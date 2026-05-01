defmodule OctoPiTestLoaderHandler5636 do
  def init(api) do
    OctoPi.Coder.Extension.API.on(api, :agent_start, fn _ev, _ctx -> nil end)
  end
end
