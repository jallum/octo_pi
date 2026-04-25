defmodule OctoPi.Coder.Extensions.AutoCommitOnExit do
  @moduledoc """
  Automatically commits uncommitted changes when the session shuts down.
  Uses a [pi] prefixed commit message.

  Diverges from auto-commit-on-exit.ts: ctx.sessionManager.getEntries() is not
  available, so the commit message is derived from the cwd rather than the last
  assistant message.
  Ported from examples/extensions/auto-commit-on-exit.ts.
  """

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

  defp build_message(%{cwd: cwd}) do
    dir = Path.basename(cwd)
    "[pi] Work in progress in #{dir}"
  end
end
