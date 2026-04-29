# Compaction & Branch Summarization

LLMs have limited context windows. When conversations grow too long, pi uses compaction to summarize older content while preserving recent work. This page covers both auto-compaction and branch summarization.

**Source files**:

- [`apps/octo_pi_coder/lib/octo_pi/coder/compaction.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction.ex) - Auto-compaction logic
- [`apps/octo_pi_coder/lib/octo_pi/coder/compaction/branch_summarization.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/branch_summarization.ex) - Branch summarization
- [`apps/octo_pi_coder/lib/octo_pi/coder/compaction/file_ops.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/file_ops.ex) and [`apps/octo_pi_coder/lib/octo_pi/coder/compaction/serialize.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/serialize.ex) - Shared utilities (file tracking, serialization)
- [`apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex) - Entry types (`Entry.Compaction`, `Entry.BranchSummary`)
- [`apps/octo_pi_coder/lib/octo_pi/coder/extension/event.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/extension/event.ex) - Extension event types

## Overview

Pi has two summarization mechanisms:

| Mechanism            | Trigger                                  | Purpose                                   |
| -------------------- | ---------------------------------------- | ----------------------------------------- |
| Compaction           | Context exceeds threshold, or `/compact` | Summarize old messages to free up context |
| Branch summarization | `/tree` navigation                       | Preserve context when switching branches  |

Both use the same structured summary format and track file operations cumulatively.

## Compaction

### When It Triggers

Auto-compaction triggers when:

```
contextTokens > contextWindow - reserveTokens
```

`contextTokens` is taken from the most recent successful assistant's `usage`: prefer `usage.total_tokens` when the provider supplies a positive value, otherwise compute `input + output + cache_read + cache_write`. Cache reads count — a turn dominated by Anthropic prompt-cache hits can have a tiny `input` while still consuming most of the window.

When the most recent assistant is an error (no useful usage of its own), the trigger falls back to the most recent *prior* successful assistant whose timestamp is after the last compaction boundary; this keeps persistent provider errors (e.g. 529 overloaded) from masking a context that is already over the limit.

By default, `reserveTokens` is 16384 tokens (configurable in `~/.pi/agent/settings.json` or `<project-dir>/.pi/settings.json`). This leaves room for the LLM's response.

You can also trigger manually with `/compact [instructions]`, where optional instructions focus the summary.

### How It Works

1. **Find cut point**: Walk backwards from newest message, accumulating token estimates until `keepRecentTokens` (default 20k, configurable in `~/.pi/agent/settings.json` or `<project-dir>/.pi/settings.json`) is reached
2. **Extract messages**: Collect messages from the previous kept boundary (or session start) up to the cut point
3. **Generate summary**: Call LLM to summarize with structured format, passing the previous summary as iterative context when present
4. **Append entry**: Save `CompactionEntry` with summary and `firstKeptEntryId`
5. **Reload**: Session reloads, using summary + messages from `firstKeptEntryId` onwards

```
Before compaction:

  entry:  0     1     2     3      4     5     6      7      8     9
        ┌─────┬─────┬─────┬──────┬─────┬─────┬──────┬──────┬─────┬─────┐
        │ hdr │ usr │ ass │ tool │ usr │ ass │ tool │ tool │ ass │ tool│
        └─────┴─────┴─────┴──────┴─────┴─────┴──────┴──────┴─────┴─────┘
                └────────┬───────┘ └──────────────┬──────────────┘
               messagesToSummarize            kept messages
                                   ↑
                          firstKeptEntryId (entry 4)

After compaction (new entry appended):

  entry:  0     1     2     3      4     5     6      7      8     9     10
        ┌─────┬─────┬─────┬──────┬─────┬─────┬──────┬──────┬─────┬─────┬─────┐
        │ hdr │ usr │ ass │ tool │ usr │ ass │ tool │ tool │ ass │ tool│ cmp │
        └─────┴─────┴─────┴──────┴─────┴─────┴──────┴──────┴─────┴─────┴─────┘
               └──────────┬──────┘ └──────────────────────┬───────────────────┘
                 not sent to LLM                    sent to LLM
                                                         ↑
                                              starts from firstKeptEntryId

What the LLM sees:

  ┌────────┬─────────┬─────┬─────┬──────┬──────┬─────┬──────┐
  │ system │ summary │ usr │ ass │ tool │ tool │ ass │ tool │
  └────────┴─────────┴─────┴─────┴──────┴──────┴─────┴──────┘
       ↑         ↑      └─────────────────┬────────────────┘
    prompt   from cmp          messages from firstKeptEntryId
```

