#!/usr/bin/env elixir
# Analyzes mix xref graph JSON output to surface dead-code candidates.
# Usage: elixir .claude/commands/dead-code.exs [xref_graph.json]

path = System.argv() |> List.first() || "xref_graph.json"

graph =
  path
  |> File.read!()
  |> :json.decode()

# Build a reverse (callers) map so we can detect unreferenced files.
incoming =
  Enum.reduce(graph, %{}, fn {src, deps}, acc ->
    acc = Map.put_new(acc, src, [])
    Enum.reduce(deps, acc, fn {dst, _kind}, a -> Map.update(a, dst, [src], &[src | &1]) end)
  end)

unreferenced = for {file, []} <- incoming, do: file

classify = fn file ->
  cond do
    String.contains?(file, "/mix/tasks/") -> :task
    String.ends_with?(file, "application.ex") -> :application
    # Extensions are loaded by path at runtime — xref can't track them.
    String.contains?(file, "/extensions/") or String.contains?(file, "/extension/") -> :extension
    String.ends_with?(file, "_test.ex") -> :test
    true -> :candidate
  end
end

grouped =
  unreferenced
  |> Enum.group_by(classify)
  |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)

candidates = Map.get(grouped, :candidate, [])

noise = [
  {:task, "Mix tasks", "entry points — not reachable via compile graph"},
  {:application, "Application modules", "OTP entry points listed in mix.exs"},
  {:extension, "Extension modules", "loaded by file path at runtime; xref cannot track them"},
  {:test, "Test files", "not part of the compiled application"}
]

active_noise =
  Enum.filter(noise, fn {key, _label, _reason} ->
    grouped |> Map.get(key, []) |> length() > 0
  end)

footnote_refs =
  active_noise
  |> Enum.with_index(1)
  |> Map.new(fn {{key, _label, _reason}, idx} -> {key, idx} end)

IO.puts("Dead-code candidates (#{length(candidates)} files with no incoming compile/export/runtime edges)\n")

if candidates == [] do
  IO.puts("  (none)")
else
  Enum.each(candidates, &IO.puts("  #{&1}"))
end

IO.puts("\n#{map_size(graph)} files in graph; #{Enum.sum(for {k, _, _} <- active_noise, do: length(Map.get(grouped, k, [])))} suppressed[^suppressed]\n")

IO.puts("[^suppressed]: False-positive categories excluded from the report above:")
IO.puts("")

for {key, label, reason} <- active_noise do
  files = Map.get(grouped, key, [])
  ref = footnote_refs[key]
  IO.puts("  **[#{ref}] #{label}** (#{length(files)} files) — #{reason}:")
  Enum.each(files, &IO.puts("  - `#{&1}`"))
  IO.puts("")
end
