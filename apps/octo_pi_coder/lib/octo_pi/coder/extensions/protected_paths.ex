defmodule OctoPi.Coder.Extensions.ProtectedPaths do
  @moduledoc """
  Blocks write and edit operations to protected paths (.env, .git/, node_modules/).
  Ported from examples/extensions/protected-paths.ts.
  """

  alias OctoPi.Coder.Extension.API

  @protected_paths [".env", ".git/", "node_modules/"]
  @write_tools ["write", "edit"]

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :tool_call, fn event, ctx -> check(event, ctx) end)
  end

  defp check(%{name: name, arguments: args}, ctx) when name in @write_tools do
    path = Map.get(args, "path", "")
    block_if_protected(path, ctx)
  end

  defp check(_, _), do: nil

  defp block_if_protected(path, ctx) do
    if protected?(path) do
      maybe_notify(ctx, path)
      {:block, ~s(Path "#{path}" is protected)}
    end
  end

  defp protected?(path), do: Enum.any?(@protected_paths, &String.contains?(path, &1))

  defp maybe_notify(%{has_ui?: true, ui: ui}, path) do
    ui.notify.("Blocked write to protected path: #{path}")
  end

  defp maybe_notify(_, _), do: :ok
end
