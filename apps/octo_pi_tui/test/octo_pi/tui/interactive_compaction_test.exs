defmodule OctoPi.TUI.InteractiveCompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Event.CompactionEnd
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: TUICSM
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Transcript

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
      # Seed the transcript with two prior CompactionSummaryMessage entries
      # (any prior entries; CSM is convenient because it needs no agent
      # context). The test asserts compaction *appends* — it doesn't wipe.
      seeded =
        %Transcript{}
        |> Transcript.append("a", %TUICSM{}, OctoPi.TUI.Transcript.ComponentWrapper)
        |> Transcript.append("b", %TUICSM{}, OctoPi.TUI.Transcript.ComponentWrapper)

      state = %Interactive{transcript: seeded, theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(50, "done")})

      assert length(state2.transcript.order) == 3
      assert [%TUICSM{}, %TUICSM{}, %TUICSM{}] = Interactive.transcript_entries(state2)
    end

    test "CompactionSummaryMessage carries tokens_before and summary from the event" do
      state = %Interactive{transcript: %Transcript{}, theme: @theme}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(99_000, "session summary here")})

      [%TUICSM{message: msg}] = Interactive.transcript_entries(state2)
      assert msg.tokens_before == 99_000
      assert msg.summary == "session summary here"
    end

    test "cancelled compaction leaves transcript unchanged" do
      seeded = Transcript.append(%Transcript{}, "a", %TUICSM{}, OctoPi.TUI.Transcript.ComponentWrapper)
      state = %Interactive{transcript: seeded, theme: @theme}
      event = %CompactionEnd{reason: :manual, result: {:cancel, "user said no"}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == seeded
    end

    test "failed compaction leaves transcript unchanged" do
      seeded = Transcript.append(%Transcript{}, "a", %TUICSM{}, OctoPi.TUI.Transcript.ComponentWrapper)
      state = %Interactive{transcript: seeded, theme: @theme}
      event = %CompactionEnd{reason: :manual, result: {:error, :no_model}}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, event})

      assert state2.transcript == seeded
    end

    test "successful compaction works without a theme (uses default dark theme)" do
      state = %Interactive{transcript: %Transcript{}, theme: nil}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(42, "fallback")})

      assert [%TUICSM{} = csm] = Interactive.transcript_entries(state2)
      assert csm.message.tokens_before == 42
    end

    test "restores stashed loader on completion (existing behavior preserved)" do
      alias OctoPi.TUI.Components.Loader
      stashed = Loader.new(message: "Thinking…")
      state = %Interactive{transcript: %Transcript{}, theme: @theme, loader_stash: stashed, is_compacting?: true}
      state2 = Interactive.handle_event(state, {:octo_pi_agent_event, ok_event(10, "ok")})

      assert state2.loader == stashed
      assert state2.loader_stash == nil
      assert state2.is_compacting? == false
    end
  end
end
