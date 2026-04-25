defmodule OctoPi.TUI.RendererTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Renderer

  defp new(opts \\ []) do
    {:ok, pid} = Renderer.start_link(Keyword.merge([width: 80, height: 24], opts))
    pid
  end

  defp strip_csi(binary) do
    # For tests that don't care about specific CSI escapes — just
    # verify the payload text survives.
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, binary, "")
  end

  describe "full redraw on first render" do
    test "emits clear + home + all lines" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["hello", "world"])

      # Expect: clear screen + cursor home + both lines visible.
      assert bytes =~ "\e[2J"
      assert bytes =~ "\e[H"
      assert strip_csi(bytes) =~ "hello"
      assert strip_csi(bytes) =~ "world"
    end
  end

  describe "diff against previous frame" do
    test "no change → empty bytes" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      assert bytes == ""
    end

    test "single middle-line change → cursor move + only that line" do
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
      # Middle unchanged line is re-emitted as part of the range
      # (simple O(n) diff) — that's fine, the tradeoff is clarity.
      assert text =~ "c"
      # Outer unchanged lines are NOT re-emitted.
      refute text =~ "a"
      refute text =~ "e"
    end
  end

  describe "full redraw triggers" do
    test "width change triggers full redraw" do
      pid = new(width: 80)
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      :ok = Renderer.resize(pid, 100, 24)
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end

    test "height change triggers full redraw" do
      pid = new(height: 24)
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      :ok = Renderer.resize(pid, 80, 40)
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end

    test "line-count shrink triggers full redraw" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])
      assert bytes =~ "\e[2J"
    end

    test "line-count growth stays on the diff path" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      refute bytes =~ "\e[2J"
      assert bytes =~ "c"
    end
  end

  describe "termux suppression" do
    # Termux's console doesn't survive a clear-screen the same way
    # as a normal xterm — upstream suppresses the full redraw on
    # height changes. We detect via the TERMUX_VERSION env var.

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
    test "wraps diff output in \\e[?2026h / \\e[?2026l when enabled" do
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

  describe "content shrink triggers full redraw" do
    test "shrinking from N to M<N lines triggers full redraw with stale-row clearance" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c", "d", "e"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b"])

      assert bytes =~ "\e[2J"
      text = strip_csi(bytes)
      assert text =~ "a"
      assert text =~ "b"
    end
  end

  describe "content transitions" do
    test "content → empty is a shrink (full redraw), empty → content grows (diff)" do
      pid = new()
      {:ok, bytes1} = Renderer.render(pid, ["hello"])
      assert bytes1 =~ "\e[2J"

      {:ok, bytes2} = Renderer.render(pid, [])
      assert bytes2 =~ "\e[2J"

      {:ok, bytes3} = Renderer.render(pid, ["back"])
      refute bytes3 =~ "\e[2J"
      assert strip_csi(bytes3) =~ "back"
    end

    test "growth to a wider frame paints new lines via diff" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["x", "y", "z", "w"])
      refute bytes =~ "\e[2J"
      text = strip_csi(bytes)
      assert text =~ "x"
      assert text =~ "w"
    end
  end

  describe "each line ends with clear-to-eol" do
    test "every rendered line has \\e[K to clear stale content" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["short", "longer line here"])

      lines = String.split(bytes, "\r\n")

      for line <- lines, strip_csi(line) != "" do
        assert line =~ "\e[K",
               "Line should end with clear-to-eol: #{inspect(line)}"
      end
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

  describe "erase below after render" do
    test "full redraw ends with erase-below to clear stale content" do
      pid = new()
      {:ok, bytes} = Renderer.render(pid, ["line1", "line2", "line3"])
      assert bytes =~ "\e[J"
    end

    test "diff render does NOT erase below (would wipe unchanged rows)" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b", "c"])
      {:ok, bytes} = Renderer.render(pid, ["a", "X", "c"])
      refute bytes =~ "\e[J"
    end
  end

  describe "find_diff_range/2" do
    test "no changes → {first > last}" do
      {first, last} = Renderer.find_diff_range(["a", "b", "c"], ["a", "b", "c"])
      assert first > last
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
