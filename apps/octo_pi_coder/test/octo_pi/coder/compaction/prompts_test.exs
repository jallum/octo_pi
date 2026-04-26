defmodule OctoPi.Coder.Compaction.PromptsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.Prompts

  test "system/0 matches upstream first sentence verbatim" do
    assert Prompts.system() =~
             "You are a context summarization assistant."

    assert Prompts.system() =~ "ONLY output the structured summary."
    refute String.ends_with?(Prompts.system(), "\n")
  end

  test "summarize/0 includes the EXACT format anchor sections" do
    p = Prompts.summarize()
    assert p =~ "## Goal"
    assert p =~ "## Constraints & Preferences"
    assert p =~ "## Progress"
    assert p =~ "### Done"
    assert p =~ "### In Progress"
    assert p =~ "### Blocked"
    assert p =~ "## Key Decisions"
    assert p =~ "## Next Steps"
    assert p =~ "## Critical Context"
    assert p =~ "Preserve exact file paths, function names, and error messages."
    refute String.ends_with?(p, "\n")
  end

  test "update/0 begins with the NEW-messages directive" do
    assert Prompts.update() =~
             "NEW conversation messages to incorporate into the existing summary"

    assert Prompts.update() =~ "<previous-summary>"
    refute String.ends_with?(Prompts.update(), "\n")
  end

  test "turn_prefix/0 matches the prefix-only summary template" do
    p = Prompts.turn_prefix()
    assert p =~ "PREFIX of a turn that was too large to keep"
    assert p =~ "## Original Request"
    assert p =~ "## Early Progress"
    assert p =~ "## Context for Suffix"
    refute String.ends_with?(p, "\n")
  end
end
