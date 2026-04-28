defmodule OctoPi.Coder.Extension.Loader do
  @moduledoc false

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Session

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
          dedup_path(path, acc, seen)
        end)
      end)

    Enum.reverse(paths)
  end

  @spec load(String.t()) :: {:ok, Extension.t()} | {:error, term()}
  def load(path), do: do_load(path, _actions = nil)

  @doc """
  Load an extension and pre-bind it to a live `OctoPi.Coder.Session`
  process **before** `module.init/1` runs.

  This ordering matters: extension handlers register via `API.on(api,
  ...)` and close over the `api` they were given. If we bound after
  init, the captured api would still hold the raise-on-call stubs.
  Compare with the post-init upstream pattern, which is fine in JS
  because handlers reference the `api` object by mutable identity.

  Routes API actions like `api.compact.([])` to `Coder.Session.compact/2`
  on the given pid. Unimplemented actions stay as the raise-on-call
  stubs installed by `API.new/1`.
  """
  @spec load_for_session(String.t(), GenServer.server()) ::
          {:ok, Extension.t()} | {:error, term()}
  def load_for_session(path, session) do
    do_load(path, Session.__action_closures__(session))
  end

  defp do_load(path, actions) do
    :telemetry.execute([:octo_pi_coder, :extension, :load_start], %{}, %{path: path})
    id = extension_id(path)

    with {:ok, modules} <- compile_file(path),
         {:ok, module} <- find_init_module(modules, path),
         {:ok, api} <- call_init(module, id, actions) do
      {:ok, API.build_extension(api, path)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec load_all([String.t()]) :: [Extension.t()]
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

  @spec load_from_factory(String.t(), (API.t() -> {:ok, API.t()} | :ok)) ::
          {:ok, Extension.t()} | {:error, term()}
  def load_from_factory(id, factory) when is_binary(id) and is_function(factory, 1) do
    api = API.new(id)

    case factory.(api) do
      {:ok, %API{} = api} -> {:ok, API.build_extension(api, "factory:#{id}")}
      :ok -> {:ok, API.build_extension(api, "factory:#{id}")}
      other -> {:error, "factory returned unexpected: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "factory raised: #{Exception.message(e)}"}
  end

  @spec discover_mix_deps(String.t()) :: [String.t()]
  def discover_mix_deps(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(fn entry ->
          full = Path.join(dir, entry)
          File.dir?(full) && File.exists?(Path.join(full, "mix.exs"))
        end)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @spec standard_dirs(String.t()) :: [String.t()]
  def standard_dirs(cwd) do
    [
      Path.join(cwd, ".octo_pi/extensions"),
      Path.expand("~/.octo_pi/extensions")
    ]
  end

  @type load_result :: %{extensions: [Extension.t()], errors: [%{path: String.t(), error: String.t()}]}

  @doc """
  Discovers extensions from `{cwd}/extensions/` and loads them together
  with any `explicit_paths`. Returns a result map with `:extensions` and
  `:errors` keys so callers can surface load failures without crashing.
  """
  @spec discover_and_load([String.t()], String.t()) :: load_result()
  def discover_and_load(explicit_paths, cwd) do
    discovered = discover(Path.join(cwd, "extensions"))
    all_paths = Enum.uniq(explicit_paths ++ discovered)
    load_with_errors(all_paths)
  end

  @doc """
  Loads only the given `explicit_paths` without any filesystem discovery.
  Returns a result map with `:extensions` and `:errors` keys.
  """
  @spec load_extensions([String.t()], String.t()) :: load_result()
  def load_extensions(explicit_paths, _cwd) do
    load_with_errors(explicit_paths)
  end

  defp load_with_errors(paths) do
    {exts, errs} =
      Enum.reduce(paths, {[], []}, fn path, {exts, errs} ->
        case load(path) do
          {:ok, ext} -> {[ext | exts], errs}
          {:error, reason} -> {exts, [%{path: path, error: reason} | errs]}
        end
      end)

    %{extensions: Enum.reverse(exts), errors: Enum.reverse(errs)}
  end

  defp dedup_path(path, acc, seen) do
    basename = extension_id(path)

    if MapSet.member?(seen, basename) do
      {acc, seen}
    else
      {[path | acc], MapSet.put(seen, basename)}
    end
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

  defp call_init(module, id, actions) do
    api = id |> API.new() |> maybe_bind_core(actions)

    case module.init(api) do
      {:ok, %API{} = api} -> {:ok, api}
      :ok -> {:ok, api}
      other -> {:error, "init/1 returned unexpected: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "init/1 raised: #{Exception.message(e)}"}
  end

  defp maybe_bind_core(api, nil), do: api
  defp maybe_bind_core(api, %{} = actions), do: API.bind_core(api, actions)
end
