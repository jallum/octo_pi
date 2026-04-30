defmodule OctoPi.TUI.InteractiveCompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Event.CompactionEnd
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: TUICSM
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp ok_event(tokens_before, summary) do
    %CompactionEnd{
      reason: :manual,
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

  describe "handle_event — Coder.Event.CompactionEnd (success appends marker)" do
    test "appends a CompactionSummaryMessage to existing transcript (does not wipe)" do
      existing = [%AssistantMessage{}, %AssistantMessage{}]
      state = %Interactive{transcript: existing, theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(50, "done")})

      assert length(state2.transcript) == 3
      assert [%AssistantMessage{}, %AssistantMessage{}, %TUICSM{}] = state2.transcript
    end

    test "CompactionSummaryMessage carries tokens_before and summary from the event" do
      state = %Interactive{transcript: [], theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(99_000, "session summary here")})

      [%TUICSM{message: msg}] = state2.transcript
      assert msg.tokens_before == 99_000
      assert msg.summary == "session summary here"
    end

    test "cancelled compaction leaves transcript unchanged" do
      existing = [%AssistantMessage{}]
      state = %Interactive{transcript: existing, theme: @theme}
      event = %CompactionEnd{reason: :manual, result: {:cancel, "user said no"}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == existing
    end

    test "failed compaction leaves transcript unchanged" do
      existing = [%AssistantMessage{}]
      state = %Interactive{transcript: existing, theme: @theme}
      event = %CompactionEnd{reason: :manual, result: {:error, :no_model}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == existing
    end

    test "successful compaction works without a theme (uses default dark theme)" do
      state = %Interactive{transcript: [], theme: nil}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(42, "fallback")})

      assert [%TUICSM{} = csm] = state2.transcript
      assert csm.message.tokens_before == 42
    end

    test "restores stashed loader on completion (existing behavior preserved)" do
      alias OctoPi.TUI.Components.Loader
      stashed = Loader.new(message: "Thinking…")
      state = %Interactive{transcript: [], theme: @theme, loader_stash: stashed, is_compacting?: true}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(10, "ok")})

      assert state2.loader == stashed
      assert state2.loader_stash == nil
      assert state2.is_compacting? == false
    end
  end
end
