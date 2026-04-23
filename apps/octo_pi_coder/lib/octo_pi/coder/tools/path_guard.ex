defmodule OctoPi.Coder.Tools.PathGuard do
  @moduledoc """
  Resolves tool-supplied paths against a session's working
  directory and rejects paths that escape it. Prevents a model
  from reading `/etc/passwd` or writing to `~/.ssh/id_rsa` just
  because it happened to emit an absolute path.

  Symlinks that point outside the session cwd are not followed at
  resolve time — `File.stat/2` is still the caller's
  responsibility. This guard catches the common `..` and
  absolute-path cases, which is the bulk of the blast radius.
  """

  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @doc """
  Resolve `path` against `cwd`. Relative paths are joined to cwd,
  absolute paths are taken as-is. Then the fully-expanded path is
  checked to make sure it's inside `cwd`.

  Returns `{:ok, absolute_path}` or
  `{:error, {:escapes_cwd, attempted}}`.
  """
  @spec resolve(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:escapes_cwd, String.t()}}
  def resolve(path, cwd) when is_binary(path) and is_binary(cwd) do
    base = Path.expand(cwd)
    candidate = Path.expand(path, base)

    if candidate == base or String.starts_with?(candidate, base <> "/") do
      {:ok, candidate}
    else
      {:error, {:escapes_cwd, candidate}}
    end
  end

  @doc """
  Convenience: resolve, or return an error `Tool.Result` ready to
  be handed back from a tool handler's `execute/4`. Fits in a
  `with` pipeline — `{:ok, path}` continues, `{:error, result}`
  short-circuits.
  """
  @spec resolve_or_error(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Result.t()}
  def resolve_or_error(path, cwd) do
    case resolve(path, cwd) do
      {:ok, abs} ->
        {:ok, abs}

      {:error, {:escapes_cwd, attempted}} ->
        {:error,
         %Result{
           is_error?: true,
           content: [%Content.Text{text: "path escapes session cwd: #{attempted}"}]
         }}
    end
  end
end
