defmodule OctoPi.Coder.Extensions.SessionName do
  @moduledoc """
  Registers a /session-name command that gets or sets a friendly name for the
  current session. Demonstrates api.set_session_name./api.get_session_name..
  Ported from examples/extensions/session-name.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.register_command(api, "session-name", %{
      description: "Set or show session name (usage: /session-name [new name])",
      handler: fn args, _ctx -> handle_session_name(api, String.trim(args)) end
    })
  end

  defp handle_session_name(api, "") do
    case api.get_session_name.() do
      nil -> "No session name set"
      name -> "Session: #{name}"
    end
  end

  defp handle_session_name(api, name) do
    api.set_session_name.(name)
    "Session named: #{name}"
  end
end
