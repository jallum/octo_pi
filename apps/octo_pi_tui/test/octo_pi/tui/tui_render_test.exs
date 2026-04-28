defmodule OctoPi.TUI.TuiRenderTest do
  @moduledoc """
  End-to-end render tests ported from upstream tui-render.test.ts.

  Each test feeds frames through the Renderer and verifies the
  resulting screen via VirtualTerminal, exactly as upstream does
  with its VirtualTerminal + xterm headless.
  """

  use ExUnit.Case, async: true

  alias OctoPi.TUI.Renderer
  alias OctoPi.TUI.VirtualTerminal, as: VT

  # --- helpers ---

  defp setup_render(opts) do
    width = Keyword.get(opts, :width, 40)
    height = Keyword.get(opts, :height, 10)
    r = Renderer.new(width: width, height: height)
    vt = VT.new(width, height)
    {r, vt}
  end

  defp render_frame(r, vt, lines) do
    {bytes, r} = Renderer.render(r, lines)
    {r, VT.write(vt, bytes)}
  end

  defp visible(vt), do: VT.get_viewport(vt)

  # --- resize handling (upstream tui-render.test.ts L66-143) ---

  describe "resize handling" do
    test "height change triggers full redraw, content preserved" do
      {r, vt} = setup_render(width: 40, height: 10)
      {r, vt} = render_frame(r, vt, ["Line 0", "Line 1", "Line 2"])

      assert Enum.at(visible(vt), 0) == "Line 0"
      assert Enum.at(visible(vt), 1) == "Line 1"
      assert Enum.at(visible(vt), 2) == "Line 2"

      # Resize to taller terminal
      r = Renderer.resize(r, 40, 15)
      vt = VT.resize(vt, 40, 15)
      {_r, vt} = render_frame(r, vt, ["Line 0", "Line 1", "Line 2"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "Line 0"
      assert Enum.at(rows, 1) == "Line 1"
      assert Enum.at(rows, 2) == "Line 2"
      assert length(rows) == 15
    end

    test "width change triggers full redraw" do
      {r, vt} = setup_render(width: 40, height: 10)
      {r, vt} = render_frame(r, vt, ["short"])

      r = Renderer.resize(r, 60, 10)
      vt = VT.resize(vt, 60, 10)
      {_r, vt} = render_frame(r, vt, ["wider content now"])

      assert Enum.at(visible(vt), 0) == "wider content now"
    end
  end

  # --- content shrinkage (upstream tui-render.test.ts L146-225) ---

  describe "content shrinkage" do
    test "clears stale rows when content shrinks from 6 to 2" do
      {r, vt} = setup_render(height: 10)
      lines = Enum.map(0..5, &"Line #{&1}")
      {r, vt} = render_frame(r, vt, lines)

      assert Enum.at(visible(vt), 5) == "Line 5"

      {_r, vt} = render_frame(r, vt, ["Line 0", "Line 1"])
      rows = visible(vt)

      assert Enum.at(rows, 0) == "Line 0"
      assert Enum.at(rows, 1) == "Line 1"
      assert Enum.at(rows, 2) == ""
      assert Enum.at(rows, 3) == ""
      assert Enum.at(rows, 4) == ""
      assert Enum.at(rows, 5) == ""
    end

    test "handles shrink to single line" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["a", "b", "c", "d"])
      {_r, vt} = render_frame(r, vt, ["Only line"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "Only line"
      assert Enum.at(rows, 1) == ""
      assert Enum.at(rows, 2) == ""
      assert Enum.at(rows, 3) == ""
    end

    test "handles shrink to empty" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["a", "b", "c"])
      {_r, vt} = render_frame(r, vt, [])

      rows = visible(vt)
      assert Enum.all?(rows, &(&1 == ""))
    end
  end

  # --- differential rendering (upstream tui-render.test.ts L227-508) ---

  describe "differential rendering" do
    test "cursor tracking after shrink with unchanged remaining lines" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["a", "b", "c", "d", "e"])

      # Shrink to 3 lines (same content)
      {r, vt} = render_frame(r, vt, ["a", "b", "c"])

      # Change middle line — should render correctly despite shrink
      {_r, vt} = render_frame(r, vt, ["a", "X", "c"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "a"
      assert Enum.at(rows, 1) == "X"
      assert Enum.at(rows, 2) == "c"
    end

    test "only middle line changes — spinner animation" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["Header", "⠋ Working...", "Footer"])
      {r, vt} = render_frame(r, vt, ["Header", "⠙ Working...", "Footer"])
      {_r, vt} = render_frame(r, vt, ["Header", "⠹ Working...", "Footer"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "Header"
      assert Enum.at(rows, 1) == "⠹ Working..."
      assert Enum.at(rows, 2) == "Footer"
    end

    test "first line changes but rest stays same" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["aaa", "bbb", "ccc", "ddd"])
      {_r, vt} = render_frame(r, vt, ["XXX", "bbb", "ccc", "ddd"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "XXX"
      assert Enum.at(rows, 1) == "bbb"
      assert Enum.at(rows, 2) == "ccc"
      assert Enum.at(rows, 3) == "ddd"
    end

    test "last line changes but rest stays same" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["aaa", "bbb", "ccc", "ddd"])
      {_r, vt} = render_frame(r, vt, ["aaa", "bbb", "ccc", "XXX"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "aaa"
      assert Enum.at(rows, 1) == "bbb"
      assert Enum.at(rows, 2) == "ccc"
      assert Enum.at(rows, 3) == "XXX"
    end

    test "non-adjacent line changes preserve unchanged lines between" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["a", "b", "c", "d", "e"])
      {_r, vt} = render_frame(r, vt, ["a", "X", "c", "Y", "e"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "a"
      assert Enum.at(rows, 1) == "X"
      assert Enum.at(rows, 2) == "c"
      assert Enum.at(rows, 3) == "Y"
      assert Enum.at(rows, 4) == "e"
    end

    test "transition: content → empty → content" do
      {r, vt} = setup_render(height: 10)
      {r, vt} = render_frame(r, vt, ["hello", "world"])
      {r, vt} = render_frame(r, vt, [])
      {_r, vt} = render_frame(r, vt, ["back", "again"])

      rows = visible(vt)
      assert Enum.at(rows, 0) == "back"
      assert Enum.at(rows, 1) == "again"
      assert Enum.at(rows, 2) == ""
    end

    test "multi-component: chat + editor, stale lines cleared after transient inflation" do
      {r, vt} = setup_render(height: 12)

      # Initial: 6 chat lines + 3 editor lines = 9 total
      chat = Enum.map(0..5, &"Chat #{&1}")
      editor = ["───", "input text", "───"]
      {r, vt} = render_frame(r, vt, chat ++ editor)

      # Inflate: 15 chat lines + 3 editor = 18 (exceeds terminal height)
      big_chat = Enum.map(0..14, &"Chat #{&1}")
      {r, vt} = render_frame(r, vt, big_chat ++ editor)

      # Shrink back: 7 chat lines + 3 editor = 10
      small_chat = Enum.map(5..11, &"Chat #{&1}")
      {_r, vt} = render_frame(r, vt, small_chat ++ editor)

      rows = visible(vt)
      # Chat 5..11 + editor should be visible, stale rows cleared
      assert Enum.at(rows, 0) == "Chat 5"
      assert Enum.at(rows, 6) == "Chat 11"
      assert Enum.at(rows, 7) == "───"
      assert Enum.at(rows, 8) == "input text"
      assert Enum.at(rows, 9) == "───"
      assert Enum.at(rows, 10) == ""
      assert Enum.at(rows, 11) == ""
    end

    test "append after shrink stays clean" do
      {r, vt} = setup_render(height: 10)

      # Start with 5 lines
      {r, vt} = render_frame(r, vt, Enum.map(0..4, &"Line #{&1}"))

      # Shrink to 3
      {r, vt} = render_frame(r, vt, Enum.map(0..2, &"Line #{&1}"))

      # Append one more (4 total now)
      {_r, vt} = render_frame(r, vt, Enum.map(0..3, &"Line #{&1}"))

      rows = visible(vt)
      assert Enum.at(rows, 0) == "Line 0"
      assert Enum.at(rows, 1) == "Line 1"
      assert Enum.at(rows, 2) == "Line 2"
      assert Enum.at(rows, 3) == "Line 3"
      assert Enum.at(rows, 4) == ""
    end
  end

  # --- Interactive render integration ---

  describe "Interactive.build_screen end-to-end" do
    test "input with borders always visible after long transcript" do
      alias OctoPi.TUI.Components.Footer
      alias OctoPi.TUI.Components.Input
      alias OctoPi.TUI.Interactive

      # Simulate: long transcript (50 lines) + input with borders
      transcript = Enum.map(1..50, &{:assistant, "Line #{&1}", :done})

      state = %Interactive{
        transcript: transcript,
        input: %Input{value: "", cursor: 0},
        footer: %Footer{cwd: "/test", model_id: "test", context_window: 200_000},
        width: 80,
        height: 24
      }

      lines = Interactive.build_screen(state)

      # The last lines should be footer, preceded by input with borders
      # Input renders: [border, content, border] = 3 lines
      # Footer renders: 3 lines
      # Total last 6 lines = input(3) + footer(3)
      footer_lines = Footer.render(state.footer, 80)
      input_lines = Input.render(state.input, 80)

      # Verify input border is present in the output
      border = String.duplicate("─", 80)
      assert border in lines

      # Verify footer is at the bottom
      assert Enum.slice(lines, -length(footer_lines)..-1) == footer_lines

      # Verify input lines are just above footer
      input_end = length(lines) - length(footer_lines)
      input_start = input_end - length(input_lines)
      assert Enum.slice(lines, input_start..(input_end - 1)) == input_lines
    end
  end

  # --- streaming simulation (content growth + fit_to_height) ---

  describe "streaming simulation" do
    test "growing content stays clean through renderer diff path" do
      {r, vt} = setup_render(width: 40, height: 10)

      # Start with 5 lines (padded to 10 by fit_to_height)
      lines0 = pad_to_height(["Header", "Line 1", "───", "", "───"], 10)
      {r, vt} = render_frame(r, vt, lines0)
      rows = visible(vt)
      assert Enum.at(rows, 5) == "Header"
      assert Enum.at(rows, 9) == "───"

      # Grow to 8 lines — padding shrinks
      lines1 =
        pad_to_height(
          ["Header", "Line 1", "Line 2", "Line 3", "Line 4", "───", "", "───"],
          10
        )

      {r, vt} = render_frame(r, vt, lines1)
      rows = visible(vt)
      assert Enum.at(rows, 2) == "Header"
      assert Enum.at(rows, 9) == "───"

      # Grow past height — viewport scrolls, top lines off-screen
      lines2 = Enum.map(1..8, &"Line #{&1}") ++ ["───", "", "───"]
      {r, vt} = render_frame(r, vt, lines2)
      rows = visible(vt)
      # 11 lines, viewport shows last 10 → Line 1 scrolled off
      assert Enum.at(rows, 0) == "Line 2"
      assert Enum.at(rows, 9) == "───"

      # Continue growing — more lines scroll off top
      lines3 = Enum.map(1..12, &"Line #{&1}") ++ ["───", "", "───"]
      {_r, vt} = render_frame(r, vt, lines3)
      rows = visible(vt)
      # 15 lines, viewport shows last 10 → Lines 1-5 scrolled off
      assert Enum.at(rows, 0) == "Line 6"
      assert Enum.at(rows, 9) == "───"
      # No stale content in any row
      assert Enum.at(rows, 6) == "Line 12"
      assert Enum.at(rows, 7) == "───"
      assert Enum.at(rows, 8) == ""
    end

    test "tool execution box appears cleanly mid-stream" do
      {r, vt} = setup_render(width: 40, height: 12)

      # Frame 1: some transcript + input + footer
      frame1 = pad_to_height(["Hello world", "───", "", "───", "footer1", "footer2"], 12)
      {r, vt} = render_frame(r, vt, frame1)

      # Frame 2: assistant response starts streaming (7 lines → 5 padding)
      frame2 =
        pad_to_height(
          [
            "> what's new?",
            "Let me check...",
            "───",
            "",
            "───",
            "footer1",
            "footer2"
          ],
          12
        )

      {r, vt} = render_frame(r, vt, frame2)
      rows = visible(vt)
      assert Enum.at(rows, 5) == "> what's new?"
      assert Enum.at(rows, 6) == "Let me check..."

      # Frame 3: tool box appears (simulating ToolExecution render)
      frame3 =
        pad_to_height(
          [
            "> what's new?",
            "Let me check...",
            "",
            "┌ bash ─────────────────────────────┐",
            "│ ls -la                            │",
            "└──────────────────────────────────┘",
            "───",
            "",
            "───",
            "footer1",
            "footer2"
          ],
          12
        )

      {r, vt} = render_frame(r, vt, frame3)
      rows = visible(vt)
      # 11 content lines + 1 padding row → tool box starts at row 4
      assert Enum.at(rows, 4) =~ "bash"
      assert Enum.at(rows, 6) =~ "└"
      assert Enum.at(rows, 11) == "footer2"

      # Frame 4: tool completes, more streaming text
      frame4 = [
        "> what's new?",
        "Let me check...",
        "",
        "┌ v bash ───────────────────────────┐",
        "│ ls -la                            │",
        "└──────────────────────────────────┘",
        "Here are the results:",
        "- file1.ex",
        "- file2.ex",
        "───",
        "",
        "───",
        "footer1",
        "footer2"
      ]

      {_r, vt} = render_frame(r, vt, frame4)
      rows = visible(vt)
      # 14 lines, viewport shows last 12 → first 2 scrolled off
      # Row 0 = "" (tool separator), Row 1 = tool box top
      assert Enum.at(rows, 0) == ""
      assert Enum.at(rows, 1) =~ "bash"
      assert Enum.at(rows, 4) == "Here are the results:"
      assert Enum.at(rows, 11) == "footer2"
    end

    test "rapid frame updates don't leave stale content" do
      {r, vt} = setup_render(width: 40, height: 8)

      # Simulate word-by-word streaming — short words so they fit width
      words = ~w(Hi how are you ok bye go up at)

      {_r, vt, _} =
        Enum.reduce(words, {r, vt, ""}, fn word, {r_acc, vt_acc, text_acc} ->
          new_text = if text_acc == "", do: word, else: text_acc <> " " <> word
          lines = pad_to_height([new_text, "───", "", "───"], 8)
          {r_acc, vt_acc} = render_frame(r_acc, vt_acc, lines)
          {r_acc, vt_acc, new_text}
        end)

      rows = visible(vt)
      full_text = Enum.join(words, " ")
      # 4 content lines padded to 8 → 4 padding rows at top
      assert Enum.at(rows, 4) == full_text
      assert Enum.at(rows, 5) == "───"
      assert Enum.at(rows, 6) == ""
      assert Enum.at(rows, 7) == "───"
      assert Enum.at(rows, 0) == ""
      assert Enum.at(rows, 3) == ""
    end
  end

  # --- redraw counter + Termux + SGR reset (upstream tui-render.test.ts L66-290) ---

  describe "redraw counter" do
    test "full_redraws increments on first render, stays flat on shrink and growth" do
      {r, _vt} = setup_render(height: 10)
      assert r.full_redraws == 0

      {_, r} = Renderer.render(r, ["a", "b", "c", "d"])
      assert r.full_redraws == 1

      {_, r} = Renderer.render(r, ["a", "b"])
      assert r.full_redraws == 1, "shrink uses diff path, not full redraw"

      {_, r} = Renderer.render(r, ["a", "b", "c"])
      assert r.full_redraws == 1, "growth must stay on the diff path"
    end
  end

  describe "Termux height-resize suppression" do
    test "height change under TERMUX_VERSION does not full-redraw or clear" do
      prev = System.get_env("TERMUX_VERSION")
      System.put_env("TERMUX_VERSION", "0.118.0")

      try do
        {r, vt} = setup_render(width: 40, height: 10)
        lines = Enum.map(0..19, &"Line #{&1}")
        {bytes0, r} = Renderer.render(r, lines)
        vt = VT.write(vt, bytes0)
        initial = r.full_redraws

        r =
          Enum.reduce([15, 8, 14, 11], r, fn h, r ->
            r = Renderer.resize(r, 40, h)
            {bytes, r} = Renderer.render(r, lines)

            refute bytes =~ "\e[2J",
                   "Termux height change must not emit clear-screen (h=#{h})"

            refute bytes =~ "\e[3J",
                   "Termux height change must not clear scrollback (h=#{h})"

            _ = VT.write(vt, bytes)
            r
          end)

        assert r.full_redraws == initial,
               "Termux height changes must not bump full_redraws"
      after
        case prev do
          nil -> System.delete_env("TERMUX_VERSION")
          v -> System.put_env("TERMUX_VERSION", v)
        end
      end
    end
  end

  describe "style isolation across lines" do
    test "rendered italic line does not leak italic into the next line" do
      {r, vt} = setup_render(width: 20, height: 6)
      {bytes, _r} = Renderer.render(r, ["\e[3mItalic\e[23m", "Plain"])
      vt = VT.write(vt, bytes)
      refute VT.cell_italic?(vt, 1, 0), "italic leaked to plain line"
    end
  end

  describe "strict shrink/append counter invariants" do
    test "deleting lines clears stale rows and preserves remaining content" do
      {r, vt} = setup_render(width: 20, height: 12)
      twelve = Enum.map(0..11, &"Line #{&1}")
      {bytes0, r} = Renderer.render(r, twelve)
      vt = VT.write(vt, bytes0)

      seven = Enum.map(0..6, &"Line #{&1}")
      {bytes1, _r} = Renderer.render(r, seven)
      vt = VT.write(vt, bytes1)

      rows = visible(vt)
      for i <- 0..6, do: assert(Enum.at(rows, i) == "Line #{i}")
    end

    test "appending after a shrink stays on the diff path (no extra full redraw)" do
      {r, vt} = setup_render(width: 20, height: 10)
      eight = Enum.map(0..7, &"Line #{&1}")
      {b0, r} = Renderer.render(r, eight)
      vt = VT.write(vt, b0)

      {b1, r} = Renderer.render(r, ["Line 0", "Line 1"])
      vt = VT.write(vt, b1)
      after_shrink = r.full_redraws

      {b2, r} = Renderer.render(r, ["Line 0", "Line 1", "Line 2"])
      vt = VT.write(vt, b2)

      assert r.full_redraws == after_shrink,
             "append after shrink should stay on the diff path"

      rows = visible(vt)
      assert Enum.at(rows, 0) == "Line 0"
      assert Enum.at(rows, 1) == "Line 1"
      assert Enum.at(rows, 2) == "Line 2"
    end
  end

  # --- overlay visibility (upstream overlay-short-content.test.ts) ---

  describe "overlay visibility" do
    alias OctoPi.TUI.Overlay

    test "overlay renders when base content is shorter than terminal height" do
      # Regression: 24-row terminal, 3-line child, centered overlay
      # must appear in viewport (upstream overlay-short-content.test.ts).
      {r, vt} = setup_render(width: 80, height: 24)
      base = pad_to_height(["Line 1", "Line 2", "Line 3"], 24)

      overlay = %Overlay{
        lines: ["OVERLAY_TOP", "OVERLAY_MID", "OVERLAY_BOT"],
        width: 11,
        anchor: :center
      }

      composed = Overlay.composite(base, [overlay], 80, 24)
      {_r, vt} = render_frame(r, vt, composed)

      assert Enum.any?(visible(vt), &String.contains?(&1, "OVERLAY")),
             "expected overlay text in viewport: #{inspect(visible(vt))}"
    end
  end

  # --- helpers for streaming tests ---

  defp pad_to_height(lines, height) do
    len = length(lines)

    if len >= height,
      do: Enum.take(lines, -height),
      else: List.duplicate("", height - len) ++ lines
  end
end
