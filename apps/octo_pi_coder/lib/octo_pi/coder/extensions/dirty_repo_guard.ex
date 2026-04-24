defmodule OctoPi.Coder.Extensions.DirtyRepoGuard do
  @moduledoc false

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :session_before_switch, &handle_before_switch/2)
  end

  defp handle_before_switch(_event, ctx) do
    case git_dirty?(ctx.cwd) do
      true -> {:cancel, "uncommitted changes in repo"}
      false -> nil
    end
  end

  defp git_dirty?(cwd) do
    case System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  rescue
    _ -> false
  end
end
