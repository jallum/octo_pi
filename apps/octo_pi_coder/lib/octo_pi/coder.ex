defmodule OctoPi.Coder do
  @moduledoc """
  Coding-agent core: the application layer that composes the
  `OctoPi.Agent` kernel with a JSONL session store, built-in file +
  bash + search tools, and the Print / RPC output modes.

  Public facade is intentionally thin at this stage — callers should
  reach for specific submodules (`OctoPi.Coder.SessionStore`,
  `OctoPi.Coder.Tools.*`, `OctoPi.Coder.Modes.Print`,
  `OctoPi.Coder.Modes.Rpc`).
  """
end
