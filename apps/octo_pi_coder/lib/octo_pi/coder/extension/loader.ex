defmodule OctoPi.Coder.Extension.Loader do
  @moduledoc false

  alias OctoPi.Coder.Extension.API

  require Logger

  @spec discover(String.t()) :: [String.t()]
  def discover(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)

          cond do
            Path.extname(entry) == ".ex" ->
              [full]

            File.dir?(full) && File.exists?(Path.join(full, "index.ex")) ->
              [Path.join(full, "index.ex")]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @spec discover_all([String.t()]) :: [String.t()]
  def discover_all(dirs) do
    {paths, _seen} =
      Enum.reduce(dirs, {[], MapSet.new()}, fn dir, {acc, seen} ->
        Enum.reduce(discover(dir), {acc, seen}, fn path, {acc, seen} ->
          basename = extension_id(path)

          if MapSet.member?(seen, basename) do
            {acc, seen}
          else
            {acc ++ [path], MapSet.put(seen, basename)}
          end
        end)
      end)

    paths
  end

  @spec load(String.t()) :: {:ok, OctoPi.Coder.Extension.t()} | {:error, term()}
  def load(path) do
    id = extension_id(path)

    with {:ok, modules} <- compile_file(path),
         {:ok, module} <- find_init_module(modules, path),
         {:ok, api} <- call_init(module, id) do
      {:ok, API.build_extension(api, path)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec load_all([String.t()]) :: [OctoPi.Coder.Extension.t()]
  def load_all(paths) do
    Enum.flat_map(paths, fn path ->
      case load(path) do
        {:ok, ext} ->
          :telemetry.execute(
            [:octo_pi_coder, :extension, :loaded],
            %{count: 1},
            %{
              id: ext.id,
              path: ext.path,
              handler_count: ext.handlers |> Map.values() |> List.flatten() |> length(),
              tool_count: map_size(ext.tools)
            }
          )

          [ext]

        {:error, reason} ->
          :telemetry.execute(
            [:octo_pi_coder, :extension, :load_error],
            %{},
            %{path: path, error: reason}
          )

          Logger.warning("Failed to load extension at #{path}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp extension_id(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> then(fn
      "index" -> path |> Path.dirname() |> Path.basename()
      name -> name
    end)
  end

  defp compile_file(path) do
    case Code.compile_file(path) do
      [] -> {:error, "no modules defined in #{path}"}
      modules -> {:ok, Enum.map(modules, &elem(&1, 0))}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp find_init_module(modules, path) do
    case Enum.find(modules, &function_exported?(&1, :init, 1)) do
      nil -> {:error, "no module with init/1 in #{path}"}
      mod -> {:ok, mod}
    end
  end

  defp call_init(module, id) do
    api = API.new(id)

    case module.init(api) do
      {:ok, %API{} = api} -> {:ok, api}
      :ok -> {:ok, api}
      other -> {:error, "init/1 returned unexpected: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "init/1 raised: #{Exception.message(e)}"}
  end
end
