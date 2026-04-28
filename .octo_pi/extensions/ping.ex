defmodule Ping do
  alias OctoPi.Coder.Extension.API

  def init(api) do
    API.register_command(api, "ping", %{
      description: "Reply pong (extension smoke test)",
      handler: fn _args, _ctx -> "pong!" end
    })
  end
end
