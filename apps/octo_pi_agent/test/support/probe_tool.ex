defmodule OctoPi.Agent.TestSupport.ProbeTool do
  @moduledoc """
  Flexible test tool. The handler dispatches on the argument shape so
  a single `%Tool{}` can model sleepy, updating, or raising tools
  depending on what the scripted assistant turn asks for.

  Factory: `tool(name \\ "probe", execution_mode \\ :parallel)`.

  Supported arg shapes (all optional):

    * `"sleep_ms"`  — `Process.sleep/1` before returning
    * `"label"`     — text returned in the result (defaults to "")
    * `"updates"`   — list of strings; each triggers `on_update.(str)`
    * `"raise"`     — message to raise (RuntimeError), tests the
                      loop's rescue path
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @doc "Build a `%Tool{}` wired to this handler."
  @spec tool(String.t(), :parallel | :sequential) :: Tool.t()
  def tool(name \\ "probe", execution_mode \\ :parallel) do
    %Tool{
      name: name,
      label: "Probe #{name}",
      description: "Test probe tool",
      parameters: %{"properties" => %{}},
      handler: __MODULE__,
      execution_mode: execution_mode
    }
  end

  @impl true
  def execute(_tool_call_id, args, _abort_ref, on_update) do
    if msg = args["raise"], do: raise(msg)

    for u <- List.wrap(args["updates"] || []) do
      on_update.(%Result{content: [%Content.Text{text: u}]})
    end

    if ms = args["sleep_ms"], do: Process.sleep(ms)

    label = args["label"] || ""
    {:ok, %Result{content: [%Content.Text{text: label}]}}
  end
end
