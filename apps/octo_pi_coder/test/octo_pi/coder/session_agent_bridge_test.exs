defmodule OctoPi.Coder.SessionAgentBridgeTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Session
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.Test.FauxTransport

  @faux_model %Model{
    id: "faux-1",
    name: "Faux Model",
    api: :faux,
    provider: :faux,
    base_url: "https://example.com",
    context_window: 128_000,
    max_tokens: 16_384
  }

  @test_model %Model{
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

  setup do
    FauxTransport.clear()
    FauxTransport.set_script([])
    on_exit(&FauxTransport.clear/0)
    :ok
  end

  # Starts a fresh Agent + store + Coder.Session, registers on_exit cleanup.
  # opts overrides defaults passed to Session.start_link.
  defp new_wiring(ctx, opts \\ []) do
    id = "bridge-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "opi-bridge-#{ctx.test}-#{id}")

    {:ok, agent} = OctoPi.Agent.start_session(model: @faux_model, transport: FauxTransport)
    {:ok, store} = SessionStore.start_link(id: id, cwd: System.tmp_dir!(), root: root)

    base = [
      extensions: [],
      session_manager: %SessionManager{cwd: "/tmp", session_id: id},
      store_pid: store,
      agent_pid: agent,
      model_provider: fn -> @test_model end,
      settings_provider: fn ->
        %Settings{enabled: true, reserve_tokens: 1000, keep_recent_tokens: 0}
      end
    ]

    {:ok, coder} = Session.start_link(Keyword.merge(base, opts))

    on_exit(fn ->
      if Process.alive?(coder), do: GenServer.stop(coder)
      if Process.alive?(store), do: SessionStore.close(store)
      if Process.alive?(agent), do: GenServer.stop(agent)
    end)

    %{agent: agent, coder: coder, store: store}
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

  defp seed_entries(coder) do
    entry = %Entry.Message{id: nil, timestamp: nil, message: %{"role" => "user", "content" => "x"}}
    {:ok, _} = Session.add_entry(coder, entry)
    {:ok, _} = Session.add_entry(coder, entry)
  end

  defp ext_with(id, event_type, handler) do
    ext = %Extension{id: id, path: "/dev/null"}
    Extension.add_handler(ext, event_type, handler)
  end

  describe "happy path" do
    test "Entry.Compaction lands in SessionManager + JSONL, summary returned", ctx do
      %{agent: agent, coder: coder, store: store} = new_wiring(ctx)
      seed_entries(coder)
      producer = fn _, _, _ -> done_event("THE-SUMMARY") end

      assert {:ok, result} = OctoPi.Agent.compact(agent, producer: producer)

      assert result.summary == "THE-SUMMARY"
      assert result.tokens_before > 0
      assert is_binary(result.first_kept_entry_id)
      assert result.from_extension? == false

      sm = Session.get_session_manager(coder)
      entry = sm.by_id |> Map.values() |> Enum.find(&match?(%Entry.Compaction{}, &1))
      assert entry != nil
      assert entry.summary == "THE-SUMMARY"
      assert entry.from_hook == nil

      content = File.read!(SessionStore.path(store))
      assert content =~ "\"compaction\""
      assert content =~ "THE-SUMMARY"
    end

    test ":session_compact fires with the stored entry and from_extension? flag", ctx do
      test_pid = self()

      ext =
        ext_with("listener", :session_compact, fn event, _ctx ->
          send(test_pid, {:session_compact, event})
          nil
        end)

      %{agent: agent, coder: coder} = new_wiring(ctx, extensions: [ext])
      seed_entries(coder)
      producer = fn _, _, _ -> done_event("EXT-SUMMARY") end

      assert {:ok, _} = OctoPi.Agent.compact(agent, producer: producer)

      assert_receive {:session_compact, event}, 1000
      assert event.type == :session_compact
      assert %Entry.Compaction{summary: "EXT-SUMMARY"} = event.compaction_entry
      assert event.from_extension? == false
    end

    test "extension override: from_hook: true in entry, from_extension?: true in result", ctx do
      override = %Result{summary: "ext-override", first_kept_entry_id: "x", tokens_before: 99}

      ext =
        ext_with("override", :session_before_compact, fn _event, _ctx ->
          {:override, override}
        end)

      %{agent: agent, coder: coder} = new_wiring(ctx, extensions: [ext])
      seed_entries(coder)

      assert {:ok, result} = OctoPi.Agent.compact(agent)
      assert result.summary == "ext-override"
      assert result.from_extension? == true

      sm = Session.get_session_manager(coder)
      entry = sm.by_id |> Map.values() |> Enum.find(&match?(%Entry.Compaction{}, &1))
      assert entry.from_hook == true
    end
  end

  describe "cancel and error paths" do
    test "{:cancel, reason} propagates back to Agent.compact/1 caller", ctx do
      ext =
        ext_with("cancel", :session_before_compact, fn _event, _ctx ->
          {:cancel, "not now"}
        end)

      %{agent: agent, coder: coder} = new_wiring(ctx, extensions: [ext])
      seed_entries(coder)

      assert {:cancel, "not now"} = OctoPi.Agent.compact(agent)

      sm = Session.get_session_manager(coder)
      refute Enum.any?(Map.values(sm.by_id), &match?(%Entry.Compaction{}, &1))
    end

    test "{:error, :nothing_to_compact} when session has no entries", ctx do
      %{agent: agent} = new_wiring(ctx)
      assert {:error, :nothing_to_compact} = OctoPi.Agent.compact(agent)
    end

    test "{:error, :no_model} when model_provider returns nil", ctx do
      %{agent: agent, coder: coder} = new_wiring(ctx, model_provider: fn -> nil end)
      seed_entries(coder)
      assert {:error, :no_model} = OctoPi.Agent.compact(agent)
    end
  end
end
