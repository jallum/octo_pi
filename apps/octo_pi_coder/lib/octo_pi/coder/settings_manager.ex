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

      sm = SettingsManager.load("/my/project")
      settings = SettingsManager.get_compaction_settings(sm)
      # => %OctoPi.Coder.Compaction.Settings{enabled: true, ...}
  """

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

  # ── load/2 ───────────────────────────────────────────────────────────────

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

  # ── in_memory/1 ──────────────────────────────────────────────────────────

  @doc """
  Construct a `SettingsManager` from an already-decoded map, bypassing
  file I/O. Useful for tests.

  The map is treated as the merged result; global and project are set
  to the same map (no separate layers needed for in-memory use).
  """
  @spec in_memory(map()) :: t()
  def in_memory(settings \\ %{}) when is_map(settings) do
    %__MODULE__{
      global_settings: settings,
      project_settings: %{},
      merged: settings,
      errors: []
    }
  end

  # ── accessors ────────────────────────────────────────────────────────────

  @doc """
  Extract compaction settings from the merged map, applying defaults for
  any missing keys. Mirrors upstream `reserveTokens`, `keepRecentTokens`,
  and `enabled` accessors (settings-manager.ts:632-649).
  """
  @spec get_compaction_settings(t()) :: CompactionSettings.t()
  def get_compaction_settings(%__MODULE__{merged: merged}) do
    comp = Map.get(merged, "compaction") || %{}

    %CompactionSettings{
      enabled: get_bool(comp, "enabled", true),
      reserve_tokens: get_int(comp, "reserveTokens", 16_384),
      keep_recent_tokens: get_int(comp, "keepRecentTokens", 20_000)
    }
  end

  # ── deep_merge/2 ─────────────────────────────────────────────────────────

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

  # ── private helpers ───────────────────────────────────────────────────────

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
