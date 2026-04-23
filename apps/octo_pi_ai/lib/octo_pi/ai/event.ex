defmodule OctoPi.AI.Event do
  @moduledoc """
  Canonical event union emitted by `OctoPi.AI.Provider.stream/3`.

  The stream begins with a single `Start`, interleaves per-content-block
  lifecycles (`*_start` → zero or more `*_delta` → `*_end`), and
  terminates with exactly one of `Done` or `Error`.

  Every event carries a `partial :: Message.Assistant.t()` snapshot of
  the assistant message under construction — consumers that only want
  to render current state can ignore deltas and render `partial`.

  Ported from pi-ai's `AssistantMessageEvent` union
  (`types.ts` L248-260). All 12 variants colocate here rather than
  spreading across a directory of tiny files — matching the scope of
  the upstream discriminated-union type.
  """

  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant

  @type t ::
          Event.Start.t()
          | Event.TextStart.t()
          | Event.TextDelta.t()
          | Event.TextEnd.t()
          | Event.ThinkingStart.t()
          | Event.ThinkingDelta.t()
          | Event.ThinkingEnd.t()
          | Event.ToolCallStart.t()
          | Event.ToolCallDelta.t()
          | Event.ToolCallEnd.t()
          | Event.Done.t()
          | Event.Error.t()

  defmodule Start do
    @moduledoc "Emitted once, before any content-block events."

    @enforce_keys [:partial]
    @type t :: %__MODULE__{partial: Assistant.t()}

    defstruct [:partial]
  end

  defmodule TextStart do
    @moduledoc "A text content block has begun."

    @enforce_keys [:content_index, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :partial]
  end

  defmodule TextDelta do
    @moduledoc "An incremental chunk of a text content block."

    @enforce_keys [:content_index, :delta, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            delta: String.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :delta, :partial]
  end

  defmodule TextEnd do
    @moduledoc "A text content block has finished; `content` is the full accumulated string."

    @enforce_keys [:content_index, :content, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            content: String.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :content, :partial]
  end

  defmodule ThinkingStart do
    @moduledoc "A thinking / reasoning content block has begun."

    @enforce_keys [:content_index, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :partial]
  end

  defmodule ThinkingDelta do
    @moduledoc "An incremental chunk of a thinking content block."

    @enforce_keys [:content_index, :delta, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            delta: String.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :delta, :partial]
  end

  defmodule ThinkingEnd do
    @moduledoc "A thinking content block has finished."

    @enforce_keys [:content_index, :content, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            content: String.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :content, :partial]
  end

  defmodule ToolCallStart do
    @moduledoc "A tool-use content block has begun."

    @enforce_keys [:content_index, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :partial]
  end

  defmodule ToolCallDelta do
    @moduledoc """
    An incremental chunk of a tool-call's streaming JSON arguments.
    `delta` is the raw JSON fragment; the caller's `partial` reflects
    the provider's best-effort parse of the accumulated buffer.
    """

    @enforce_keys [:content_index, :delta, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            delta: String.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :delta, :partial]
  end

  defmodule ToolCallEnd do
    @moduledoc """
    A tool-use content block has finished. `tool_call` is the finalized
    `ToolCall` struct with fully-parsed `arguments`.
    """

    alias OctoPi.AI.ToolCall

    @enforce_keys [:content_index, :tool_call, :partial]
    @type t :: %__MODULE__{
            content_index: non_neg_integer(),
            tool_call: ToolCall.t(),
            partial: Assistant.t()
          }

    defstruct [:content_index, :tool_call, :partial]
  end

  defmodule Done do
    @moduledoc """
    Terminal event for a successful stream. `message` is the finalized
    assistant message; `reason` is the successful stop reason.
    """

    @type reason :: :stop | :length | :tool_use

    @enforce_keys [:reason, :message]
    @type t :: %__MODULE__{
            reason: reason(),
            message: Assistant.t()
          }

    defstruct [:reason, :message]
  end

  defmodule Error do
    @moduledoc """
    Terminal event for a failed or cancelled stream. `message` carries
    the partial assistant message; `message.error_message` holds the
    human-readable cause.
    """

    @type reason :: :error | :aborted

    @enforce_keys [:reason, :message]
    @type t :: %__MODULE__{
            reason: reason(),
            message: Assistant.t()
          }

    defstruct [:reason, :message]
  end
end
