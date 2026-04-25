defmodule OctoPi.Coder.Extension.HarnessTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content.Text
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Test.EventCollector
  alias OctoPi.Coder.Test.FauxResponse
  alias OctoPi.Coder.Test.FauxTransport
  alias OctoPi.Coder.Test.Harness

  @moduletag capture_log: true

  setup do
    on_exit(&FauxTransport.clear/0)
    :ok
  end

  describe "Harness.create/1" do
    test "returns a harness with a live session and event collector" do
      harness = Harness.create()
      assert is_pid(harness.session)
      assert is_pid(harness.collector)
    end

    test "session starts idle — event collector is empty" do
      harness = Harness.create()
      assert EventCollector.events(harness.collector) == []
    end
  end

  describe "FauxTransport text response" do
    test "text response emits AgentEnd with :stop reason" do
      harness = Harness.create()
      FauxTransport.set_script([%FauxResponse{text: "hello"}])

      :ok = OctoPi.Agent.prompt(harness.session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      events = EventCollector.events(harness.collector)
      assert Enum.any?(events, &match?(%Event.AgentEnd{reason: :stop}, &1))
    end

    test "text response emits MessageEnd with the scripted text" do
      harness = Harness.create()
      FauxTransport.set_script([%FauxResponse{text: "pong"}])

      :ok = OctoPi.Agent.prompt(harness.session, "ping")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      events = EventCollector.events(harness.collector)

      assert Enum.any?(events, fn
               %Event.MessageEnd{message: msg} ->
                 Enum.any?(msg.content, fn
                   %Text{text: "pong"} -> true
                   _ -> false
                 end)

               _ ->
                 false
             end)
    end

    test "full event order: AgentStart → TurnStart → … → TurnEnd → AgentEnd" do
      harness = Harness.create()
      FauxTransport.set_script([%FauxResponse{text: "ok"}])

      :ok = OctoPi.Agent.prompt(harness.session, "go")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      types = harness.collector |> EventCollector.events() |> Enum.map(&event_type/1)

      assert Enum.find_index(types, &(&1 == :agent_start)) <
               Enum.find_index(types, &(&1 == :turn_start))

      assert Enum.find_index(types, &(&1 == :turn_end)) <
               Enum.find_index(types, &(&1 == :agent_end))
    end
  end

  describe "FauxTransport tool call response" do
    test "tool call response triggers ToolExecutionStart and ToolExecutionEnd" do
      harness = Harness.create(tools: [noop_tool()])

      FauxTransport.set_script([
        %FauxResponse{tool_calls: [%{id: "c1", name: "noop", args: %{}}]},
        %FauxResponse{text: "done"}
      ])

      :ok = OctoPi.Agent.prompt(harness.session, "use noop")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      events = EventCollector.events(harness.collector)
      assert Enum.any?(events, &match?(%Event.ToolExecutionStart{tool_name: "noop"}, &1))
      assert Enum.any?(events, &match?(%Event.ToolExecutionEnd{tool_name: "noop"}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{reason: :stop}, &1))
    end

    test "tool call loop runs both turns" do
      harness = Harness.create(tools: [noop_tool()])

      FauxTransport.set_script([
        %FauxResponse{tool_calls: [%{id: "c1", name: "noop", args: %{}}]},
        %FauxResponse{text: "finished"}
      ])

      :ok = OctoPi.Agent.prompt(harness.session, "use noop twice")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      events = EventCollector.events(harness.collector)
      turn_starts = Enum.filter(events, &match?(%Event.TurnStart{}, &1))
      assert length(turn_starts) == 2
    end
  end

  describe "extension factory injection" do
    test "factories are loaded into harness.extensions" do
      factory = fn api -> {:ok, api} end

      harness = Harness.create(factories: [{"my_ext", factory}])
      assert length(harness.extensions) == 1
      assert hd(harness.extensions).id == "my_ext"
    end

    test "extension handler is registered in the loaded extension" do
      factory = fn api ->
        handler = fn _event, _ctx -> nil end
        API.on(api, :message_end, handler)
      end

      harness = Harness.create(factories: [{"counter_ext", factory}])
      assert length(harness.extensions) == 1

      ext = hd(harness.extensions)
      assert ext.id == "counter_ext"
      assert map_size(ext.handlers) > 0
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp event_type(%Event.AgentStart{}), do: :agent_start
  defp event_type(%Event.AgentEnd{}), do: :agent_end
  defp event_type(%Event.TurnStart{}), do: :turn_start
  defp event_type(%Event.TurnEnd{}), do: :turn_end
  defp event_type(_), do: :other

  defp noop_tool do
    %OctoPi.Agent.Tool{
      name: "noop",
      description: "does nothing",
      parameters: %{},
      handler: __MODULE__.NoopHandler
    }
  end

  defmodule NoopHandler do
    @moduledoc false
    @behaviour OctoPi.Agent.Tool.Handler

    alias OctoPi.Agent.Tool.Result

    @impl true
    def execute(_id, _args, _abort_ref, _on_update) do
      {:ok, %Result{content: [%Text{text: "ok"}]}}
    end
  end
end
