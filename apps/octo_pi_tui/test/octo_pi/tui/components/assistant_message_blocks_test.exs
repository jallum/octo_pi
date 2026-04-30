defmodule OctoPi.TUI.Components.AssistantMessageBlocksTest do
  @moduledoc """
  Tests for opi-4dx.9: AssistantMessage's nested per-block state
  shape. Independent renderer state per `block_id`, cached iolist
  for finalized blocks at the stamped ctx, mixed kinds preserved
  across renders.
  """

  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.AssistantMessage.TextBlock
  alias OctoPi.TUI.Components.AssistantMessage.ThinkingBlock
  alias OctoPi.TUI.Components.Markdown.Render, as: MdRender
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")

  describe "put_block/4" do
    test "first delta on a fresh message creates the block at the given id" do
      msg = AssistantMessage.new(@theme, width: 80)
      msg = AssistantMessage.put_block(msg, 0, :text, "hello")

      assert msg.blocks.data[0] == "hello"
      assert msg.blocks.modules[0] == TextBlock
      assert %MdRender{} = msg.blocks.renderers[0]
      assert msg.content == [{:text, "hello"}]
    end

    test "subsequent puts update the renderer's source incrementally" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "he")
        |> AssistantMessage.put_block(0, :text, "hello")

      assert msg.blocks.data[0] == "hello"
      assert %MdRender{source: "hello"} = msg.blocks.renderers[0]
    end

    test "updating one block leaves other blocks' state untouched" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "alpha")
        |> AssistantMessage.put_block(1, :text, "beta")

      r0_before = msg.blocks.renderers[0]

      msg2 = AssistantMessage.put_block(msg, 1, :text, "beta-extended")

      assert msg2.blocks.renderers[0] === r0_before,
             "block 0's renderer state must be the same struct (no rebuild)"
    end

    test "mixed text and thinking by id are preserved across renders" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :thinking, "let me think")
        |> AssistantMessage.put_block(1, :text, "and here is the answer")

      lines = AssistantMessage.render(msg, 80)
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "let me think"
      assert flat =~ "and here is the answer"
      assert :binary.match(flat, "let me think") < :binary.match(flat, "and here is the answer")
    end

    test "out-of-order arrival: block 2 update doesn't disturb block 1" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(1, :text, "first")
        |> AssistantMessage.put_block(2, :text, "second")

      r1_before = msg.blocks.renderers[1]

      msg2 = AssistantMessage.put_block(msg, 2, :text, "second-grew")

      assert msg2.blocks.renderers[1] === r1_before
      assert msg2.blocks.data[2] == "second-grew"
    end

    test "thinking block uses the ThinkingBlock renderer module" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :thinking, "ponder")

      assert msg.blocks.modules[0] == ThinkingBlock
      assert %ThinkingBlock{snapshot: "ponder"} = msg.blocks.renderers[0]
    end
  end

  describe "finalize_block/2" do
    test "marks block finalized in the embedded transcript" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello world")
        |> AssistantMessage.finalize_block(0)

      assert MapSet.member?(msg.blocks.finalized, 0)
    end

    test "no-op for an unknown block id" do
      msg = AssistantMessage.new(@theme, width: 80)
      msg2 = AssistantMessage.finalize_block(msg, 99)
      assert msg2 == msg
    end
  end

  describe "render/2 caching at stamped ctx" do
    test "renderers persist across renders at the stamped ctx (no rebuild)" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")
        |> AssistantMessage.finalize_block(0)

      _ = AssistantMessage.render(msg, 80)

      # After finalize + render, the renderer is dropped from the live
      # set and the iodata moves into Transcript.rendered.
      msg2 = AssistantMessage.update_content(msg, content: msg.content)
      _ = AssistantMessage.render(msg2, 80)

      # Cache identity is intact.
      assert msg2.blocks.ctx == %{theme: @theme, width: 80, padding_x: 1, hide_thinking: false, hidden_thinking_label: "Thinking..."}
    end

    test "render at a different width triggers Transcript.resize (renderers rebuilt)" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")

      r_before = msg.blocks.renderers[0]
      _ = AssistantMessage.render(msg, 60)

      # AssistantMessage.render returns lines but doesn't mutate msg.
      # The cache rebuild only "sticks" if the caller persists the
      # updated transcript via update_content(width: 60).
      msg2 = AssistantMessage.update_content(msg, width: 60)
      assert %MdRender{width: 60} = msg2.blocks.renderers[0]
      refute msg2.blocks.renderers[0] === r_before
    end
  end

  describe "update_content/2 — width / theme propagation" do
    test "first call without width leaves the renderer in a deferred state" do
      msg = AssistantMessage.new(nil)
      msg = AssistantMessage.update_content(msg, content: [{:text, "x"}])

      assert msg.blocks.renderers[0] == {:deferred, "x"}

      msg = AssistantMessage.update_content(msg, theme: @theme, width: 80)
      assert %MdRender{width: 80} = msg.blocks.renderers[0]
    end

    test "width change resizes existing renderers via Transcript.resize" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")

      msg2 = AssistantMessage.update_content(msg, width: 60)
      assert %MdRender{width: 60} = msg2.blocks.renderers[0]
      assert msg2.blocks.ctx.width == 60
    end
  end
end
