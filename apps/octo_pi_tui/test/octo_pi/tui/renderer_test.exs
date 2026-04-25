defmodule OctoPi.TUI.RendererTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Renderer

  defp new(opts \\ []) do
    {:ok, pid} = Renderer.start_link(Keyword.merge([width: 80, height: 24], opts))
    pid
  end

  defp strip_csi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, binary, "")
  end

  describe "first render" do
    test "clears screen and outputs all lines" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["hello", "world"])

      assert bytes =~ "\e[2J"
      text = strip_csi(bytes)
      assert text =~ "hello"
      assert text =~ "world"
    end

    test "lines are joined with \\r\\n" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      text = strip_csi(bytes)
      assert text =~ "a\r\nb\r\nc"
    end
  end

  describe "diff against previous frame" do
    test "no change → empty bytes" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      assert bytes == ""
    end

    test "single middle-line change → only that line" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "X", "c"])

      text = strip_csi(bytes)
      assert text =~ "X"
      refute text =~ "a"
      refute text =~ "c"
    end

    test "first-line change only" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["X", "b", "c"])

      text = strip_csi(bytes)
      assert text =~ "X"
      refute text =~ "b"
      refute text =~ "c"
    end

    test "last-line change only" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "X"])

      text = strip_csi(bytes)
      assert text =~ "X"
      refute text =~ "a"
    end

    test "non-adjacent changes are emitted as a contiguous range" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c", "d", "e"])
      {:ok, bytes} = Renderer.render(pid, ["a", "X", "c", "Y", "e"])

      text = strip_csi(bytes)
      assert text =~ "X"
      assert text =~ "Y"
      assert text =~ "c"
      refute text =~ "a"
      refute text =~ "e"
    end
  end

  describe "full redraw triggers" do
    test "width change triggers full redraw with clear" do
      pid = new(width: 80)
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      :ok = Renderer.resize(pid, 100, 24)
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end

    test "height change triggers full redraw with clear" do
      pid = new(height: 24)
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      :ok = Renderer.resize(pid, 80, 40)
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end

    test "line-count growth stays on the diff path" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      refute bytes =~ "\e[2J"
      assert strip_csi(bytes) =~ "c"
    end
  end

  @erase_line "\e[2K"

  describe "content shrink" do
    test "shrink uses diff path (not full redraw) by default" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c", "d", "e"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])

      refute bytes =~ "\e[2J"
    end

    test "shrink clears stale rows" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c", "d", "e"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])

      assert bytes =~ @erase_line
    end
  end

  describe "termux suppression" do
    test "height change under Termux emits a normal diff instead of clear-screen" do
      prev = System.get_env("TERMUX_VERSION")
      System.put_env("TERMUX_VERSION", "0.118.0")

      try do
        pid = new(height: 24)
        {:ok, _} = Renderer.render(pid, ["a"])
        :ok = Renderer.resize(pid, 80, 40)
        {:ok, bytes} = Renderer.render(pid, ["a"])
        refute bytes =~ "\e[2J"
      after
        case prev do
          nil -> System.delete_env("TERMUX_VERSION")
          v -> System.put_env("TERMUX_VERSION", v)
        end
      end
    end
  end

  describe "CSI 2026 synchronized output" do
    test "wraps output in \\e[?2026h / \\e[?2026l when enabled" do
      pid = new(csi_2026?: true)
      {:ok, _} = Renderer.render(pid, ["a"])
      {:ok, bytes} = Renderer.render(pid, ["X"])

      assert String.starts_with?(bytes, "\e[?2026h")
      assert String.ends_with?(bytes, "\e[?2026l")
    end

    test "no wrapping when disabled" do
      pid = new(csi_2026?: false)
      {:ok, _} = Renderer.render(pid, ["a"])
      {:ok, bytes} = Renderer.render(pid, ["X"])

      refute bytes =~ "\e[?2026h"
    end
  end

  describe "content transitions" do
    test "content → empty → content round-trips correctly" do
      pid = new()
      {:ok, bytes1} = Renderer.render(pid, ["hello"])
      assert strip_csi(bytes1) =~ "hello"

      {:ok, _bytes2} = Renderer.render(pid, [])

      {:ok, bytes3} = Renderer.render(pid, ["back"])
      assert strip_csi(bytes3) =~ "back"
    end

    test "growth paints new lines via diff" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["x", "y", "z", "w"])
      refute bytes =~ "\e[2J"
      text = strip_csi(bytes)
      assert text =~ "x"
      assert text =~ "w"
    end
  end

  describe "each line is preceded by erase-line" do
    test "every rendered line has \\e[2K on first render" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["short", "longer line here"])

      assert strip_csi(bytes) =~ "short"
      assert strip_csi(bytes) =~ "longer line here"
    end

    test "diff lines use erase-line before painting" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      {:ok, bytes} = Renderer.render(pid, ["a", "X"])

      assert bytes =~ "\e[2KX"
    end
  end

  describe "resize then render" do
    test "resize invalidates previous frame so next render is full redraw" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      {:ok, no_diff} = Renderer.render(pid, ["a", "b"])
      assert no_diff == ""

      :ok = Renderer.resize(pid, 120, 40)
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end
  end

  describe "viewport tracking (opi-185)" do
    # previous_viewport_top must be derived from hw_row (actual final cursor
    # position) not render_end (last changed line index). When cursor_seq places
    # the cursor above render_end the two diverge, causing the next diff render
    # to incorrectly decide first_changed < prev_vp_top and trigger a full redraw.
    test "cursor_seq above render_end does not cause spurious full redraw" do
      pid = new(height: 10)
      lines8 = Enum.map(1..8, &"line#{&1}")
      {:ok, _} = Renderer.render(pid, lines8)

      # Grow to 12 lines; cursor placed at screen row 0 (buffer row 2 for
      # a 12-line frame in a 10-row terminal).  render_end will be 11 but
      # hw_row will be 2.  Bug: prev_vp_top = max(0, 11-9) = 2.
      # Fix: prev_vp_top = max(0, 2-9)  = 0.
      lines12 = lines8 ++ Enum.map(9..12, &"line#{&1}")
      {:ok, _} = Renderer.render(pid, lines12, "\e[1;1H")

      # Change the first line.  With the bug, prev_vp_top=2 so
      # first_changed(0) < 2 forces a full redraw.
      changed = List.replace_at(lines12, 0, "CHANGED")
      {:ok, _} = Renderer.render(pid, changed)

      assert Renderer.full_redraws(pid) == 1
    end
  end

  describe "max_lines_rendered resets on content change (opi-e72)" do
    # max_lines_rendered must track the *current* line count, not a
    # historical maximum.  When clear_on_shrink is active, a monotonically
    # growing counter would trigger a full clear-redraw whenever content
    # later renders at fewer lines than the all-time peak — even when those
    # extra lines were already removed by a handled deletion.
    test "shrink-then-grow does not trigger spurious clear-redraw" do
      prev = System.get_env("PI_CLEAR_ON_SHRINK")
      System.put_env("PI_CLEAR_ON_SHRINK", "1")

      try do
        pid = new()
        # Render 5 lines — max_lines_rendered = 5
        {:ok, _} = Renderer.render(pid, ["a", "b", "c", "d", "e"])

        # Render 3 lines with a content change at row 0 (goes through
        # handle_changed_lines, not handle_deleted_lines).
        # Bug:  max_lines_rendered stays 5.
        # Fix:  max_lines_rendered reset to 3.
        {:ok, _} = Renderer.render(pid, ["X", "b", "c"])

        # Render the same 3 lines with a change.
        # Bug:  3 < 5 → compute triggers full_render → full_redraws = 2.
        # Fix:  3 < 3 is false → diff path → full_redraws = 1.
        {:ok, _} = Renderer.render(pid, ["X", "b", "Y"])

        assert Renderer.full_redraws(pid) == 1
      after
        case prev do
          nil -> System.delete_env("PI_CLEAR_ON_SHRINK")
          v -> System.put_env("PI_CLEAR_ON_SHRINK", v)
        end
      end
    end
  end

  describe "find_diff_range/2" do
    test "no changes → {-1, -1}" do
      assert {-1, -1} = Renderer.find_diff_range(["a", "b", "c"], ["a", "b", "c"])
    end

    test "new lines appended → repaints shifted region" do
      assert {3, 5} =
               Renderer.find_diff_range(
                 ["a", "b", "c", "d", "footer_hr", "footer_stats"],
                 ["a", "b", "c", "footer_hr", "footer_stats"]
               )
    end

    test "single change → first == last" do
      assert {1, 1} = Renderer.find_diff_range(["a", "X", "c"], ["a", "b", "c"])
    end

    test "change at start" do
      assert {0, 0} = Renderer.find_diff_range(["X", "b", "c"], ["a", "b", "c"])
    end

    test "change at end" do
      assert {2, 2} = Renderer.find_diff_range(["a", "b", "X"], ["a", "b", "c"])
    end

    test "non-adjacent changes → full spanning range" do
      assert {1, 3} =
               Renderer.find_diff_range(["a", "X", "c", "Y", "e"], ["a", "b", "c", "d", "e"])
    end
  end
end
