defmodule OctoPi.Coder.ResourceLoader.Skills do
  @moduledoc """
  Discovers and loads skills from SKILL.md files.

  Mirrors upstream pi-mono's `loadSkills()` in `skills.ts`. Skills are
  directories containing a `SKILL.md` file with YAML frontmatter. The
  name defaults to the parent directory name when omitted. Description
  is required; skills without one are silently skipped.

  Loaded from `{agent_dir}/skills/` (global) and
  `{cwd}/.pi/skills/` (project). Global skills are loaded first; name
  collisions keep the first loaded (global wins over project).
  """

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          file_path: String.t(),
          base_dir: String.t(),
          disable_model_invocation: boolean()
        }

  @config_dir ".pi"

  @doc """
  Load all skills for `cwd`.

  `agent_dir` is the global config directory (e.g. `~/.pi/`). Pass
  `nil` to skip global skills loading.

  Returns a list of skill maps. Duplicate names keep the first loaded.
  """
  @spec load_all(String.t(), String.t() | nil) :: [skill()]
  def load_all(cwd, agent_dir) do
    global_skills_dir = agent_dir && Path.join(agent_dir, "skills")
    project_skills_dir = Path.join([cwd, @config_dir, "skills"])

    global = if global_skills_dir, do: scan_dir(global_skills_dir), else: []
    project = scan_dir(project_skills_dir)

    dedup_by_name(global ++ project)
  end

  defp dedup_by_name(skills) do
    skills
    |> Enum.reduce({[], MapSet.new()}, fn skill, {acc, seen} ->
      if MapSet.member?(seen, skill.name) do
        {acc, seen}
      else
        {[skill | acc], MapSet.put(seen, skill.name)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp scan_dir(dir) do
    if File.dir?(dir) do
      do_scan_dir(dir, true)
    else
      []
    end
  end

  defp do_scan_dir(dir, _include_root_files) do
    case File.ls(dir) do
      {:error, _} -> []
      {:ok, entries} -> scan_entries(dir, entries)
    end
  end

  defp scan_entries(dir, entries) do
    skill_md = Path.join(dir, "SKILL.md")

    if File.regular?(skill_md) do
      load_skill_file(skill_md)
    else
      recurse_entries(dir, entries)
    end
  end

  defp load_skill_file(skill_md) do
    case load_from_file(skill_md) do
      nil -> []
      skill -> [skill]
    end
  end

  defp recurse_entries(dir, entries) do
    Enum.flat_map(entries, &recurse_entry(dir, &1))
  end

  defp recurse_entry(_dir, "." <> _), do: []
  defp recurse_entry(_dir, "node_modules"), do: []

  defp recurse_entry(dir, entry) do
    path = Path.join(dir, entry)
    if File.dir?(path), do: do_scan_dir(path, false), else: []
  end

  defp load_from_file(file_path) do
    case File.read(file_path) do
      {:error, _} ->
        nil

      {:ok, content} ->
        fm = parse_frontmatter(content)
        skill_dir = Path.dirname(file_path)
        parent_name = Path.basename(skill_dir)
        name = Map.get(fm, "name") || parent_name
        description = Map.get(fm, "description", "")

        if description == "" or is_nil(description) do
          nil
        else
          %{
            name: name,
            description: description,
            file_path: file_path,
            base_dir: skill_dir,
            disable_model_invocation: Map.get(fm, "disable-model-invocation") == true
          }
        end
    end
  end

  defp parse_frontmatter(content) do
    normalized = content |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    with true <- String.starts_with?(normalized, "---"),
         end_index when is_integer(end_index) <- find_frontmatter_end(normalized) do
      yaml_str = String.slice(normalized, 4, end_index - 4)
      parse_yaml_scalars(yaml_str)
    else
      _ -> %{}
    end
  end

  defp find_frontmatter_end(content) do
    case :binary.match(content, "\n---", scope: {3, byte_size(content) - 3}) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp parse_yaml_scalars(yaml_str) do
    yaml_str
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^([A-Za-z0-9_-]+):\s*(.*)$/, String.trim(line)) do
        [_, key, value] -> Map.put(acc, key, coerce_value(value))
        _ -> acc
      end
    end)
  end

  defp coerce_value("true"), do: true
  defp coerce_value("false"), do: false
  defp coerce_value("null"), do: nil
  defp coerce_value("~"), do: nil

  defp coerce_value(v) do
    stripped = v |> String.trim("\"") |> String.trim("'")
    if stripped == v, do: v, else: stripped
  end
end
