defmodule OctoPi.AI.Message.Assistant do
  @moduledoc """
  An assistant message. `content` is a list of text, thinking, and
  tool-call blocks in the order they streamed in.

  `stop_reason` is `:stop | :length | :tool_use | :error | :aborted`.
  `error_message` is set only when `stop_reason in [:error, :aborted]`.
  `response_id` is the provider-assigned id when the API returns one
  (e.g. Anthropic's `msg_...`).

  `timestamp` is Unix milliseconds.
  """

  alias OctoPi.AI.{Content, Usage}

  @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

  @enforce_keys [:api, :provider, :model, :timestamp]
  @type t :: %__MODULE__{
          content: [Content.assistant_block()],
          api: atom(),
          provider: atom(),
          model: String.t(),
          response_id: String.t() | nil,
          usage: Usage.t(),
          stop_reason: stop_reason() | nil,
          error_message: String.t() | nil,
          timestamp: integer()
        }

  defstruct [
    :api,
    :provider,
    :model,
    :response_id,
    :stop_reason,
    :error_message,
    :timestamp,
    content: [],
    usage: %Usage{}
  ]
end