On repeated compactions, the summarized span starts at the previous compaction's kept boundary (`firstKeptEntryId`), not at the compaction entry itself, falling back to the entry after the previous compaction if that kept entry cannot be found in the path. This preserves messages that survived the earlier compaction by including them in the next summarization pass as well. Pi also recalculates `tokensBefore` from the rebuilt session context before writing the new `CompactionEntry`, so the token count reflects the actual pre-compaction context being replaced.

### Split Turns

A "turn" starts with a user message and includes all assistant responses and tool calls until the next user message. Normally, compaction cuts at turn boundaries.

When a single turn exceeds `keepRecentTokens`, the cut point lands mid-turn at an assistant message. This is a "split turn":

```
Split turn (one huge turn exceeds budget):

  entry:  0     1     2      3     4      5      6     7      8
        ┌─────┬─────┬─────┬──────┬─────┬──────┬──────┬─────┬──────┐
        │ hdr │ usr │ ass │ tool │ ass │ tool │ tool │ ass │ tool │
        └─────┴─────┴─────┴──────┴─────┴──────┴──────┴─────┴──────┘
                ↑                                     ↑
         turnStartIndex = 1                  firstKeptEntryId = 7
                │                                     │
                └──── turnPrefixMessages (1-6) ───────┘
                                                      └── kept (7-8)

  isSplitTurn = true
  messagesToSummarize = []  (no complete turns before)
  turnPrefixMessages = [usr, ass, tool, ass, tool, tool]
```

For split turns, pi generates two summaries and merges them:

1. **History summary**: Previous context (if any). Uses the full `reserveTokens` budget. When there is no completed earlier history (the cut lands inside the very first turn), this call is short-circuited to the literal sentinel `No prior history.` rather than invoking the model.
2. **Turn prefix summary**: The early part of the split turn. Uses a smaller budget — `0.5 × reserveTokens` — since it only has to cover one turn's prefix.

The two calls run in parallel, and their bodies are joined with the literal separator:

```
\n\n---\n\n**Turn Context (split turn):**\n\n
```

Both the separator and the `No prior history.` sentinel appear verbatim in the resulting summary, so they are greppable in stored sessions.

### Cut Point Rules

Valid cut points fall into two categories.

Message-role cut points (entry type `message`, with one of these roles): `user`, `assistant`, `bashExecution`, `custom`, `branchSummary`, `compactionSummary`.

Entry-type cut points (treated as user-role for turn-start purposes): `Entry.BranchSummary` (`branch_summary`) and `Entry.CustomMessage` (`custom_message`). `Entry.Custom` (entry type `custom`) is intentionally excluded — it is distinct from the `custom` message role and is never a cut point.

Never cut at tool results (they must stay with their tool call).

### Absorbing Preceding State Changes

After a cut point is chosen, the algorithm walks backwards from the entry just before the cut and pulls any non-message, non-compaction entries — `model_change`, `thinking_level_change`, `label`, `session_info`, and `Entry.Custom` — into the kept window. The walk halts at a compaction boundary or any message-bearing entry (including `Entry.BranchSummary` and `Entry.CustomMessage`). This keeps state-change entries that immediately precede the kept messages traveling with them, so their effect (e.g. a model or thinking-level switch) isn't orphaned in the summarized history where it would no longer apply to the kept turn.

### CompactionEntry Structure

