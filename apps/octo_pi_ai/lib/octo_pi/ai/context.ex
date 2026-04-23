defmodule OctoPi.AI.Context do
  @moduledoc """
  Everything a provider needs besides the model and per-call options:
  a system prompt, the message history, and the tools the model may
  call.
  """

  alias OctoPi.AI.{Message, Tool}

  @type t :: %__MODULE__{
          system_prompt: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()]
        }

  defstruct system_prompt: nil, messages: [], tools: []
end
