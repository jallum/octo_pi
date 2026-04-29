defmodule OctoPi.Agent.TestSupport.EchoTool do
  @moduledoc """
  Test-only tool that echoes its input back as text content. Used
  across Phase 2 tests to exercise the tool-dispatch path without
  needing a real provider's tool logic.

  Register via `tool/0` to get a `%OctoPi.Agent.Tool{}` wired to this
  handler.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @doc "Return the `%Tool{}` struct callers register on a loop."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "echo",
      label: "Echo",
      description: "Returns its input as a text block.",
      parameters: %{
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_tool_call_id, %{"text" => text}, _abort_ref, _on_update) do
    {:ok, %Result{content: [%Content.Text{text: text}]}}
  end

  def execute(_tool_call_id, args, _abort_ref, _on_update) do
    {:ok, %Result{content: [%Content.Text{text: "echo (no text): #{inspect(args)}"}]}}
  end
end
