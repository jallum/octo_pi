defmodule OctoPi.AI.Event.Start do
  @moduledoc "Emitted once, before any content-block events."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:partial]
  @type t :: %__MODULE__{partial: Assistant.t()}

  defstruct [:partial]
end
