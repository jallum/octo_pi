defmodule OctoPi.Coder.PromptTemplates do
  @moduledoc """
  Prompt template loading and expansion.

  Mirrors upstream pi-mono's `prompt-templates.ts`. Templates are `.md`
  files in `{agent_dir}/prompts/` (global) and `{cwd}/.pi/prompts/`
  (project). Frontmatter provides optional `description` and
  `argument-hint`. Argument placeholders `$1`, `$@`, `$ARGUMENTS`, and
  `${@:N}` / `${@:N:L}` are substituted on expansion.
  """

  @config_dir ".pi"
  @max_desc_len 60

  @type template :: %{
          name: String.t(),
          description: String.t(),
          content: String.t(),
          argument_hint: String.t() | nil
        }

  @doc """
  Load all templates for `cwd`.

  Scans `{agent_dir}/prompts/` and `{cwd}/.pi/prompts/` for `.md` files
  (non-recursive). `agent_dir` may be `nil` to skip global loading.
  """
  @spec load_all(String.t(), String.t() | nil) :: [template()]
  def load_all(cwd, agent_dir) do
    global_dir = agent_dir && Path.join(agent_dir, "prompts")
    project_dir = Path.join([cwd, @config_dir, "prompts"])

    global = if global_dir, do: load_from_dir(global_dir), else: []
    project = load_from_dir(project_dir)

    global ++ project
  end

  @doc """
  Expand `/template-name args` if a matching template exists.

  Returns the expanded content, or the original text unchanged if no
  template is found or the text does not start with `/`.
  """
  @spec expand(String.t(), [template()]) :: String.t()
  def expand(text, templates) do
    with true <- String.starts_with?(text, "/"),
         {name, args_str} <- split_slash_command(text),
         template when not is_nil(template) <- Enum.find(templates, &(&1.name == name)) do
      args = parse_args(args_str)
      substitute_args(template.content, args)
    else
      _ -> text
    end
  end

  defp split_slash_command("/" <> rest) do
    case :binary.match(rest, " ") do
      {pos, _} -> {String.slice(rest, 0, pos), String.slice(rest, pos + 1, byte_size(rest))}
      :nomatch -> {rest, ""}
    end
  end

  @doc """
  Parse a shell-style argument string into a list of strings.

  Double- and single-quoted strings are treated as single arguments.
  Spaces and tabs act as delimiters. Empty (unquoted) tokens are
  skipped; empty quoted tokens are skipped too unless they contain
  content (e.g. `" "` produces `[" "]`).
  """
  @spec parse_args(String.t()) :: [String.t()]
  def parse_args(input) do
    input
    |> tokenize(nil, "")
    |> Enum.filter(&(&1 != ""))
  end

  defp tokenize("", nil, current) do
    if current == "", do: [], else: [current]
  end

  defp tokenize("", _quote, current) do
    if current == "", do: [], else: [current]
  end

  defp tokenize(<<q::utf8, rest::binary>>, nil, current) when q in [?", ?'] do
    tokenize(rest, <<q::utf8>>, current)
  end

  defp tokenize(<<q::utf8, rest::binary>>, <<q::utf8>>, current) do
    tokenize(rest, nil, current)
  end

  defp tokenize(<<c::utf8, rest::binary>>, nil, current) when c in [?\s, ?\t] do
    if current == "", do: tokenize(rest, nil, ""), else: [current | tokenize(rest, nil, "")]
  end

  defp tokenize(<<c::utf8, rest::binary>>, quote, current) do
    tokenize(rest, quote, current <> <<c::utf8>>)
  end

  @doc """
  Substitute argument placeholders in `content`.

  Supported:
  - `$1`, `$2`, … — 1-indexed positional args; out-of-range → `""`
  - `$@` / `$ARGUMENTS` — all args joined with space
  - `${@:N}` — args from N onward (1-indexed; 0 → all)
  - `${@:N:L}` — L args starting from N (1-indexed)

  Substitution is non-recursive: argument values are never re-scanned.
  """
  @spec substitute_args(String.t(), [String.t()]) :: String.t()
  def substitute_args(content, args) do
    all_args = Enum.join(args, " ")

    content
    |> sub_positional(args)
    |> sub_slice(args)
    |> sub_wildcard(all_args)
  end

  defp sub_positional(content, args) do
    Regex.replace(~r/\$(\d+)/, content, fn _, num ->
      idx = String.to_integer(num) - 1
      if idx >= 0, do: Enum.at(args, idx, ""), else: ""
    end)
  end

  defp sub_slice(content, args) do
    Regex.replace(~r/\$\{@:(\d+)(?::(\d+))?\}/, content, fn _, start_str, len_str ->
      start = max(0, String.to_integer(start_str) - 1)

      case len_str do
        "" -> args |> Enum.drop(start) |> Enum.join(" ")
        s -> args |> Enum.slice(start, String.to_integer(s)) |> Enum.join(" ")
      end
    end)
  end

  defp sub_wildcard(content, all_args) do
    content
    |> String.replace("$ARGUMENTS", all_args)
    |> String.replace("$@", all_args)
  end

  defp load_from_dir(dir) do
    case File.ls(dir) do
      {:error, _} ->
        []

      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&load_file_entry(dir, &1))
    end
  end

  defp load_file_entry(dir, filename) do
    path = Path.join(dir, filename)
    if File.regular?(path), do: load_template(path), else: []
  end

  defp load_template(path) do
    case File.read(path) do
      {:error, _} ->
        []

      {:ok, raw} ->
        {fm, body} = parse_frontmatter(raw)
        name = Path.basename(path, ".md")
        description = description_for(fm, body)
        hint = non_empty(Map.get(fm, "argument-hint"))

        [%{name: name, description: description, content: body, argument_hint: hint}]
    end
  end

  defp description_for(fm, body) do
    case non_empty(Map.get(fm, "description")) do
      nil -> first_line_truncated(body)
      desc -> desc
    end
  end

  defp first_line_truncated(body) do
    line =
      body
      |> String.split("\n")
      |> Enum.find("", &(String.trim(&1) != ""))

    if String.length(line) > @max_desc_len do
      String.slice(line, 0, @max_desc_len) <> "..."
    else
      line
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(v), do: v

  defp parse_frontmatter(content) do
    normalized = content |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    with true <- String.starts_with?(normalized, "---"),
         {pos, _} <- :binary.match(normalized, "\n---", scope: {3, byte_size(normalized) - 3}) do
      yaml_str = String.slice(normalized, 4, pos - 4)
      body = normalized |> String.slice(pos + 4, byte_size(normalized)) |> String.trim_leading("\n")
      {parse_yaml_scalars(yaml_str), body}
    else
      _ -> {%{}, normalized}
    end
  end

  defp parse_yaml_scalars(yaml_str) do
    yaml_str
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^([A-Za-z0-9_-]+):\s*(.*)$/, String.trim(line)) do
        [_, key, value] -> Map.put(acc, key, value |> String.trim("\"") |> String.trim("'"))
        _ -> acc
      end
    end)
  end
end
