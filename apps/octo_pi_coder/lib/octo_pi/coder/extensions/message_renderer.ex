defmodule OctoPi.Coder.Extensions.MessageRenderer do
  @moduledoc """
  Registers a custom renderer for "status-update" messages and a /status command.
  Ported from examples/extensions/message-renderer.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    {:ok, api} = API.register_message_renderer(api, "status-update", &render_status/2)

    API.register_command(api, "status", %{
      description: "Send a status message (usage: /status [warn|error] message)",
      handler: fn args, _ctx -> send_status(api, String.trim(args)) end
    })
  end

  defp render_status(%{content: content, details: details}, _ctx) do
    level = (details && Map.get(details, :level)) || "info"
    "[#{String.upcase(level)}] #{content}"
  end

  defp send_status(api, args) do
    {level, content} = parse_args(args)

    api.append_entry.(%{
      custom_type: "status-update",
      content: content,
      display: true,
      details: %{level: level, timestamp: System.system_time(:millisecond)}
    })
  end

  defp parse_args("warn " <> rest), do: {"warn", rest}
  defp parse_args("error " <> rest), do: {"error", rest}
  defp parse_args(content), do: {"info", content}
end