Defined in [`apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex):

```elixir
defmodule OctoPi.Coder.Session.Entry.Compaction do
  defstruct [
    :id,
    :parent_id,
    :timestamp,
    :summary,
    :first_kept_entry_id,
    :tokens_before,
    :from_hook,
    :details,
    extras: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          summary: String.t(),
          first_kept_entry_id: String.t(),
          tokens_before: non_neg_integer(),
          from_hook: boolean() | nil,
          # implementation-specific data
          details: term() | nil,
          extras: %{optional(String.t()) => term()}
        }
end

# Default compaction stores file ops in `details` as a wire-shape map
# (see `OctoPi.Coder.Compaction.Result`):
%{"readFiles" => ["foo.ex"], "modifiedFiles" => ["bar.ex"]}
```

Extensions can store any JSON-serializable data in `details`. The default compaction tracks file operations, but custom extension implementations can use their own structure.

See [`OctoPi.Coder.Compaction.Preparation`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/preparation.ex) and [`OctoPi.Coder.Compaction.compact/3`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction.ex) for the implementation.

## Branch Summarization

### When It Triggers

When you use `/tree` to navigate to a different branch, pi offers to summarize the work you're leaving. This injects context from the left branch into the new branch.

### How It Works

1. **Find common ancestor**: Deepest node shared by old and new positions
2. **Collect entries**: Walk from old leaf back to common ancestor. Unlike auto-compaction — where a `Compaction` entry acts as a hard left-edge for the kept window — this walk does **not** stop at compaction boundaries. Any `Compaction` or `BranchSummary` entries on the path are included; during message conversion they are reconstituted as synthetic summary messages so their stored summary text feeds into the new branch summary as context.
3. **Prepare with budget**: Include messages up to token budget (newest first)
4. **Generate summary**: Call LLM with structured format
5. **Append entry**: Save `BranchSummaryEntry` at navigation point

### Token Budget

The budget for step 3 is `model.context_window - reserve_tokens`. While walking entries newest-first, two rules shape what gets admitted:

- **Tool-result messages are skipped unconditionally.** They are always paired with the assistant message that requested them, and the prepared transcript reconstructs them from that side; including them again would double-count tokens.
- **Prior summary entries get a privileged admission rule.** When admitting a `Compaction` or `BranchSummary` entry would push the running total past the budget, it is still admitted as long as the running total is below `0.9 × token_budget` at that point; the walk then halts. Non-summary entries that would overflow simply halt the walk without being admitted. Prior summaries are dense, high-value context, so it is preferable to slightly overshoot the budget than to drop the most informative entries on the path.

```
Tree before navigation:

         ┌─ B ─ C ─ D (old leaf, being abandoned)
    A ───┤
         └─ E ─ F (target)

Common ancestor: A
Entries to summarize: B, C, D

After navigation with summary:

         ┌─ B ─ C ─ D ─ [summary of B,C,D]
    A ───┤
         └─ E ─ F (new leaf)
```

### Cumulative File Tracking

Both compaction and branch summarization track files cumulatively. When generating a summary, pi extracts file operations from:

- Tool calls in the messages being summarized
- Previous compaction or branch summary `details` (if any)

This means file tracking accumulates across multiple compactions or nested branch summaries, preserving the full history of read and modified files.

There is one exception: prior summary entries with `from_hook: true` are skipped when extracting cumulative file ops. A `from_hook: true` flag means the summary was produced by an extension's `:session_before_compact` or `:session_before_tree` hook returning `{:override, ...}`, and the extension is free to put any JSON-serializable shape into `details` — so the default tracker cannot assume the standard `readFiles` / `modifiedFiles` keys are present and conservatively ignores that entry rather than risk reading garbage. The practical consequence for extension authors: file tracking effectively resets after every hook-generated summary. If you want the `<read-files>` / `<modified-files>` blocks at the bottom of the next pi-generated summary to reflect prior reads and edits, the cleanest path is to let pi handle compaction / branch summarization when you can, since `from_hook` is provenance and is not meant to be lied about.

### BranchSummaryEntry Structure

Defined in [`apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/session/entry.ex):

