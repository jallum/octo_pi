defmodule OctoPi.Coder.Extensions.StatusLineTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.StatusLine

  defp ext_with_state do
    {:ok, state} = Agent.start_link(fn -> %{turn_count: 0} end)
    {:ok, ext} = Loader.load_from_factory("status-line", fn api -> StatusLine.init(api, state) end)
    {ext, state}
  end

  defp no_ui_ctx, do: Context.new(%{cwd: "/tmp"})

  defp ui_ctx(status_calls) do
    ui =
      UIContext.bind(UIContext.new(), %{
        set_status: fn text -> Agent.update(status_calls, fn acc -> [text | acc] end) end,
        apply_fg: fn _color, text -> text end,
        apply_bg: fn _color, text -> text end
      })

    Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
  end

  describe "init/2" do
    test "registers a session_start handler" do
      {ext, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :session_start)
    end

    test "registers a turn_start handler" do
      {ext, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :turn_start)
    end

    test "registers a turn_end handler" do
      {ext, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :turn_end)
    end

    test "registers no tools" do
      {ext, _} = ext_with_state()
      assert ext.tools == %{}
    end

    test "registers no commands" do
      {ext, _} = ext_with_state()
      assert ext.commands == %{}
    end
  end

  describe "session_start handler" do
    test "calls set_status when has_ui? is true" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ui_ctx(status_calls))
      assert length(Agent.get(status_calls, & &1)) == 1
    end

    test "set_status text indicates ready state" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ui_ctx(status_calls))
      [text] = Agent.get(status_calls, & &1)
      assert is_binary(text)
      assert String.length(text) > 0
    end

    test "does not call set_status when has_ui? is false" do
      {ext, _} = ext_with_state()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), no_ui_ctx())
    end
  end

  describe "turn_start handler" do
    test "calls set_status with turn info when has_ui? is true" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()
      handler = hd(ext.handlers[:turn_start])
      handler.(Event.new(:turn_start, %{}), ui_ctx(status_calls))
      assert length(Agent.get(status_calls, & &1)) == 1
    end

    test "increments turn count on each call" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, state} = ext_with_state()
      handler = hd(ext.handlers[:turn_start])
      ctx = ui_ctx(status_calls)
      handler.(Event.new(:turn_start, %{}), ctx)
      handler.(Event.new(:turn_start, %{}), ctx)
      assert Agent.get(state, & &1.turn_count) == 2
    end

    test "status text includes the turn number" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()
      handler = hd(ext.handlers[:turn_start])
      handler.(Event.new(:turn_start, %{}), ui_ctx(status_calls))
      [text] = Agent.get(status_calls, & &1)
      assert text =~ "1"
    end
  end

  describe "turn_end handler" do
    test "calls set_status with completion info when has_ui? is true" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()

      start_handler = hd(ext.handlers[:turn_start])
      end_handler = hd(ext.handlers[:turn_end])
      ctx = ui_ctx(status_calls)

      start_handler.(Event.new(:turn_start, %{}), ctx)
      end_handler.(Event.new(:turn_end, %{}), ctx)

      texts = Agent.get(status_calls, & &1)
      assert length(texts) == 2
    end

    test "completion status text includes the turn number" do
      {:ok, status_calls} = Agent.start_link(fn -> [] end)
      {ext, _} = ext_with_state()
      ctx = ui_ctx(status_calls)

      hd(ext.handlers[:turn_start]).(Event.new(:turn_start, %{}), ctx)
      hd(ext.handlers[:turn_end]).(Event.new(:turn_end, %{}), ctx)

      [end_text | _] = Agent.get(status_calls, & &1)
      assert end_text =~ "1"
    end
  end
end
