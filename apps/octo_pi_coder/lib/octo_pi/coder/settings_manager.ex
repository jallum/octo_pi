defmodule OctoPi.Coder.SettingsManager do
  @moduledoc """
  Reads project-wide settings from JSON files and exposes merged,
  typed accessors. Port of
  `tmp/pi-mono/.../core/settings-manager.ts:105-133, 146-153, 258`.

  ## Discovery

    * Global:  `~/.pi/agent/settings.json`
    * Project: `<cwd>/.pi/settings.json`

  Both files are optional. Missing files are silently ignored; parse
  errors are collected in `:errors` and the failed scope falls back
  to an empty settings map.

  ## Merge semantics

  Project settings take precedence over global. Nested maps are merged
  recursively (one level deep for each nested object); primitives and
  arrays are replaced wholesale. Mirrors upstream `deepMergeSettings`.

  ## Compaction schema (wire → Elixir)

  ```json
  { "compaction": { "enabled": true, "reserveTokens": 16384, "keepRecentTokens": 20000 } }
  ```

  Defaults: `enabled=true`, `reserve_tokens=16384`, `keep_recent_tokens=20000`.

  ## Usage

      {:ok, sm} = SettingsManager.create("/my/project")
      settings  = SettingsManager.get_compaction_settings(sm)
      # => %OctoPi.Coder.Compaction.Settings{enabled: true, ...}

      {:ok, sm} = SettingsManager.in_memory(%{"theme" => "light"})
      SettingsManager.get_theme(sm)
      # => "light"
  """

  use GenServer

  alias OctoPi.Coder.Compaction.Settings, as: CompactionSettings

  @config_dir ".pi"
  @settings_file "settings.json"

  @type error :: %{scope: :global | :project, reason: String.t()}

  @type t :: %__MODULE__{
          global_settings: map(),
          project_settings: map(),
          merged: map(),
          errors: [error()]
        }

  defstruct global_settings: %{},
            project_settings: %{},
            merged: %{},
            errors: []

  # ── GenServer API ─────────────────────────────────────────────────────────

  @doc """
  Start a linked `SettingsManager` that reads settings files for `cwd`.

  Options forwarded to `load/2` (e.g. `:global_dir`).
  """
  @spec create(Path.t(), keyword()) :: GenServer.on_start()
  def create(cwd, opts \\ []) do
    GenServer.start_link(__MODULE__, {:load, cwd, opts})
  end

  @doc """
  Start a linked `SettingsManager` backed by an in-memory map, bypassing
  file I/O. Useful for tests and for sessions that don't need persistence.
  """
  @spec in_memory(map()) :: GenServer.on_start()
  def in_memory(settings \\ %{}) when is_map(settings) do
    GenServer.start_link(__MODULE__, {:memory, settings})
  end

  @doc "Return and clear accumulated load errors. O(1)."
  @spec drain_errors(pid()) :: [error()]
  def drain_errors(pid), do: GenServer.call(pid, :drain_errors)

  @doc "Await any pending async writes. Returns `:ok` when the queue is drained."
  @spec flush(pid()) :: :ok
  def flush(pid), do: GenServer.call(pid, :flush)

  # ── Compaction accessors ──────────────────────────────────────────────────

  @doc """
  Extract compaction settings from the merged map, applying defaults for
  any missing keys. Mirrors upstream `reserveTokens`, `keepRecentTokens`,
  and `enabled` accessors (settings-manager.ts:632-649).
  """
  @spec get_compaction_settings(pid()) :: CompactionSettings.t()
  def get_compaction_settings(pid) when is_pid(pid), do: GenServer.call(pid, :get_compaction_settings)

  @spec get_compaction_enabled(pid()) :: boolean()
  def get_compaction_enabled(pid), do: get_nested(pid, ["compaction", "enabled"], true)

  @spec get_compaction_reserve_tokens(pid()) :: non_neg_integer()
  def get_compaction_reserve_tokens(pid), do: get_nested(pid, ["compaction", "reserveTokens"], 16_384)

  @spec get_compaction_keep_recent_tokens(pid()) :: non_neg_integer()
  def get_compaction_keep_recent_tokens(pid), do: get_nested(pid, ["compaction", "keepRecentTokens"], 20_000)

  # ── Model / session accessors ─────────────────────────────────────────────

  @spec get_default_model(pid()) :: String.t() | nil
  def get_default_model(pid), do: get_setting(pid, "defaultModel", nil)

  @spec set_default_model(pid(), String.t() | nil) :: :ok
  def set_default_model(pid, model), do: GenServer.call(pid, {:set, "defaultModel", model})

  @spec get_default_thinking_level(pid()) :: String.t() | nil
  def get_default_thinking_level(pid), do: get_setting(pid, "defaultThinkingLevel", nil)

  @spec get_steering_mode(pid()) :: String.t()
  def get_steering_mode(pid), do: get_setting(pid, "steeringMode", "queue")

  # ── Retry ─────────────────────────────────────────────────────────────────

  @spec get_retry_enabled(pid()) :: boolean()
  def get_retry_enabled(pid), do: get_setting(pid, "retryEnabled", false)

  @spec get_retry_settings(pid()) :: map()
  def get_retry_settings(pid), do: get_setting(pid, "retrySettings", %{})

  # ── UI / extension accessors ──────────────────────────────────────────────

  @spec get_theme(pid()) :: String.t()
  def get_theme(pid), do: get_setting(pid, "theme", "dark")

  @spec set_theme(pid(), String.t()) :: :ok
  def set_theme(pid, theme), do: GenServer.call(pid, {:set, "theme", theme})

  @spec get_extension_paths(pid()) :: [String.t()]
  def get_extension_paths(pid), do: get_setting(pid, "extensions", [])

  @spec set_extension_paths(pid(), [String.t()]) :: :ok
  def set_extension_paths(pid, paths), do: GenServer.call(pid, {:set, "extensions", paths})

  @spec get_packages(pid()) :: [String.t()]
  def get_packages(pid), do: get_setting(pid, "packages", [])

  @spec set_packages(pid(), [String.t()]) :: :ok
  def set_packages(pid, packages), do: GenServer.call(pid, {:set, "packages", packages})

  # ── Generic accessor (useful for tests) ──────────────────────────────────

  @spec get_setting(pid(), String.t(), term()) :: term()
  def get_setting(pid, key, default \\ nil) when is_binary(key), do: GenServer.call(pid, {:get, key, default})

  # ── Pure helpers (kept public) ────────────────────────────────────────────

  @doc """
  Load and merge settings for a project at `cwd`.

  Options:
    * `:global_dir` — override the global settings directory
      (default: `~/.pi/agent`)

  Returns a `SettingsManager.t()` with `:merged` holding the
  project-over-global merged map, and `:errors` listing any
  parse failures.
  """
  @spec load(Path.t(), keyword()) :: t()
  def load(cwd, opts \\ []) do
    global_dir = Keyword.get(opts, :global_dir, default_global_dir())
    global_path = Path.join(global_dir, @settings_file)
    project_path = Path.join([cwd, @config_dir, @settings_file])

    {global, global_errors} = try_load(global_path, :global)
    {project, project_errors} = try_load(project_path, :project)

    merged = deep_merge(global, project)

    %__MODULE__{
      global_settings: global,
      project_settings: project,
      merged: merged,
      errors: global_errors ++ project_errors
    }
  end

  @doc """
  Recursively merge `base` and `overrides`, with `overrides` winning.
  For nested maps, merges one level recursively; for primitives and
  lists the override value replaces the base value entirely.

  Mirrors upstream `deepMergeSettings` (settings-manager.ts:105-133).
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(base, overrides) when is_map(base) and is_map(overrides) do
    Enum.reduce(overrides, base, fn {key, override_val}, acc ->
      base_val = Map.get(acc, key)

      merged_val =
        if is_map(override_val) and not is_struct(override_val) and
             is_map(base_val) and not is_struct(base_val) do
          Map.merge(base_val, override_val)
        else
          override_val
        end

      Map.put(acc, key, merged_val)
    end)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init({:load, cwd, opts}) do
    {:ok, load(cwd, opts)}
  end

  def init({:memory, settings}) do
    {:ok, %__MODULE__{global_settings: settings, project_settings: %{}, merged: settings, errors: []}}
  end

  @impl true
  def handle_call(:get_compaction_settings, _from, %__MODULE__{merged: merged} = state) do
    comp = Map.get(merged, "compaction") || %{}

    result = %CompactionSettings{
      enabled: get_bool(comp, "enabled", true),
      reserve_tokens: get_int(comp, "reserveTokens", 16_384),
      keep_recent_tokens: get_int(comp, "keepRecentTokens", 20_000)
    }

    {:reply, result, state}
  end

  def handle_call(:drain_errors, _from, state) do
    {:reply, state.errors, %{state | errors: []}}
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:get, key, default}, _from, state) do
    {:reply, Map.get(state.merged, key, default), state}
  end

  def handle_call({:get_nested, keys, default}, _from, state) do
    value =
      case get_in(state.merged, keys) do
        nil -> default
        val -> val
      end

    {:reply, value, state}
  end

  def handle_call({:set, key, value}, _from, state) do
    {:reply, :ok, %{state | merged: Map.put(state.merged, key, value)}}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp get_nested(pid, keys, default), do: GenServer.call(pid, {:get_nested, keys, default})

  defp try_load(path, scope) do
    case File.read(path) do
      {:error, :enoent} ->
        {%{}, []}

      {:error, reason} ->
        {%{}, [%{scope: scope, reason: "read error: #{inspect(reason)}"}]}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {map, []}

          {:ok, _other} ->
            {%{}, [%{scope: scope, reason: "settings file is not a JSON object"}]}

          {:error, reason} ->
            {%{}, [%{scope: scope, reason: "JSON parse error: #{inspect(reason)}"}]}
        end
    end
  end

  defp default_global_dir do
    home = System.user_home() || raise "cannot determine home directory"
    Path.join([home, ".pi", "agent"])
  end

  defp get_bool(map, key, default) do
    case Map.get(map, key) do
      b when is_boolean(b) -> b
      _ -> default
    end
  end

  defp get_int(map, key, default) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> default
    end
  end
end
