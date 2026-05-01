defmodule OctoPi.Extensions.LoadStartExt do
  @moduledoc false
  def init(api) do
    {:ok, api} = OctoPi.Coder.Extension.API.on(api, :session_start, fn _e, _c -> nil end)
    {:ok, api}
  end
end
