# /dead-code

Find dead-code candidates using `mix xref graph`. A file is a candidate if nothing in the graph references it at compile, export, or runtime level. Known false-positive categories (Mix tasks, Application modules, extension modules loaded by path) are excluded from the report.

## Steps

1. Run from the repo root:

   ```bash
   mix xref graph --format json
   ```

   This writes `xref_graph.json` in the current directory.

2. Run the analysis script:

   ```bash
   elixir .claude/commands/dead-code.exs
   ```

   The script reads `xref_graph.json`, builds a reverse-reference map, finds unreferenced files, classifies them, and prints the candidate list.

3. For each candidate file, read it and decide:
   - **Genuinely dead** — module is never called; present a removal proposal.
   - **Ported but not yet wired** — module exists in the graph but hasn't been integrated; flag as "not yet used."
   - **Public API / boundary** — module is the external surface of an app (e.g., a top-level `OctoPi.TUI` façade); note it as intentional.

4. Report findings grouped by app (`apps/<name>`), with one line per file and a short disposition note.

## Notes

- Extension modules under `lib/…/extensions/` and `lib/…/extension/` are loaded by file path at runtime via `Code.require_file` or similar; xref will always report them as unreferenced. They are excluded automatically.
- `Application` modules are OTP entry points listed in `mix.exs`; same exclusion applies.
- The script requires `jason` to be available (it is — `jason` is a direct dep of this project).
- Re-run `mix xref graph --format json` whenever you want a fresh snapshot; the file is not committed.
