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

    test "line-count change triggers full redraw" do
      pid = new()
      {:ok, _} = Renderer.render(pid, ["a", "b"])
      {:ok, bytes} = Renderer.render(pid, ["a", "b", "c"])
      assert bytes =~ "\e[2J"
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
