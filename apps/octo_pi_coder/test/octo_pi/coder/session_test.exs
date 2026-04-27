defmodule OctoPi.Coder.SessionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Session
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore

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

  defp empty_sm do
    %SessionManager{cwd: "/tmp", session_id: "sm-test"}
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
      sm = empty_sm()

      {:ok, pid} = Session.start_link(extensions: [], session_manager: sm, store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = Session.state(pid)
      assert state.extensions == []
      assert state.session_manager == sm
      assert state.store_pid == store
      assert state.agent_pid == nil
    end

    test "raises if :extensions, :session_manager, or :store_pid is missing", ctx do
      store = open_store!(ctx)
      sm = empty_sm()

      assert_raise KeyError, fn ->
        Session.start_link(session_manager: sm, store_pid: store)
      end

      assert_raise KeyError, fn ->
        Session.start_link(extensions: [], store_pid: store)
      end

      assert_raise KeyError, fn ->
        Session.start_link(extensions: [], session_manager: sm)
      end
    end

    test "default settings_provider returns Settings.default()", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Session.state(pid).settings_provider.() == Settings.default()
    end

    test "default model_provider returns nil", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Session.state(pid).model_provider.() == nil
    end

    test "honors caller-supplied model_provider and settings_provider", ctx do
      store = open_store!(ctx)
      model_fn = fn -> :my_model end
      settings = %Settings{enabled: false, reserve_tokens: 99, keep_recent_tokens: 99}
      settings_fn = fn -> settings end

      {:ok, pid} =
        Session.start_link(
          extensions: [],
          session_manager: empty_sm(),
          store_pid: store,
          model_provider: model_fn,
          settings_provider: settings_fn
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = Session.state(pid)
      assert state.model_provider.() == :my_model
      assert state.settings_provider.() == settings
    end
  end

  describe "getters" do
    setup ctx do
      store = open_store!(ctx)
      ext = %Extension{id: "e1", path: "/dev/null"}
      sm = empty_sm()

      {:ok, pid} =
        Session.start_link(extensions: [ext], session_manager: sm, store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store, sm: sm, ext: ext}
    end

    test "get_session_manager/1 returns the seeded SessionManager", %{pid: pid, sm: sm} do
      assert Session.get_session_manager(pid) == sm
    end

    test "get_extensions/1 returns the seeded extension list", %{pid: pid, ext: ext} do
      assert Session.get_extensions(pid) == [ext]
    end
  end

  describe "add_entry/3" do
    setup ctx do
      store = open_store!(ctx)
      sm = empty_sm()

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: sm, store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store}
    end

    test "appends to in-process SessionManager AND persists to store", %{pid: pid, store: store} do
      assert {:ok, entry_id} = Session.add_entry(pid, message_entry("hello"))

      sm = Session.get_session_manager(pid)
      assert sm.leaf_id == entry_id
      assert Map.has_key?(sm.by_id, entry_id)

      # Persistence: read JSONL back and confirm the entry landed.
      path = SessionStore.path(store)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      # header line + one entry line
      assert length(lines) == 2
    end

    test "two appends produce a parent_id chain in the SessionManager", %{pid: pid} do
      assert {:ok, id1} = Session.add_entry(pid, message_entry("a"))
      assert {:ok, id2} = Session.add_entry(pid, message_entry("b"))
      refute id1 == id2

      sm = Session.get_session_manager(pid)
      assert sm.leaf_id == id2
      e2 = Map.fetch!(sm.by_id, id2)
      assert e2.parent_id == id1
    end

    test "honors caller-supplied :id option", %{pid: pid} do
      assert {:ok, "fixed-id"} = Session.add_entry(pid, message_entry("x"), id: "fixed-id")
      assert Session.get_session_manager(pid).leaf_id == "fixed-id"
    end
  end

  describe "compact/2" do
    alias OctoPi.AI.Content.Text
    alias OctoPi.AI.Event
    alias OctoPi.AI.Message.Assistant
    alias OctoPi.AI.Model
    alias OctoPi.AI.Usage
    alias OctoPi.Coder.Compaction.Result
    alias OctoPi.Coder.Extension

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

      {:ok, pid} =
        Session.start_link(
          extensions: extensions,
          session_manager: empty_sm(),
          store_pid: store,
          model_provider: fn -> test_model() end,
          settings_provider: fn ->
            %Settings{enabled: true, reserve_tokens: 1000, keep_recent_tokens: 0}
          end
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Two messages so prep has something to summarize.
      {:ok, _} = Session.add_entry(pid, message_entry("first"))
      {:ok, _} = Session.add_entry(pid, message_entry("second"))

      pid
    end

    defp ext_with(id, event_type, handler) do
      ext = %Extension{id: id, path: "/dev/null"}
      Extension.add_handler(ext, event_type, handler)
    end

    test "returns {:error, :nothing_to_compact} for an empty session", ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(
          extensions: [],
          session_manager: empty_sm(),
          store_pid: store,
          model_provider: fn -> test_model() end
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:error, :nothing_to_compact} = Session.compact(pid)
    end

    test "extension {:cancel, reason} surfaces verbatim, no LLM call", ctx do
      test_pid = self()

      ext =
        ext_with("c", :session_before_compact, fn _e, _c ->
          send(test_pid, :cancel_handler_ran)
          {:cancel, "user said no"}
        end)

      pid = populated_session(ctx, [ext])

      producer = fn _, _, _ -> send(test_pid, :producer_called); done_event("") end

      assert {:cancel, "user said no"} = Session.compact(pid, producer: producer)
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
      producer = fn _, _, _ -> send(test_pid, :producer_called); done_event("") end

      assert {:ok, %{result: ^override_result, from_extension?: true}} =
               Session.compact(pid, producer: producer)

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
               Session.compact(pid, producer: producer)

      assert_received :producer_called
    end

    test "{:error, :no_model} when model_provider returns nil", ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(
          extensions: [],
          session_manager: empty_sm(),
          store_pid: store,
          model_provider: fn -> nil end,
          settings_provider: fn ->
            %Settings{enabled: true, reserve_tokens: 1000, keep_recent_tokens: 0}
          end
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, _} = Session.add_entry(pid, message_entry("a"))
      {:ok, _} = Session.add_entry(pid, message_entry("b"))

      assert {:error, :no_model} = Session.compact(pid)
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
      Session.compact(pid, producer: producer, custom_instructions: "tag this")

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
        Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "empty session returns empty context", %{pid: pid} do
      assert %{messages: [], thinking_level: "off", model: nil} =
               Session.build_session_context(pid)
    end

    test "delegates to SessionManager and reflects appended messages", %{pid: pid} do
      {:ok, _} = Session.add_entry(pid, message_entry("hello"))
      {:ok, _} = Session.add_entry(pid, message_entry("world"))

      ctx = Session.build_session_context(pid)
      assert length(ctx.messages) == 2
    end

    test "compaction boundary: synthetic summary at head, kept window after", %{pid: pid} do
      {:ok, _id1} = Session.add_entry(pid, message_entry("first"))
      {:ok, id2} = Session.add_entry(pid, message_entry("second"))

      compaction = %Entry.Compaction{
        id: nil,
        timestamp: nil,
        summary: "the summary",
        first_kept_entry_id: id2,
        tokens_before: 1234
      }

      {:ok, _} = Session.add_entry(pid, compaction)
      {:ok, _} = Session.add_entry(pid, message_entry("after"))

      ctx = Session.build_session_context(pid)

      assert [%CompactionSummaryMessage{summary: "the summary", tokens_before: 1234} | rest] =
               ctx.messages

      assert length(rest) == 2
    end
  end

  describe "messages_provider closure for Agent.Session (E5a)" do
    alias OctoPi.AI.Content.Text
    alias OctoPi.AI.Message.User
    alias OctoPi.Coder.Session.Messages

    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    # The coder app builds this closure when starting an Agent.Session
    # bound to a Coder.Session. Agent.Session calls it per turn to get
    # the LLM messages list (replacing MessageLog.to_list/1).
    defp build_provider(coder_session) do
      fn _agent_state ->
        coder_session
        |> Session.build_session_context()
        |> Map.fetch!(:messages)
        |> Messages.to_llm()
      end
    end

    test "no compaction: passes through messages as-is", %{pid: pid} do
      {:ok, _} = Session.add_entry(pid, message_entry("hi"))
      provider = build_provider(pid)

      assert [_msg] = provider.(:dummy_state)
    end

    test "after compaction: synthetic summary becomes wrapped User at head", %{pid: pid} do
      {:ok, _id1} = Session.add_entry(pid, message_entry("first"))
      {:ok, id2} = Session.add_entry(pid, message_entry("kept"))

      compaction = %Entry.Compaction{
        id: nil,
        timestamp: nil,
        summary: "rolled-up summary",
        first_kept_entry_id: id2,
        tokens_before: 1000
      }

      {:ok, _} = Session.add_entry(pid, compaction)
      {:ok, _} = Session.add_entry(pid, message_entry("after"))

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

  describe "Context.bind_session/2" do
    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "wires get_entries / get_branch / get_leaf_entry_id to live SessionManager", %{pid: pid} do
      ctx = OctoPi.Coder.Extension.Context.new(%{cwd: "/tmp"})
      bound = OctoPi.Coder.Extension.Context.bind_session(ctx, pid)

      assert bound.get_entries.() == []
      assert bound.get_leaf_entry_id.() == nil

      assert {:ok, id} = Session.add_entry(pid, message_entry("x"))
      assert bound.get_leaf_entry_id.() == id
    end
  end
end