```elixir
defmodule OctoPi.Coder.Session.Entry.BranchSummary do
  defstruct [
    :id,
    :parent_id,
    :timestamp,
    # Entry we navigated from
    :from_id,
    :summary,
    :from_hook,
    :details,
    extras: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          from_id: String.t(),
          summary: String.t(),
          from_hook: boolean() | nil,
          # implementation-specific data
          details: term() | nil,
          extras: %{optional(String.t()) => term()}
        }
end

# Default branch summarization populates `details` with file ops.
# Note the dual shape: the in-process `%BranchSummaryResult{}` struct
# returned by `BranchSummarization.generate/2` uses snake-case fields
# `:read_files` / `:modified_files`, but the persisted `details` map
# on a `BranchSummary` entry uses string keys `"readFiles"` /
# `"modifiedFiles"` — the same wire shape as `CompactionEntry.details`.
```

Same as compaction, extensions can store custom data in `details`.

See [`OctoPi.Coder.SessionManager.collect_entries_for_branch_summary/3`](../apps/octo_pi_coder/lib/octo_pi/coder/session_manager.ex), [`OctoPi.Coder.Compaction.BranchSummarization.prepare/2`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/branch_summarization.ex), and [`OctoPi.Coder.Compaction.BranchSummarization.generate/2`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/branch_summarization.ex) for the implementation.

## Summary Format

Both compaction and branch summarization use the same structured format:

```markdown
## Goal

[What the user is trying to accomplish]

## Constraints & Preferences

- [Requirements mentioned by user]

## Progress

### Done

- [x] [Completed tasks]

### In Progress

- [ ] [Current work]

### Blocked

- [Issues, if any]

## Key Decisions

- **[Decision]**: [Rationale]

## Next Steps

1. [What should happen next]

## Critical Context

- [Data needed to continue]

<read-files>
path/to/file1.ts
path/to/file2.ts
</read-files>

<modified-files>
path/to/changed.ts
</modified-files>
```

The model is only asked to produce the prose body — `## Goal` through `## Critical Context`. The `<read-files>` and `<modified-files>` blocks are not model output; pi appends them deterministically after the LLM call, so their tag shape and ordering are stable across summaries. The file lists themselves are computed from tool calls extracted from the messages being summarized, merged with any file ops carried over from the previous summary's `details`.

Branch summaries additionally get a fixed preamble prepended before the prose body — a short note explaining that the user explored a different conversation branch before returning. Compaction summaries do not get a preamble. The preamble exists so a reader of the new branch sees framing context about the abandoned exploration before the structured summary that follows. The on-disk shape of a stored branch summary is therefore preamble + LLM body + appended file blocks; a stored compaction summary is just LLM body + appended file blocks.

### Message Serialization

Before summarization, messages are serialized to text via [`OctoPi.Coder.Compaction.Serialize.conversation/1`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/serialize.ex):

```
[User]: What they said
[Assistant thinking]: Internal reasoning
[Assistant]: Response text
[Assistant tool calls]: read(path="foo.ts"); edit(path="bar.ts", ...)
[Tool result]: Output from tool
```

This prevents the model from treating it as a conversation to continue.

Tool results are truncated to 2000 characters during serialization. Content beyond that limit is replaced with a marker indicating how many characters were truncated. This keeps summarization requests within reasonable token budgets, since tool results (especially from `read` and `bash`) are typically the largest contributors to context size.

## Custom Summarization via Extensions

