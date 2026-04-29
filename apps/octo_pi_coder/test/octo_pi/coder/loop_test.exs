defmodule OctoPi.Coder.LoopTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder
  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Loop
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Messages, as: SessionMessages
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.SettingsManager

  defp tmp_session_opts(ctx) do
    id = "test-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "opi-session-test-#{ctx.test}-#{id}")
    [id: id, cwd: System.tmp_dir!(), root: root]
  end

  defp open_store!(ctx) do
    {:ok, pid} = SessionStore.start_link(tmp_session_opts(ctx))
    on_exit(fn -> if Process.alive?(pid), do: SessionStore.close(pid) end)
    pid
  end

  @faux_model %OctoPi.AI.Model{
    id: "faux-1",
    name: "Faux Model",
    api: :faux,
    provider: :faux,
    base_url: "https://example.com",
    context_window: 128_000,
    max_tokens: 16_384
  }

  defp start_agent! do
    {:ok, pid} = OctoPi.Agent.start_loop(model: @faux_model, convert_to_llm: &SessionMessages.to_llm/1)
    on_exit(fn -> if Process.alive?(pid), do: try_stop(pid) end)
    pid
  end

  defp try_stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp loop_opts(extra \\ []) do
    Keyword.put_new_lazy(extra, :agent_pid, &start_agent!/0)
  end

  defp message_entry(text) do
    %Entry.Message{
      id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => text}
    }
  end

  describe "start_link/1" do
    test "starts with required opts and exposes state via state/1", ctx do
      store = open_store!(ctx)
      agent = start_agent!()

      {:ok, pid} = Loop.start_link(extensions: [], store_pid: store, agent_pid: agent)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.extensions == []
      assert state.store_pid == store
      assert state.agent_pid == agent
    end

    test "raises if :extensions, :store_pid, or :agent_pid is missing", ctx do
      store = open_store!(ctx)
      agent = start_agent!()

      assert_raise KeyError, fn ->
        Loop.start_link(store_pid: store, agent_pid: agent)
      end

      assert_raise KeyError, fn ->
        Loop.start_link(extensions: [], agent_pid: agent)
      end

      assert_raise KeyError, fn ->
        Loop.start_link(extensions: [], store_pid: store)
      end
    end

    test "default settings_manager returns Settings.default() for compaction", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Loop.start_link(loop_opts(extensions: [], store_pid: store))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Coder.get_compaction_settings(pid) == Settings.default()
    end

    test "default model_provider returns nil", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Loop.start_link(loop_opts(extensions: [], store_pid: store))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :sys.get_state(pid).model_provider.() == nil
    end

    test "honors caller-supplied model_provider and settings_manager", ctx do
      store = open_store!(ctx)
      model_fn = fn -> :my_model end
      expected = %Settings{enabled: false, reserve_tokens: 99, keep_recent_tokens: 99}

      {:ok, sm} =
        SettingsManager.in_memory(%{
          "compaction" => %{"enabled" => false, "reserveTokens" => 99, "keepRecentTokens" => 99}
        })

      {:ok, pid} =
        Loop.start_link(
          loop_opts(
            extensions: [],
            store_pid: store,
            model_provider: model_fn,
            settings_manager: sm
          )
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :sys.get_state(pid).model_provider.() == :my_model
      assert Coder.get_compaction_settings(pid) == expected
    end
  end

  describe "getters" do
    setup ctx do
      store = open_store!(ctx)
      ext = %Extension{id: "e1", path: "/dev/null"}

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [ext], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store, ext: ext}
    end

    test "get_session_manager/1 proxies to the store", %{pid: pid, store: store} do
      assert Coder.get_session_manager(pid) == SessionStore.get_session_manager(store)
    end

    test "get_extensions/1 returns the seeded extension list", %{pid: pid, ext: ext} do
      assert Coder.get_extensions(pid) == [ext]
    end
  end

  describe "add_entry/3" do
    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store}
    end

    test "appends to in-process SessionManager AND persists to store", %{pid: pid, store: store} do
      assert {:ok, entry_id} = Coder.add_entry(pid, message_entry("hello"))

      sm = Coder.get_session_manager(pid)
      assert sm.leaf_id == entry_id
      assert Map.has_key?(sm.by_id, entry_id)

      # Persistence: read JSONL back and confirm the entry landed.
      path = SessionStore.path(store)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      # header line + one entry line
      assert length(lines) == 2
    end

    test "two appends produce a parent_id chain in the SessionManager", %{pid: pid} do
      assert {:ok, id1} = Coder.add_entry(pid, message_entry("a"))
      assert {:ok, id2} = Coder.add_entry(pid, message_entry("b"))
      refute id1 == id2

      sm = Coder.get_session_manager(pid)
      assert sm.leaf_id == id2
      e2 = Map.fetch!(sm.by_id, id2)
      assert e2.parent_id == id1
    end

    test "honors caller-supplied :id option", %{pid: pid} do
      assert {:ok, "fixed-id"} = Coder.add_entry(pid, message_entry("x"), id: "fixed-id")
      assert Coder.get_session_manager(pid).leaf_id == "fixed-id"
    end

    test "mirrors user-origin entries into Agent's working transcript", ctx do
      store = open_store!(ctx)
      agent = start_agent!()

      {:ok, pid} =
        Loop.start_link(extensions: [], store_pid: store, agent_pid: agent)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:ok, _} = Coder.add_entry(pid, message_entry("hello agent"))

      agent_state = :sys.get_state(agent).loop
      msgs = agent_state.messages
      assert [%{"role" => "user", "content" => "hello agent"}] = msgs
    end
  end

  describe "compact/2" do
    alias OctoPi.AI.Content.Text
    alias OctoPi.AI.Event
    alias OctoPi.AI.Message.Assistant
    alias OctoPi.AI.Model
    alias OctoPi.AI.Usage
    alias OctoPi.Coder.Compaction.Result

    defp test_model do
      %Model{
        id: "claude-test",
        name: "Test",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://example",
        reasoning: false,
        input: [:text],
        context_window: 200_000,
        max_tokens: 8192,
        cost: nil
      }
    end

    defp done_event(text) do
      [
        %Event.Done{
          reason: :stop,
          message: %Assistant{
            api: :anthropic_messages,
            provider: :anthropic,
            model: "claude-test",
            timestamp: 0,
            stop_reason: :stop,
            content: [%Text{text: text}],
            usage: %Usage{}
          }
        }
      ]
    end

    defp populated_session(ctx, extensions \\ []) do
      store = open_store!(ctx)

      {:ok, sm} =
        SettingsManager.in_memory(%{
          "compaction" => %{"enabled" => true, "reserveTokens" => 1000, "keepRecentTokens" => 0}
        })

      {:ok, pid} =
        Loop.start_link(
          loop_opts(
            extensions: extensions,
            store_pid: store,
            model_provider: fn -> test_model() end,
            settings_manager: sm
          )
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Two messages so prep has something to summarize.
      {:ok, _} = Coder.add_entry(pid, message_entry("first"))
      {:ok, _} = Coder.add_entry(pid, message_entry("second"))

      pid
    end

    defp ext_with(id, event_type, handler) do
      ext = %Extension{id: id, path: "/dev/null"}
      Extension.add_handler(ext, event_type, handler)
    end

    test "returns {:error, :nothing_to_compact} for an empty session", ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Loop.start_link(
          loop_opts(
            extensions: [],
            store_pid: store,
            model_provider: fn -> test_model() end
          )
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:error, :nothing_to_compact} = Coder.compact(pid)
    end

    test "extension {:cancel, reason} surfaces verbatim, no LLM call", ctx do
      test_pid = self()

      ext =
        ext_with("c", :session_before_compact, fn _e, _c ->
          send(test_pid, :cancel_handler_ran)
          {:cancel, "user said no"}
        end)

      pid = populated_session(ctx, [ext])

      producer = fn _, _, _ ->
        send(test_pid, :producer_called)
        done_event("")
      end

      assert {:cancel, "user said no"} = Coder.compact(pid, producer: producer)
      assert_received :cancel_handler_ran
      refute_received :producer_called
    end

    test "extension {:override, %Result{}} surfaces with from_extension?: true, no LLM call", ctx do
      test_pid = self()

      override_result = %Result{
        summary: "ext-supplied",
        first_kept_entry_id: "anything",
        tokens_before: 42
      }

      ext =
        ext_with("o", :session_before_compact, fn _e, _c ->
          {:override, override_result}
        end)

      pid = populated_session(ctx, [ext])

      producer = fn _, _, _ ->
        send(test_pid, :producer_called)
        done_event("")
      end

      assert {:ok, %{result: ^override_result, from_extension?: true}} =
               Coder.compact(pid, producer: producer)

      refute_received :producer_called
    end

    test "no extension override falls through to Compaction.compact/2 with model + opts", ctx do
      test_pid = self()

      producer = fn _, _, _ ->
        send(test_pid, :producer_called)
        done_event("LLM-SUMMARY")
      end

      pid = populated_session(ctx)

      assert {:ok, %{result: %Result{summary: "LLM-SUMMARY"}, from_extension?: false}} =
               Coder.compact(pid, producer: producer)

      assert_received :producer_called
    end

    test "{:error, :no_model} when model_provider returns nil", ctx do
      store = open_store!(ctx)

      {:ok, sm} =
        SettingsManager.in_memory(%{
          "compaction" => %{"enabled" => true, "reserveTokens" => 1000, "keepRecentTokens" => 0}
        })

      {:ok, pid} =
        Loop.start_link(
          loop_opts(
            extensions: [],
            store_pid: store,
            model_provider: fn -> nil end,
            settings_manager: sm
          )
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, _} = Coder.add_entry(pid, message_entry("a"))
      {:ok, _} = Coder.add_entry(pid, message_entry("b"))

      assert {:error, :no_model} = Coder.compact(pid)
    end

    test "passes preparation in :session_before_compact event payload", ctx do
      test_pid = self()

      ext =
        ext_with("p", :session_before_compact, fn event, _c ->
          send(test_pid, {:event_seen, event})
          nil
        end)

      pid = populated_session(ctx, [ext])
      producer = fn _, _, _ -> done_event("ok") end
      Coder.compact(pid, producer: producer, custom_instructions: "tag this")

      assert_received {:event_seen, event}
      assert event.type == :session_before_compact
      assert match?(%OctoPi.Coder.Compaction.Preparation{}, event.preparation)
      assert event.custom_instructions == "tag this"
    end
  end

  describe "build_session_context/1" do
    alias OctoPi.Coder.Session.CompactionSummaryMessage

    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "empty session returns empty context", %{pid: pid} do
      assert %{messages: [], thinking_level: "off", model: nil} =
               Coder.build_session_context(pid)
    end

    test "delegates to SessionManager and reflects appended messages", %{pid: pid} do
      {:ok, _} = Coder.add_entry(pid, message_entry("hello"))
      {:ok, _} = Coder.add_entry(pid, message_entry("world"))

      ctx = Coder.build_session_context(pid)
      assert length(ctx.messages) == 2
    end

    test "compaction boundary: synthetic summary at head, kept window after", %{pid: pid} do
      {:ok, _id1} = Coder.add_entry(pid, message_entry("first"))
      {:ok, id2} = Coder.add_entry(pid, message_entry("second"))

      compaction = %Entry.Compaction{
        id: nil,
        timestamp: nil,
        summary: "the summary",
        first_kept_entry_id: id2,
        tokens_before: 1234
      }

      {:ok, _} = Coder.add_entry(pid, compaction)
      {:ok, _} = Coder.add_entry(pid, message_entry("after"))

      ctx = Coder.build_session_context(pid)

      assert [%CompactionSummaryMessage{summary: "the summary", tokens_before: 1234} | rest] =
               ctx.messages

      assert length(rest) == 2
    end
  end

  describe "messages_provider closure for Agent.Loop (E5a)" do
    alias OctoPi.AI.Content.Text
    alias OctoPi.AI.Message.User
    alias SessionMessages, as: SessionMessages

    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    # The coder app builds this closure when starting an Agent.Loop
    # bound to a Coder.Session. Agent.Loop calls it per turn to get
    # the LLM messages list (replacing MessageLog.to_list/1).
    defp build_provider(coder_session) do
      fn _agent_state ->
        coder_session
        |> Coder.build_session_context()
        |> Map.fetch!(:messages)
        |> SessionMessages.to_llm()
      end
    end

    test "no compaction: passes through messages as-is", %{pid: pid} do
      {:ok, _} = Coder.add_entry(pid, message_entry("hi"))
      provider = build_provider(pid)

      assert [_msg] = provider.(:dummy_state)
    end

    test "after compaction: synthetic summary becomes wrapped User at head", %{pid: pid} do
      {:ok, _id1} = Coder.add_entry(pid, message_entry("first"))
      {:ok, id2} = Coder.add_entry(pid, message_entry("kept"))

      compaction = %Entry.Compaction{
        id: nil,
        timestamp: nil,
        summary: "rolled-up summary",
        first_kept_entry_id: id2,
        tokens_before: 1000
      }

      {:ok, _} = Coder.add_entry(pid, compaction)
      {:ok, _} = Coder.add_entry(pid, message_entry("after"))

      provider = build_provider(pid)

      [head | rest] = provider.(:dummy_state)

      # Compaction summary is converted to a wrapped User block by
      # Messages.to_llm/1 — it should never reach the provider as a
      # synthetic struct.
      assert %User{content: [%Text{text: text}]} = head
      assert text =~ "rolled-up summary"
      assert text =~ "<summary>"

      # Kept window: "kept" + the compaction's own row's projection +
      # "after". (Compaction rows themselves don't project messages.)
      assert length(rest) == 2
    end
  end

  describe "fork/2" do
    defp loaded_session!(ctx) do
      store = open_store!(ctx)
      path = SessionStore.path(store)

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {pid, path, store}
    end

    defp fork_dir(ctx) do
      Path.join(System.tmp_dir!(), "opi-fork-test-#{ctx.test}-#{System.unique_integer([:positive])}")
    end

    test "returns {:ok, new_store_pid} for a valid session", ctx do
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("hello"))

      dir = fork_dir(ctx)
      assert {:ok, new_store} = Coder.fork(pid, target_cwd: "/some/cwd", target_dir: dir)
      assert is_pid(new_store)
      on_exit(fn -> if Process.alive?(new_store), do: SessionStore.close(new_store) end)
    end

    test "forked session has parent_session pointing at source file", ctx do
      {pid, source_path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("a"))

      dir = fork_dir(ctx)
      {:ok, new_store} = Coder.fork(pid, target_cwd: "/cwd", target_dir: dir)
      on_exit(fn -> if Process.alive?(new_store), do: SessionStore.close(new_store) end)

      assert SessionStore.get_session_manager(new_store).parent_session == source_path
    end

    test "forked session has the requested target_cwd", ctx do
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("a"))

      dir = fork_dir(ctx)
      {:ok, new_store} = Coder.fork(pid, target_cwd: "/fork/cwd", target_dir: dir)
      on_exit(fn -> if Process.alive?(new_store), do: SessionStore.close(new_store) end)

      assert SessionStore.get_cwd(new_store) == "/fork/cwd"
    end

    test "forked session carries all source entries", ctx do
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("one"))
      {:ok, _} = Coder.add_entry(pid, message_entry("two"))

      dir = fork_dir(ctx)
      {:ok, new_store} = Coder.fork(pid, target_cwd: "/cwd", target_dir: dir)
      on_exit(fn -> if Process.alive?(new_store), do: SessionStore.close(new_store) end)

      assert length(SessionStore.get_entries(new_store)) == 2
    end

    test "forked session file is readable and loads correctly", ctx do
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("content"))

      dir = fork_dir(ctx)
      {:ok, new_store} = Coder.fork(pid, target_cwd: "/cwd", target_dir: dir)
      on_exit(fn -> if Process.alive?(new_store), do: SessionStore.close(new_store) end)

      assert {:ok, reloaded} = SessionManager.load(SessionStore.path(new_store))
      assert reloaded.session_id == SessionStore.get_session_id(new_store)
    end

    test "extension {:cancel, reason} aborts fork, no file written", ctx do
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, _} = Coder.add_entry(pid, message_entry("a"))

      ext = ext_with("c", :session_before_fork, fn _e, _c -> {:cancel, "not allowed"} end)
      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)

      dir = fork_dir(ctx)
      assert {:cancel, "not allowed"} = Coder.fork(pid, target_cwd: "/cwd", target_dir: dir)
      refute File.dir?(dir)
    end

    test "event payload includes leaf entry_id", ctx do
      test_pid = self()
      {pid, _path, _store} = loaded_session!(ctx)
      {:ok, leaf_id} = Coder.add_entry(pid, message_entry("leaf"))

      ext =
        ext_with("e", :session_before_fork, fn event, _c ->
          send(test_pid, {:fork_event, event})
          nil
        end)

      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)
      dir = fork_dir(ctx)
      Coder.fork(pid, target_cwd: "/cwd", target_dir: dir)

      assert_received {:fork_event, event}
      assert event.type == :session_before_fork
      assert event.entry_id == leaf_id
    end
  end

  describe "Context.bind_session/2" do
    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Loop.start_link(loop_opts(extensions: [], store_pid: store))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "wires get_entries / get_branch / get_leaf_entry_id to live SessionManager", %{pid: pid} do
      ctx = Context.new(%{cwd: "/tmp"})
      bound = Context.bind_session(ctx, pid)

      assert bound.get_entries.() == []
      assert bound.get_leaf_entry_id.() == nil

      assert {:ok, id} = Coder.add_entry(pid, message_entry("x"))
      assert bound.get_leaf_entry_id.() == id
    end
  end

  describe "navigate_tree/2" do
    alias OctoPi.AI.Content.Text
    alias OctoPi.AI.Event, as: AIEvent
    alias OctoPi.AI.Message.Assistant
    alias OctoPi.AI.Model
    alias OctoPi.AI.Usage
    alias OctoPi.Coder.Compaction.BranchSummaryResult
    alias OctoPi.Coder.Compaction.TreePreparation

    defp nav_model do
      %Model{
        id: "nav-model",
        name: "Nav Model",
        api: :anthropic,
        provider: :anthropic,
        base_url: "https://api.anthropic.com",
        context_window: 200_000,
        max_tokens: 8192
      }
    end

    defp summary_producer(text) do
      msg = %Assistant{
        api: :anthropic,
        provider: :anthropic,
        model: "nav-model",
        timestamp: 0,
        content: [%Text{text: text}],
        stop_reason: :end_turn,
        usage: %Usage{}
      }

      fn _m, _c, _o -> [%AIEvent.Done{reason: :stop, message: msg}] end
    end

    defp session_with_two_branches(ctx) do
      store = open_store!(ctx)
      {:ok, pid} = Loop.start_link(loop_opts(extensions: [], store_pid: store))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, id1} = Coder.add_entry(pid, message_entry("root message"))
      {:ok, id2} = Coder.add_entry(pid, message_entry("branch A"))
      # Navigate back to id1 to create a fork point for id3.
      :ok = SessionStore.set_leaf(store, id1)

      {:ok, id3} = Coder.add_entry(pid, message_entry("branch B"))

      {pid, id1, id2, id3}
    end

    # ---- no-op ----

    test "returns {:ok, nil} immediately when target_id == current leaf", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Loop.start_link(loop_opts(extensions: [], store_pid: store))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, id} = Coder.add_entry(pid, message_entry("a"))
      assert {:ok, nil} = Coder.navigate_tree(pid, target_id: id)
    end

    test "returns {:error, :not_found} for an unknown target_id", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Loop.start_link(loop_opts(extensions: [], store_pid: store))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:error, :not_found} = Coder.navigate_tree(pid, target_id: "ghost")
    end

    # ---- cancel path ----

    test "extension {:cancel, reason} aborts navigation without changing leaf", ctx do
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)
      ext = ext_with("c", :session_before_tree, fn _e, _c -> {:cancel, "denied"} end)
      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)

      assert {:cancel, "denied"} = Coder.navigate_tree(pid, target_id: id2)
      # leaf unchanged (should still be id3 — the last one added)
      sm = Coder.get_session_manager(pid)
      refute sm.leaf_id == id2
    end

    # ---- extension-override path ----

    test "extension {:override, BranchSummaryResult} is used when user_wants_summary != :no", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      ext_result = %BranchSummaryResult{summary: "ext summary", read_files: [], modified_files: []}

      ext =
        ext_with("o", :session_before_tree, fn _e, _c ->
          send(test_pid, :ext_ran)
          {:override, ext_result}
        end)

      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)

      assert {:ok, ^ext_result} =
               Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :yes, model: nav_model())

      assert_received :ext_ran
    end

    test "extension {:override, BranchSummaryResult} is ignored when user_wants_summary is :no", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      ext_result = %BranchSummaryResult{summary: "ext summary", read_files: [], modified_files: []}
      ext = ext_with("o", :session_before_tree, fn _e, _c -> {:override, ext_result} end)

      producer = fn _m, _c, _o ->
        send(test_pid, :llm_called)
        []
      end

      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)

      assert {:ok, nil} =
               Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :no, producer: producer)

      refute_received :llm_called
    end

    # ---- no-summary path ----

    test "user_wants_summary: :no skips LLM and updates leaf", ctx do
      test_pid = self()
      {pid, id1, id2, _id3} = session_with_two_branches(ctx)

      producer = fn _m, _c, _o ->
        send(test_pid, :llm_called)
        []
      end

      assert {:ok, nil} =
               Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :no, producer: producer)

      refute_received :llm_called
      sm = Coder.get_session_manager(pid)
      # id2 is a user message → new leaf is id2's parent (id1)
      assert sm.leaf_id == id1
    end

    # ---- LLM path ----

    test "user_wants_summary: :yes calls BranchSummarization.generate and updates leaf", ctx do
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)
      producer = summary_producer("summarized")

      assert {:ok, %BranchSummaryResult{summary: summary}} =
               Coder.navigate_tree(pid,
                 target_id: id2,
                 user_wants_summary: :yes,
                 model: nav_model(),
                 producer: producer
               )

      assert summary =~ "summarized"
    end

    test "{:yes, instructions} threads custom_instructions into generate", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      capturing = fn model, ai_ctx, opts ->
        send(test_pid, {:generate_called, ai_ctx})
        [_] = summary_producer("ok").(model, ai_ctx, opts)
      end

      Coder.navigate_tree(pid,
        target_id: id2,
        user_wants_summary: {:yes, "focus on files"},
        model: nav_model(),
        producer: capturing
      )

      assert_received {:generate_called, ai_ctx}
      [msg] = ai_ctx.messages
      [%Text{text: prompt}] = msg.content
      assert prompt =~ "focus on files"
    end

    test "no model given with user_wants_summary != :no returns {:error, :no_model}", ctx do
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      assert {:error, :no_model} =
               Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :yes)
    end

    # ---- event payload ----

    test ":session_before_tree event payload carries TreePreparation", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      ext =
        ext_with("p", :session_before_tree, fn event, _c ->
          send(test_pid, {:tree_event, event})
          nil
        end)

      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)
      Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :no)

      assert_received {:tree_event, event}
      assert event.type == :session_before_tree
      assert %TreePreparation{target_id: ^id2} = event.preparation
    end

    # ---- :session_tree fire-and-forget ----

    test ":session_tree event is emitted after successful navigation", ctx do
      test_pid = self()
      {pid, id1, id2, _id3} = session_with_two_branches(ctx)

      ext =
        ext_with("t", :session_tree, fn event, _c ->
          send(test_pid, {:session_tree, event})
          nil
        end)

      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)
      Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :no)

      assert_received {:session_tree, event}
      assert event.type == :session_tree
      # id2 is a user message → new_leaf = id2's parent = id1
      assert event.new_leaf_id == id1
      assert event.old_leaf_id
    end

    test ":session_tree is NOT emitted on cancel", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      cancel_ext = ext_with("c", :session_before_tree, fn _e, _c -> {:cancel, "no"} end)

      tree_ext =
        ext_with("t", :session_tree, fn _event, _c ->
          send(test_pid, :session_tree_emitted)
          nil
        end)

      :sys.replace_state(pid, fn state -> %{state | extensions: [cancel_ext, tree_ext]} end)
      assert {:cancel, "no"} = Coder.navigate_tree(pid, target_id: id2)
      refute_received :session_tree_emitted
    end

    # ---- from_id and summary parent position ----

    test "BranchSummary entry has from_id == old_leaf_id", ctx do
      {pid, _id1, id2, id3} = session_with_two_branches(ctx)
      # current leaf is id3 (branch B)
      producer = summary_producer("summary text")

      {:ok, _result} =
        Coder.navigate_tree(pid,
          target_id: id2,
          user_wants_summary: :yes,
          model: nav_model(),
          producer: producer
        )

      sm = Coder.get_session_manager(pid)
      # Find the BranchSummary entry
      branch_summary =
        sm
        |> SessionManager.get_entries()
        |> Enum.find(&match?(%Entry.BranchSummary{}, &1))

      assert branch_summary
      # from_id is the old leaf before navigation (id3)
      assert branch_summary.from_id == id3
    end

    test "BranchSummary parent is new_leaf_id (parent of user-message target)", ctx do
      {pid, id1, id2, _id3} = session_with_two_branches(ctx)
      producer = summary_producer("summary")

      {:ok, _result} =
        Coder.navigate_tree(pid,
          target_id: id2,
          user_wants_summary: :yes,
          model: nav_model(),
          producer: producer
        )

      sm = Coder.get_session_manager(pid)

      branch_summary =
        sm
        |> SessionManager.get_entries()
        |> Enum.find(&match?(%Entry.BranchSummary{}, &1))

      # id2 is a user message → new_leaf = id1 → summary.parent_id = id1
      assert branch_summary.parent_id == id1
    end

    test "no-summary navigation does not append any new entries", ctx do
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)
      count_before = pid |> Coder.get_session_manager() |> SessionManager.get_entries() |> length()

      Coder.navigate_tree(pid, target_id: id2, user_wants_summary: :no)

      count_after = pid |> Coder.get_session_manager() |> SessionManager.get_entries() |> length()
      assert count_after == count_before
    end

    test "from_hook: false for LLM-generated summary, true for extension override", ctx do
      test_pid = self()
      {pid, _id1, id2, _id3} = session_with_two_branches(ctx)

      ext_result = %BranchSummaryResult{summary: "ext summary", read_files: [], modified_files: []}
      ext = ext_with("o", :session_before_tree, fn _e, _c -> {:override, ext_result} end)
      :sys.replace_state(pid, fn state -> %{state | extensions: [ext]} end)

      {:ok, _} =
        Coder.navigate_tree(pid,
          target_id: id2,
          user_wants_summary: :yes,
          model: nav_model()
        )

      sm = Coder.get_session_manager(pid)

      branch_summary =
        sm
        |> SessionManager.get_entries()
        |> Enum.find(&match?(%Entry.BranchSummary{}, &1))

      assert branch_summary.from_hook == true
      _ = test_pid
    end
  end

  # ---- get_context_usage / get_session_stats --------------------------------
  # Ports `tmp/pi-mono/packages/coding-agent/test/agent-session-stats.test.ts`.

  describe "get_context_usage/1 and get_session_stats/1" do
    setup ctx do
      store = open_store!(ctx)

      model = %OctoPi.AI.Model{
        id: "test-model",
        name: "Test Model",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://api.anthropic.com",
        context_window: 200_000,
        max_tokens: 8096
      }

      {:ok, pid} =
        Loop.start_link(
          loop_opts(
            extensions: [],
            store_pid: store,
            model_provider: fn -> model end
          )
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid, model: model}
    end

    defp user_msg(text) do
      %Entry.Message{
        id: nil,
        timestamp: nil,
        message: %{"role" => "user", "content" => text}
      }
    end

    defp assistant_msg(text, total_tokens) do
      %Entry.Message{
        id: nil,
        timestamp: nil,
        message: %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => text}],
          "stopReason" => "stop",
          "usage" => %{
            "input" => total_tokens,
            "output" => 0,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "totalTokens" => total_tokens
          }
        }
      }
    end

    defp compaction_entry(summary, first_kept_entry_id, tokens_before) do
      %Entry.Compaction{
        id: nil,
        timestamp: nil,
        summary: summary,
        first_kept_entry_id: first_kept_entry_id,
        tokens_before: tokens_before
      }
    end

    test "exposes current context usage alongside token totals", %{pid: pid, model: model} do
      Coder.add_entry(pid, user_msg("hello"))
      Coder.add_entry(pid, assistant_msg("hi", 200))

      stats = Coder.get_session_stats(pid)
      cu = Coder.get_context_usage(pid)

      assert cu.tokens == stats.context_usage.tokens
      assert cu.tokens == 200
      assert cu.context_window == model.context_window
      assert_in_delta cu.percent, 200 / model.context_window * 100, 0.001
    end

    test "reports nil context tokens immediately after compaction (no post-compaction assistant)",
         %{pid: pid} do
      Coder.add_entry(pid, user_msg("first"))
      Coder.add_entry(pid, assistant_msg("response1", 180_000))
      {:ok, kept_id} = Coder.add_entry(pid, user_msg("second"))
      Coder.add_entry(pid, assistant_msg("response2", 195_000))
      Coder.add_entry(pid, compaction_entry("summary", kept_id, 195_000))
      Coder.add_entry(pid, user_msg("third"))

      stats = Coder.get_session_stats(pid)
      assert stats.tokens.input == 195_000
      assert stats.context_usage
      assert stats.context_usage.tokens == nil
      assert stats.context_usage.percent == nil
    end

    test "uses post-compaction usage for current context, not stale pre-compaction usage",
         %{pid: pid} do
      Coder.add_entry(pid, user_msg("first"))
      Coder.add_entry(pid, assistant_msg("response1", 180_000))
      {:ok, kept_id} = Coder.add_entry(pid, user_msg("second"))
      Coder.add_entry(pid, assistant_msg("response2", 195_000))
      Coder.add_entry(pid, compaction_entry("summary", kept_id, 195_000))
      Coder.add_entry(pid, user_msg("third"))
      Coder.add_entry(pid, assistant_msg("response3", 25_000))

      stats = Coder.get_session_stats(pid)
      assert stats.tokens.input == 220_000
      assert stats.context_usage
      assert stats.context_usage.tokens == 25_000
      assert_in_delta stats.context_usage.percent, 25_000 / 200_000 * 100, 0.001
    end

    test "returns nil when no model is set", ctx do
      store = open_store!(ctx)

      {:ok, pid2} =
        Loop.start_link(
          loop_opts(
            extensions: [],
            store_pid: store,
            model_provider: fn -> nil end
          )
        )

      on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

      assert Coder.get_context_usage(pid2) == nil
    end
  end
end
