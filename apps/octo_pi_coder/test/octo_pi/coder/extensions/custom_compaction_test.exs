defmodule OctoPi.Coder.Extensions.CustomCompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.CustomCompaction

  defp load_ext do
    {:ok, ext} = Loader.load_from_factory("custom-compaction", &CustomCompaction.init/1)
    ext
  end

  defp compact_event(opts \\ []) do
    preparation = %{
      messages_to_summarize: Keyword.get(opts, :messages, [%{role: "user", content: "hello"}]),
      turn_prefix_messages: [],
      tokens_before: Keyword.get(opts, :tokens_before, 50_000),
      first_kept_entry_id: Keyword.get(opts, :first_kept_entry_id, "entry-42"),
      previous_summary: Keyword.get(opts, :previous_summary, nil)
    }

    Event.new(:session_before_compact, %{preparation: preparation})
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  describe "init/1" do
    test "registers a session_before_compact handler" do
      ext = load_ext()
      assert Map.has_key?(ext.handlers, :session_before_compact)
      assert length(ext.handlers[:session_before_compact]) == 1
    end

    test "registers no tools" do
      assert load_ext().tools == %{}
    end

    test "registers no commands" do
      assert load_ext().commands == %{}
    end
  end

  describe "session_before_compact handler" do
    test "returns {:cancel, compaction} to provide custom compaction" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      result = handler.(compact_event(), ctx())
      assert match?({:cancel, %{compaction: _}}, result)
    end

    test "compaction result includes a non-empty summary" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      {:cancel, %{compaction: compaction}} = handler.(compact_event(), ctx())
      assert is_binary(compaction.summary) and compaction.summary != ""
    end

    test "compaction result preserves first_kept_entry_id from preparation" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      event = compact_event(first_kept_entry_id: "entry-99")
      {:cancel, %{compaction: compaction}} = handler.(event, ctx())
      assert compaction.first_kept_entry_id == "entry-99"
    end

    test "compaction result preserves tokens_before from preparation" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      event = compact_event(tokens_before: 75_000)
      {:cancel, %{compaction: compaction}} = handler.(event, ctx())
      assert compaction.tokens_before == 75_000
    end

    test "summary includes previous_summary context when present" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      event = compact_event(previous_summary: "Prior: worked on auth module")
      {:cancel, %{compaction: compaction}} = handler.(event, ctx())
      assert compaction.summary =~ "Prior"
    end

    test "returns nil when preparation has no messages to summarize" do
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      event = compact_event(messages: [])
      result = handler.(event, ctx())
      assert is_nil(result)
    end
  end
end
