defmodule OctoPi.Coder.Extensions.CustomCompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.CustomCompaction

  defp load_ext do
    {:ok, ext} = Loader.load_from_factory("custom-compaction", &CustomCompaction.init/1)
    ext
  end

  defp fake_model do
    %Model{
      id: "gemini-2.5-flash",
      name: "gemini-2.5-flash",
      api: :google,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com",
      context_window: 1_000_000,
      max_tokens: 8_192
    }
  end

  defp fake_producer(summary_text) do
    fn _model, _ctx, _opts ->
      msg = %Assistant{
        api: :google,
        provider: :google,
        model: "gemini-2.5-flash",
        timestamp: 0,
        content: [%Text{text: summary_text}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      [%AIEvent.Done{reason: :stop, message: msg}]
    end
  end

  defp error_producer do
    fn _model, _ctx, _opts ->
      msg = %Assistant{
        api: :google,
        provider: :google,
        model: "gemini-2.5-flash",
        timestamp: 0,
        content: [],
        stop_reason: :error,
        error_message: "upstream error",
        usage: %Usage{}
      }

      [%AIEvent.Error{reason: :error, message: msg}]
    end
  end

  defp compact_event(opts \\ []) do
    preparation = %{
      messages_to_summarize: Keyword.get(opts, :messages, [%{role: "user", content: "hello"}]),
      turn_prefix_messages: Keyword.get(opts, :turn_prefix, []),
      tokens_before: Keyword.get(opts, :tokens_before, 50_000),
      first_kept_entry_id: Keyword.get(opts, :first_kept_entry_id, "entry-42"),
      previous_summary: Keyword.get(opts, :previous_summary, nil)
    }

    Event.new(:session_before_compact, %{preparation: preparation})
  end

  defp ctx(opts), do: Context.new(Map.merge(%{cwd: "/tmp"}, Map.new(opts)))

  defp ctx_with_auth(opts \\ []) do
    model = Keyword.get(opts, :model, fake_model())
    producer = Keyword.get(opts, :producer, fake_producer("generated summary"))
    find_fn = fn _provider, _id -> model end
    auth_fn = fn _m -> {:ok, %{api_key: "sk-test"}} end
    ctx(find_model: find_fn, get_model_auth: auth_fn, summary_producer: producer)
  end

  defp call_handler(event, ctx) do
    ext = load_ext()
    [handler] = ext.handlers[:session_before_compact]
    handler.(event, ctx)
  end

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

  describe "session_before_compact — real LLM path" do
    test "returns {:override, %Result{}} when auth resolves and summary generates" do
      result = call_handler(compact_event(), ctx_with_auth())
      assert match?({:override, %Result{}}, result)
    end

    test "summary is the text returned by the LLM" do
      ctx = ctx_with_auth(producer: fake_producer("detailed project summary"))
      {:override, compaction} = call_handler(compact_event(), ctx)
      assert compaction.summary == "detailed project summary"
    end

    test "preserves first_kept_entry_id from preparation" do
      event = compact_event(first_kept_entry_id: "entry-99")
      {:override, compaction} = call_handler(event, ctx_with_auth())
      assert compaction.first_kept_entry_id == "entry-99"
    end

    test "preserves tokens_before from preparation" do
      event = compact_event(tokens_before: 75_000)
      {:override, compaction} = call_handler(event, ctx_with_auth())
      assert compaction.tokens_before == 75_000
    end

    test "returns {:override, %Result{}} when previous_summary is present" do
      event = compact_event(previous_summary: "Prior: worked on auth module")
      {:override, compaction} = call_handler(event, ctx_with_auth())
      assert is_binary(compaction.summary) and compaction.summary != ""
    end

    test "combines turn_prefix_messages with messages_to_summarize" do
      alias OctoPi.AI.Message.User, as: UserMsg

      test_pid = self()

      capturing_producer = fn _model, ai_ctx, _opts ->
        [user_msg] = ai_ctx.messages
        [%Text{text: text}] = user_msg.content
        send(test_pid, {:prompt, text})

        msg = %Assistant{
          api: :google,
          provider: :google,
          model: "gemini-2.5-flash",
          timestamp: 0,
          content: [%Text{text: "ok"}],
          stop_reason: :stop,
          usage: %Usage{}
        }

        [%AIEvent.Done{reason: :stop, message: msg}]
      end

      main_msg = %UserMsg{
        content: [%Text{text: "main msg text"}],
        timestamp: 0
      }

      prefix_msg = %Assistant{
        api: :google,
        provider: :google,
        model: "gemini-2.5-flash",
        timestamp: 0,
        content: [%Text{text: "prefix msg text"}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      event = compact_event(messages: [main_msg], turn_prefix: [prefix_msg])
      call_handler(event, ctx_with_auth(producer: capturing_producer))

      assert_receive {:prompt, prompt_text}
      assert prompt_text =~ "main msg text"
      assert prompt_text =~ "prefix msg text"
    end

    test "returns nil when Summary.generate returns an error" do
      ctx = ctx_with_auth(producer: error_producer())
      result = call_handler(compact_event(), ctx)
      assert is_nil(result)
    end

    test "returns nil when Summary.generate returns an empty summary" do
      ctx = ctx_with_auth(producer: fake_producer(""))
      result = call_handler(compact_event(), ctx)
      assert is_nil(result)
    end
  end

  describe "session_before_compact — fallback paths" do
    test "returns nil when preparation has no messages to summarize" do
      result = call_handler(compact_event(messages: []), ctx_with_auth())
      assert is_nil(result)
    end

    test "returns nil when find_model returns nil" do
      find_fn = fn _provider, _id -> nil end
      result = call_handler(compact_event(), ctx(find_model: find_fn))
      assert is_nil(result)
    end

    test "returns nil when get_model_auth fails" do
      find_fn = fn _provider, _id -> fake_model() end
      auth_fn = fn _m -> {:error, "unauthorized"} end
      result = call_handler(compact_event(), ctx(find_model: find_fn, get_model_auth: auth_fn))
      assert is_nil(result)
    end

    test "calls find_model with :google provider and gemini model id" do
      test_pid = self()
      find_fn = fn provider, id -> send(test_pid, {:find_model, provider, id}) && nil end
      call_handler(compact_event(), ctx(find_model: find_fn))
      assert_receive {:find_model, :google, "gemini-2.5-flash"}
    end

    test "calls get_model_auth when find_model returns a model" do
      test_pid = self()
      find_fn = fn _provider, _id -> fake_model() end
      auth_fn = fn m -> send(test_pid, {:get_model_auth, m}) && {:error, "no key"} end
      call_handler(compact_event(), ctx(find_model: find_fn, get_model_auth: auth_fn))
      assert_receive {:get_model_auth, %Model{id: "gemini-2.5-flash"}}
    end
  end
end
