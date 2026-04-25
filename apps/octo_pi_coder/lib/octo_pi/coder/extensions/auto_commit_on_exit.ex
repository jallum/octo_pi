defmodule OctoPi.Coder.Extensions.AutoCommitOnExit do
  @moduledoc """
  Automatically commits uncommitted changes when the session shuts down.
  Uses the last assistant message text as the commit message.
  Ported from examples/extensions/auto-commit-on-exit.ts.
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :session_shutdown, fn _event, ctx -> on_shutdown(api, ctx) end)
  end

  defp on_shutdown(api, ctx) do
    %{stdout: status, code: code} = api.exec.("git", ["status", "--porcelain"])

    if code == 0 and String.trim(status) != "" do
      commit_changes(api, ctx)
    end
  end

  defp commit_changes(api, ctx) do
    api.exec.("git", ["add", "-A"])
    message = build_message(ctx)
    api.exec.("git", ["commit", "-m", message])
    :ok
  end

  defp build_message(%{get_entries: get_entries}) do
    text = find_last_assistant_text(get_entries.())
    first_line = text |> String.split("\n") |> hd()
    suffix = if String.length(first_line) > 50, do: "...", else: ""
    "[pi] #{String.slice(first_line, 0, 50)}#{suffix}"
  end

  defp find_last_assistant_text(entries) do
    Enum.find_value(Enum.reverse(entries), "Work in progress", fn
      %Assistant{content: content} ->
        text =
          content
          |> Enum.filter(&match?(%Text{}, &1))
          |> Enum.map_join("\n", & &1.text)

        if text == "", do: nil, else: text

      _ ->
        nil
    end)
  end
end
