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

  defp ctx(opts \\ []), do: Context.new(Map.merge(%{cwd: "/tmp"}, Map.new(opts)))

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

    test "calls find_model with :google provider and gemini model id" do
      test_pid = self()
      find_fn = fn provider, id -> send(test_pid, {:find_model, provider, id}) && nil end
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      handler.(compact_event(), ctx(find_model: find_fn))
      assert_receive {:find_model, :google, "gemini-2.5-flash"}
    end

    test "calls get_model_auth when find_model returns a model" do
      test_pid = self()
      model = %{id: "gemini-2.5-flash", provider: :google}
      find_fn = fn _provider, _id -> model end
      auth_fn = fn m -> send(test_pid, {:get_model_auth, m}) && {:error, "no key"} end
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      handler.(compact_event(), ctx(find_model: find_fn, get_model_auth: auth_fn))
      assert_receive {:get_model_auth, ^model}
    end

    test "still returns local compaction when find_model returns nil" do
      find_fn = fn _provider, _id -> nil end
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      result = handler.(compact_event(), ctx(find_model: find_fn))
      assert match?({:cancel, %{compaction: _}}, result)
    end

    test "still returns local compaction when get_model_auth fails" do
      model = %{id: "gemini-2.5-flash", provider: :google}
      find_fn = fn _provider, _id -> model end
      auth_fn = fn _m -> {:error, "unauthorized"} end
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      result = handler.(compact_event(), ctx(find_model: find_fn, get_model_auth: auth_fn))
      assert match?({:cancel, %{compaction: _}}, result)
    end

    test "still returns local compaction when auth succeeds (LLM call deferred)" do
      model = %{id: "gemini-2.5-flash", provider: :google}
      find_fn = fn _provider, _id -> model end
      auth_fn = fn _m -> {:ok, %{api_key: "sk-test"}} end
      ext = load_ext()
      [handler] = ext.handlers[:session_before_compact]
      result = handler.(compact_event(), ctx(find_model: find_fn, get_model_auth: auth_fn))
      assert match?({:cancel, %{compaction: _}}, result)
    end
  end
end
