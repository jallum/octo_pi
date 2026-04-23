defmodule OctoPi.Agent.Tool do
  @moduledoc """
  A tool registered with a session. Mirrors pi-agent-core's
  `AgentTool` (`tmp/pi-mono/packages/agent/src/types.ts` L306-330).

  - `name` / `description` / `parameters` feed the LLM's tool schema
    (same shape as `OctoPi.AI.Tool`).
  - `label` is the human-readable form used in UI events.
  - `prepare_arguments` (optional) validates/transforms the raw args
    map before the handler sees it; returning anything other than
    the shaped map raises and surfaces as a tool error.
  - `handler` is the module implementing `OctoPi.Agent.Tool.Handler`.
  - `execution_mode` is `:parallel` (default) or `:sequential`. If
    ANY tool in a batch is `:sequential`, the whole batch runs
    sequentially — matches pi-mono semantics (agent-loop.ts L349).
  """

  @type execution_mode :: :parallel | :sequential

  @enforce_keys [:name, :description, :parameters, :handler]
  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t() | nil,
          description: String.t(),
          parameters: map(),
          prepare_arguments: (map() -> map()) | nil,
          handler: module(),
          execution_mode: execution_mode()
        }

  defstruct [
    :name,
    :description,
    :parameters,
    :handler,
    :label,
    prepare_arguments: nil,
    execution_mode: :parallel
  ]
end
