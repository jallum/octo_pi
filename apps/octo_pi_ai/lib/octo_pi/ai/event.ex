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
  (`types.ts` L248-260).
  """

  alias OctoPi.AI.Event

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
end
