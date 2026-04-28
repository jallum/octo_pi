defmodule OctoPi.TUI.InteractiveCompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: TUICSM
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp ok_event(tokens_before, summary) do
    %Event.CompactionEnd{
      result:
        {:ok,
         %{
           tokens_before: tokens_before,
           summary: summary,
           first_kept_entry_id: "entry-1",
           details: nil,
           from_extension?: false
         }}
    }
  end

  describe "handle_event — CompactionEnd (interactive-mode-compaction.test.ts parity)" do
    test "successful compaction appends a CompactionSummaryMessage TUI component" do
      state = %Interactive{transcript: [], theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(123, "summary")})

      assert [%TUICSM{} = csm] = state2.transcript
      assert csm.message.tokens_before == 123
      assert csm.message.summary == "summary"
    end

    test "successful compaction clears previous transcript entries" do
      existing = [%AssistantMessage{}, %AssistantMessage{}]
      state = %Interactive{transcript: existing, theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(50, "done")})

      assert length(state2.transcript) == 1
      assert [%TUICSM{}] = state2.transcript
    end

    test "CompactionSummaryMessage carries tokens_before and summary from the event" do
      state = %Interactive{transcript: [], theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(99_000, "session summary here")})

      [%TUICSM{message: msg}] = state2.transcript
      assert msg.tokens_before == 99_000
      assert msg.summary == "session summary here"
    end

    test "cancelled compaction leaves transcript unchanged" do
      state = %Interactive{transcript: [], theme: @theme}
      event = %Event.CompactionEnd{result: {:cancel, "user said no"}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == []
    end

    test "failed compaction leaves transcript unchanged" do
      state = %Interactive{transcript: [], theme: @theme}
      event = %Event.CompactionEnd{result: {:error, :no_model}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == []
    end

    test "successful compaction works without a theme (uses default dark theme)" do
      state = %Interactive{transcript: [], theme: nil}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(42, "fallback")})

      assert [%TUICSM{} = csm] = state2.transcript
      assert csm.message.tokens_before == 42
    end
  end
end
