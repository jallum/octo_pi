defmodule OctoPi.Coder.Modes.PrintTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.{Model, Usage}
  alias OctoPi.Coder.Modes.Print

  setup do
    on_exit(&FakeTransport.clear/0)
    :ok
  end

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

  defp assistant(content, stop_reason) do
    %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: content,
      stop_reason: stop_reason,
      usage: %Usage{}
    }
  end

  describe "run/1" do
    test "writes assistant text to stdout and returns :ok on :stop" do
      final = assistant([%OctoPi.AI.Content.Text{text: "hello world"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.TextDelta{content_index: 0, delta: "hello world", partial: final},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, _} =
                   Print.run(%{
                     prompt: "hi",
                     model: model(),
                     transport: FakeTransport,
                     tools: []
                   })
        end)

      assert output =~ "hello world"
    end

    test "returns :error when agent ends with :error" do
      errored = assistant([], :error)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: errored},
          %AIEvent.Error{reason: :error, message: errored}
        ]
      ])

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, :error} =
                 Print.run(%{
                   prompt: "fail",
                   model: model(),
                   transport: FakeTransport,
                   tools: []
                 })
      end)
    end
  end
end
