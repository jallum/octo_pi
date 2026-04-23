defmodule OctoPi.AI do
  @moduledoc """
  Facade for the `octo_pi_ai` app: multi-provider streaming LLM client,
  ported from `badlogic/pi-mono`'s `packages/ai`.

  The canonical types (`Context`, `Model`, `Message`, `Event`,
  `Provider` behaviour, …) live in `OctoPi.AI.*` submodules. The
  public `stream/3` entry point and its process-based producer land
  in a later ticket (octo-42f.6).

  See `docs/port-map/anthropic.md` for the porting spec.
  """
end