Extensions can intercept and customize both compaction and branch summarization. See [`apps/octo_pi_coder/lib/octo_pi/coder/extension/event.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/extension/event.ex) for event type definitions.

### session_before_compact

Fired before auto-compaction or `/compact`. Can cancel or provide custom summary. The event payload is a plain map `%{preparation: %OctoPi.Coder.Compaction.Preparation{}, custom_instructions: String.t() | nil}`; see [`OctoPi.Coder.Compaction.Preparation`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/preparation.ex) for the preparation struct.

```elixir
alias OctoPi.Coder.Compaction.Result
alias OctoPi.Coder.Extension.API

API.on(api, :session_before_compact, fn event, ctx ->
  %{preparation: prep, custom_instructions: _custom} = event

  # prep.messages_to_summarize - messages to summarize
  # prep.turn_prefix_messages  - split turn prefix (if cut was a split turn)
  # prep.previous_summary      - previous compaction summary
  # prep.file_ops              - extracted file operations
  # prep.tokens_before         - context tokens before compaction
  # prep.first_kept_entry_id   - where kept messages start

  # ctx exposes session/model helpers (see `Extension.Context`)

  # Cancel:
  {:cancel, :user_declined}

  # Custom summary:
  {:override,
   %Result{
     summary: "Your summary...",
     first_kept_entry_id: prep.first_kept_entry_id,
     tokens_before: prep.tokens_before,
     # custom data
     details: %{}
   }}
end)
```

#### Converting Messages to Text

To generate a summary with your own model, convert messages to text using `serializeConversation`:

```elixir
alias OctoPi.Coder.Compaction.Result
alias OctoPi.Coder.Compaction.Serialize
alias OctoPi.Coder.Extension.API
alias OctoPi.Coder.Session.Messages

API.on(api, :session_before_compact, fn %{preparation: prep}, _ctx ->
  # Convert agent messages to LLM messages, then serialize to text
  conversation_text =
    prep.messages_to_summarize
    |> Messages.to_llm()
    |> Serialize.conversation()

  # Returns:
  # [User]: message text
  # [Assistant thinking]: thinking content
  # [Assistant]: response text
  # [Assistant tool calls]: read(path="..."); bash(command="...")
  # [Tool result]: output text

  # Now send to your model for summarization
  summary = MyModel.summarize(conversation_text)

  {:override,
   %Result{
     summary: summary,
     first_kept_entry_id: prep.first_kept_entry_id,
     tokens_before: prep.tokens_before
   }}
end)
```

See [`apps/octo_pi_coder/lib/octo_pi/coder/extensions/custom_compaction.ex`](../apps/octo_pi_coder/lib/octo_pi/coder/extensions/custom_compaction.ex) for a complete example using a different model.

### session_before_tree

Fired before `/tree` navigation. Always fires regardless of whether user chose to summarize. Can cancel navigation or provide custom summary.

```elixir
alias OctoPi.Coder.Compaction.BranchSummaryResult
alias OctoPi.Coder.Extension.API

API.on(api, :session_before_tree, fn %{preparation: prep}, _ctx ->
  # prep.target_id            - where we're navigating to
  # prep.old_leaf_id          - current position (being abandoned)
  # prep.common_ancestor_id   - shared ancestor
  # prep.entries_to_summarize - entries that would be summarized
  # prep.user_wants_summary   - :no | :yes | {:yes, instructions}

  # Cancel navigation entirely:
  {:cancel, :user_declined}

  # Provide custom summary (only used if user_wants_summary != :no):
  case prep.user_wants_summary do
    :no ->
      :ok

    _ ->
      {:override,
       %BranchSummaryResult{
         summary: "Your summary...",
         read_files: [],
         modified_files: []
       }}
  end
end)
```

The event payload is a plain map `%{preparation: %OctoPi.Coder.Compaction.TreePreparation{}}`; see [`OctoPi.Coder.Compaction.TreePreparation`](../apps/octo_pi_coder/lib/octo_pi/coder/compaction/tree_preparation.ex) for the preparation struct.

## Settings

Configure compaction in `~/.pi/agent/settings.json` or `<project-dir>/.pi/settings.json`:

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

| Setting            | Default | Description                            |
| ------------------ | ------- | -------------------------------------- |
| `enabled`          | `true`  | Enable auto-compaction                 |
| `reserveTokens`    | `16384` | Tokens to reserve for LLM response     |
| `keepRecentTokens` | `20000` | Recent tokens to keep (not summarized) |

The JSON keys translate to snake-case fields on the runtime `%Compaction.Settings{}` struct: `reserveTokens` ↔ `:reserve_tokens`, `keepRecentTokens` ↔ `:keep_recent_tokens`, `enabled` ↔ `:enabled`. Extension code that reads `prep.settings.<field>` (for example in `:session_before_compact` hooks) must use the snake-case atom names; reading the camelCase form returns `nil`.

Disable auto-compaction with `"enabled": false`. You can still compact manually with `/compact`.
