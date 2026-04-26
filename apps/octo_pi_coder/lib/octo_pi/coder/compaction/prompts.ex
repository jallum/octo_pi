defmodule OctoPi.Coder.Compaction.Prompts do
  @moduledoc """
  Verbatim summarization prompt strings.

  Sources (read implementation, not docs):
  - `system/0`        — `tmp/pi-mono/.../compaction/utils.ts:168-170`
  - `summarize/0`     — `tmp/pi-mono/.../compaction/compaction.ts:454-485`
  - `update/0`        — `compaction.ts:487-524`
  - `turn_prefix/0`   — `compaction.ts:695-708`

  `branch_summary/0` is added by F4 (opi-ixp.31), keeping every
  summarization prompt in one place.
  """

  @system """
  You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

  Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.\
  """

  @summarize """
  The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

  Use this EXACT format:

  ## Goal
  [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

  ## Constraints & Preferences
  - [Any constraints, preferences, or requirements mentioned by user]
  - [Or "(none)" if none were mentioned]

  ## Progress
  ### Done
  - [x] [Completed tasks/changes]

  ### In Progress
  - [ ] [Current work]

  ### Blocked
  - [Issues preventing progress, if any]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Next Steps
  1. [Ordered list of what should happen next]

  ## Critical Context
  - [Any data, examples, or references needed to continue]
  - [Or "(none)" if not applicable]

  Keep each section concise. Preserve exact file paths, function names, and error messages.\
  """

  @update """
  The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

  Update the existing structured summary with new information. RULES:
  - PRESERVE all existing information from the previous summary
  - ADD new progress, decisions, and context from the new messages
  - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
  - UPDATE "Next Steps" based on what was accomplished
  - PRESERVE exact file paths, function names, and error messages
  - If something is no longer relevant, you may remove it

  Use this EXACT format:

  ## Goal
  [Preserve existing goals, add new ones if the task expanded]

  ## Constraints & Preferences
  - [Preserve existing, add new ones discovered]

  ## Progress
  ### Done
  - [x] [Include previously done items AND newly completed items]

  ### In Progress
  - [ ] [Current work - update based on progress]

  ### Blocked
  - [Current blockers - remove if resolved]

  ## Key Decisions
  - **[Decision]**: [Brief rationale] (preserve all previous, add new)

  ## Next Steps
  1. [Update based on current state]

  ## Critical Context
  - [Preserve important context, add new if needed]

  Keep each section concise. Preserve exact file paths, function names, and error messages.\
  """

  @turn_prefix """
  This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

  Summarize the prefix to provide context for the retained suffix:

  ## Original Request
  [What did the user ask for in this turn?]

  ## Early Progress
  - [Key decisions and work done in the prefix]

  ## Context for Suffix
  - [Information needed to understand the retained recent work]

  Be concise. Focus on what's needed to understand the kept suffix.\
  """

  @spec system() :: String.t()
  def system, do: @system

  @spec summarize() :: String.t()
  def summarize, do: @summarize

  @spec update() :: String.t()
  def update, do: @update

  @spec turn_prefix() :: String.t()
  def turn_prefix, do: @turn_prefix
end
