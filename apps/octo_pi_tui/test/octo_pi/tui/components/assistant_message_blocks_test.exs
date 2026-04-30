defmodule OctoPi.TUI.Components.AssistantMessageBlocksTest do
  @moduledoc """
  Tests for opi-4dx.9: AssistantMessage's nested per-block state
  shape. Independent renderer state per `block_id`, cached iolist
  for finalized blocks at the stamped width, mixed kinds preserved
  across renders.
  """

  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.Markdown.Render, as: MdRender
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")

  describe "put_block/4" do
    test "first delta on a fresh message creates the block at the given id" do
      msg = AssistantMessage.new(@theme, width: 80)
      msg = AssistantMessage.put_block(msg, 0, :text, "hello")

      assert %{kind: :text, snapshot: "hello", render_state: %MdRender{}} = msg.blocks[0]
      assert msg.content == [{:text, "hello"}]
    end

    test "subsequent puts update the renderer's source incrementally" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "he")
        |> AssistantMessage.put_block(0, :text, "hello")

      assert msg.blocks[0].snapshot == "hello"
      assert %MdRender{source: src} = msg.blocks[0].render_state
      assert src == "hello"
    end

    test "updating one block leaves other blocks' state untouched" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "alpha")
        |> AssistantMessage.put_block(1, :text, "beta")

      r0_before = msg.blocks[0].render_state

      msg2 = AssistantMessage.put_block(msg, 1, :text, "beta-extended")

      assert msg2.blocks[0].render_state === r0_before,
             "block 0's render_state must be the same struct (no rebuild)"
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

      r1_before = msg.blocks[1].render_state

      msg2 = AssistantMessage.put_block(msg, 2, :text, "second-grew")

      assert msg2.blocks[1].render_state === r1_before
      assert msg2.blocks[2].snapshot == "second-grew"
    end
  end

  describe "finalize_block/2" do
    test "marks block finalized and folds its volatile tail into committed" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello world")
        |> AssistantMessage.finalize_block(0)

      assert msg.blocks[0].finalized? == true
      assert %MdRender{} = msg.blocks[0].render_state
    end

    test "no-op for an unknown block id" do
      msg = AssistantMessage.new(@theme, width: 80)
      msg2 = AssistantMessage.finalize_block(msg, 99)
      assert msg2 == msg
    end
  end

  describe "render/2 caching at stamped width" do
    test "fires no markdown.render telemetry span when width matches stamped state" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")

      handler_id = "test-no-md-span-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:octo_pi_tui, :markdown, :render, :start],
        fn _name, _measurements, _meta, _config -> send(test_pid, :md_span) end,
        nil
      )

      try do
        _ = AssistantMessage.render(msg, 80)
        refute_received :md_span, "render at the stamped width must not fire markdown.render"
      after
        :telemetry.detach(handler_id)
      end
    end

    test "fires telemetry span at a non-stamped width (uncached fallback)" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")

      handler_id = "test-fallback-span-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:octo_pi_tui, :markdown, :render, :start],
        fn _name, _measurements, _meta, _config -> send(test_pid, :md_span) end,
        nil
      )

      try do
        _ = AssistantMessage.render(msg, 60)
        assert_received :md_span
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "update_content/2 — width / theme propagation" do
    test "first call without width leaves render_state unset; later width call backfills" do
      msg = AssistantMessage.new(nil)
      msg = AssistantMessage.update_content(msg, content: [{:text, "x"}])

      assert msg.blocks[0].render_state == nil

      msg = AssistantMessage.update_content(msg, theme: @theme, width: 80)
      # Width propagation rebuilds renderers if the snapshot remains
      # unchanged: a fresh content list at known width gives us a
      # backfilled state. That happens when content is repassed.
      msg = AssistantMessage.update_content(msg, content: [{:text, "x"}])
      assert %MdRender{width: 80} = msg.blocks[0].render_state
    end

    test "width change resizes existing renderer (no full rebuild)" do
      msg =
        AssistantMessage.new(@theme, width: 80)
        |> AssistantMessage.put_block(0, :text, "hello")

      msg2 = AssistantMessage.update_content(msg, width: 60)
      assert %MdRender{width: 60} = msg2.blocks[0].render_state
    end
  end
end
