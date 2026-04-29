defmodule OctoPi.Coder.CLITest do
  use ExUnit.Case, async: true

  # See RpcTest: agent turn-Task teardown can race session stop and
  # log an expected error.
  alias OctoPi.Coder.CLI

  @moduletag capture_log: true

  describe "parse_args/1" do
    test "defaults to print mode with prompt from positional args" do
      assert {:ok, %{mode: :print, prompt: "hi there", model: _}} =
               CLI.parse_args(["hi", "there"])
    end

    test "recognizes --print flag with prompt" do
      assert {:ok, %{mode: :print, prompt: "hello"}} = CLI.parse_args(["--print", "hello"])
    end

    test "recognizes -p shorthand" do
      assert {:ok, %{mode: :print, prompt: "x"}} = CLI.parse_args(["-p", "x"])
    end

    test "--mode rpc selects rpc mode; no prompt required" do
      assert {:ok, %{mode: :rpc}} = CLI.parse_args(["--mode", "rpc"])
    end

    test "--model overrides the default" do
      assert {:ok, %{model: %{id: "claude-sonnet-4-5"}}} =
               CLI.parse_args(["--model", "claude-sonnet-4-5", "hi"])
    end

    test "vendor/model id resolves to OpenRouter" do
      assert {:ok,
              %{
                model: %{
                  id: "anthropic/claude-sonnet-4.5",
                  provider: :openrouter,
                  api: :openai_completions,
                  base_url: "https://openrouter.ai/api/v1"
                }
              }} = CLI.parse_args(["--model", "anthropic/claude-sonnet-4.5", "hi"])
    end

    test "claude* id resolves to Anthropic regardless of slashes" do
      assert {:ok, %{model: %{provider: :anthropic}}} =
               CLI.parse_args(["--model", "claude-sonnet-4-5", "hi"])
    end

    test "non-slash, non-claude id resolves to local Ollama" do
      assert {:ok, %{model: %{provider: :ollama, id: "qwen3.5:latest"}}} =
               CLI.parse_args(["--model", "qwen3.5:latest", "hi"])
    end

    test "--help returns a help sentinel" do
      assert {:help, _usage} = CLI.parse_args(["--help"])
    end

    test "no args defaults to interactive mode" do
      assert {:ok, %{mode: :interactive, prompt: nil}} = CLI.parse_args([])
    end

    test "--log-telemetry=PATH is parsed into opts" do
      assert {:ok, %{log_telemetry: "/tmp/tracer.log"}} =
               CLI.parse_args(["--log-telemetry=/tmp/tracer.log"])
    end

    test "--list-telemetry sets list_telemetry: true" do
      assert {:ok, %{list_telemetry: true}} = CLI.parse_args(["--list-telemetry"])
    end

    test "--no-telemetry splits comma-separated ids into a list" do
      assert {:ok, %{no_telemetry: ["agent", "tui_events"]}} =
               CLI.parse_args(["--no-telemetry=agent,tui_events"])
    end

    test "--no-telemetry with no value defaults to empty list" do
      assert {:ok, %{no_telemetry: []}} = CLI.parse_args([])
    end
  end

  describe "safe_emit/1" do
    test "emits the JSON-encoded map on stdout" do
      output = ExUnit.CaptureIO.capture_io(fn -> CLI.safe_emit(%{"a" => 1}) end)
      assert output == ~s|{"a":1}| <> "\n"
    end

    test "survives a non-encodable value and emits an error fallback" do
      bad = %{"pid" => self()}

      output = ExUnit.CaptureIO.capture_io(fn -> CLI.safe_emit(bad) end)

      decoded = Jason.decode!(String.trim(output))
      assert decoded["error"]["message"] =~ "encoding failed"
    end
  end

  describe "response_for/2" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Model

    defp model do
      %Model{
        id: "fake-model",
        name: "fake",
        api: :fake_api,
        provider: :fake,
        base_url: "http://fake",
        context_window: 100,
        max_tokens: 100
      }
    end

    setup do
      on_exit(&FakeTransport.clear/0)
      :ok
    end

    test "dispatches a valid request through Rpc" do
      {:ok, session} =
        OctoPi.Agent.start_loop(model: model(), transport: FakeTransport, tools: [], convert_to_llm: &Function.identity/1)

      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session, :normal, 500) end)

      response = CLI.response_for(~s|{"id":"r1","method":"abort","params":{}}|, session)
      assert response["id"] == "r1"
      assert response["result"] == "ok"
    end

    test "returns a parse error for malformed JSON" do
      {:ok, session} =
        OctoPi.Agent.start_loop(model: model(), transport: FakeTransport, tools: [], convert_to_llm: &Function.identity/1)

      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session, :normal, 500) end)

      response = CLI.response_for("not json\n", session)
      assert response["id"] == nil
      assert response["error"]["message"] =~ "parse error"
    end
  end

  describe "bin/pi wrapper" do
    @wrapper_path Mix.Project.deps_path() |> Path.dirname() |> Path.join("bin/pi")

    test "wrapper script exists and is executable" do
      assert File.exists?(@wrapper_path)
      %{access: access} = File.stat!(@wrapper_path)
      assert access in [:read_write, :read]
    end

    test "wrapper passes +Bc erl flag" do
      contents = File.read!(@wrapper_path)
      assert contents =~ "+Bc"
    end

    test "wrapper invokes mix pi" do
      contents = File.read!(@wrapper_path)
      assert contents =~ "mix pi"
    end
  end

  describe "RPC event forwarder" do
    alias OctoPi.Agent.Event

    test "emits JSON event lines for messages sent to its mailbox" do
      test_pid = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          forwarder = spawn(fn -> CLI.forward_events() end)

          send(forwarder, {:octo_pi_agent_event, %Event.AgentStart{}})
          send(forwarder, {:octo_pi_agent_event, %Event.TurnStart{turn: 1}})
          send(forwarder, {:octo_pi_agent_event, %Event.TurnEnd{turn: 1}})

          # Drain marker — BEAM guarantees FIFO per-sender, so :drained
          # only arrives after all three events are processed. Waiting
          # for it *inside* capture_io ensures every IO.puts lands in
          # the captured buffer before the capture is torn down.
          send(forwarder, {:drain, test_pid})

          receive do
            :drained -> :ok
          after
            1_000 -> flunk("forwarder didn't drain")
          end
        end)

      decoded =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.map(decoded, & &1["event"]) == ["agent_start", "turn_start", "turn_end"]
    end

    test "wired into a live session, a full prompt run emits events in order" do
      alias OctoPi.Agent.TestSupport.FakeTransport, as: FT

      final =
        %OctoPi.AI.Message.Assistant{
          api: :fake_api,
          provider: :fake,
          model: "fake-model",
          timestamp: 0,
          content: [%OctoPi.AI.Content.Text{text: "hi"}],
          stop_reason: :stop,
          usage: %OctoPi.AI.Usage{}
        }

      FT.set_script([
        [
          %OctoPi.AI.Event.Start{partial: %{final | content: [], stop_reason: nil}},
          %OctoPi.AI.Event.TextDelta{content_index: 0, delta: "hi", partial: final},
          %OctoPi.AI.Event.Done{reason: :stop, message: final}
        ]
      ])

      test_pid = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, session} =
            OctoPi.Agent.start_loop(model: model(), transport: FT, tools: [], convert_to_llm: &Function.identity/1)

          forwarder = spawn(fn -> CLI.forward_events() end)
          OctoPi.Agent.subscribe(session, forwarder, :async)

          :ok = OctoPi.Agent.prompt(session, "hi")
          :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

          # After wait_for_idle, all agent events have been `send`/2'd
          # into the forwarder's mailbox. Our drain marker arrives
          # after them (different sender, but every prior send has
          # already completed before we issue this one). Waiting for
          # :drained *inside* capture_io ensures every IO.puts lands
          # in the captured buffer.
          send(forwarder, {:drain, test_pid})

          receive do
            :drained -> :ok
          after
            2_000 -> flunk("forwarder didn't drain")
          end
        end)

      events =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map(& &1["event"])

      assert events == [
               "agent_start",
               "turn_start",
               "message_start",
               "message_update",
               "message_end",
               "turn_end",
               "agent_end"
             ]
    end
  end
end
