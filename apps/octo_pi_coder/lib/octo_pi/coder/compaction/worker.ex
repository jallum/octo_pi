defmodule OctoPi.Coder.Compaction.Worker do
  @moduledoc """
  Async worker entry point for compaction. Spawned via
  `OctoPi.Coder.Compaction.async/5`.

  Drives the LLM streaming via `OctoPi.AI.stream_to/4` and a `receive`
  loop — *not* `Stream.resource` / `Enum.reduce_while`. The recv loop
  multiplexes producer events with `:abort` messages so cancellation
  is graceful (kill the producer, return `{:cancel, :aborted}` to the
  caller) rather than requiring a brutal `Process.exit/2` from
  outside.

  Mirrors `OctoPi.Agent.Turn.Worker`'s pattern. The two phases of a
  split-turn compact (history + turn-prefix) run in parallel sub-Tasks
  so an abort kills both.

  ## Message protocol

  Receives:
    * `:abort` — cancel any in-flight producer and exit, sending
      `{:compact_done, ref, {:cancel, :aborted}}` to the parent.

  Sends to parent:
    * `{:compact_done, ref, result}` — `result` is the same shape
      `Compaction.compact/3` used to return: `{:ok, %Result{}}` /
      `{:error, reason}` / `{:cancel, :aborted}`.
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Preparation
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Compaction.Serialize
  alias OctoPi.Coder.Session.Messages

  @turn_separator "\n\n---\n\n**Turn Context (split turn):**\n\n"

  @type compact_result ::
          {:ok, Result.t()} | {:error, term()} | {:cancel, :aborted}

  @doc """
  Worker entry point. Runs in the spawned process; sends the final
  `{:compact_done, ref, result}` to `parent` when finished or
  cancelled.
  """
  @spec run(pid(), reference(), Preparation.t(), Model.t(), keyword()) :: :ok
  def run(parent, ref, %Preparation{} = prep, %Model{} = model, opts) do
    result = compact(prep, model, opts)
    send(parent, {:compact_done, ref, result})
    :ok
  end

  # ---- compact (orchestration of single-pass / split-turn) ----------------

  defp compact(%Preparation{split_turn?: split?, turn_prefix_messages: tp} = prep, model, opts)
       when split? == false or tp == [] do
    case generate_summary(prep.messages_to_summarize, model, prep.settings.reserve_tokens, history_opts(prep, opts)) do
      {:ok, body} -> {:ok, build_result(prep, body)}
      other -> other
    end
  end

  defp compact(%Preparation{} = prep, model, opts) do
    # Split-turn: history + turn-prefix in parallel sub-Tasks. An
    # :abort message to this worker cancels both.
    parent = self()
    history_ref = make_ref()
    turn_ref = make_ref()

    history_pid =
      spawn_link(fn ->
        result = history_summary(prep, model, opts)
        send(parent, {:sub_summary, history_ref, result})
      end)

    turn_pid =
      spawn_link(fn ->
        result =
          generate_summary(
            prep.turn_prefix_messages,
            model,
            prep.settings.reserve_tokens,
            turn_prefix_opts(opts)
          )

        send(parent, {:sub_summary, turn_ref, result})
      end)

    case await_split([{history_ref, history_pid, nil}, {turn_ref, turn_pid, nil}]) do
      {:ok, [hist, turn]} -> {:ok, build_result(prep, hist <> @turn_separator <> turn)}
      other -> other
    end
  end

  defp await_split(slots) do
    if Enum.all?(slots, fn {_ref, _pid, value} -> not is_nil(value) end) do
      reduce_split(slots)
    else
      recv_split(slots)
    end
  end

  defp reduce_split(slots) do
    results = Enum.map(slots, fn {_, _, v} -> v end)
    Enum.find(results, &split_failure?/1) || {:ok, Enum.map(results, fn {:ok, body} -> body end)}
  end

  defp split_failure?({:error, _}), do: true
  defp split_failure?({:cancel, :aborted}), do: true
  defp split_failure?(_), do: false

  defp recv_split(slots) do
    receive do
      {:sub_summary, ref, result} ->
        slots
        |> Enum.map(fn
          {^ref, pid, _} -> {ref, pid, result}
          other -> other
        end)
        |> await_split()

      :abort ->
        for {_ref, pid, _} <- slots, Process.alive?(pid), do: Process.exit(pid, :kill)
        {:cancel, :aborted}
    end
  end

  # ---- single-pass summary using stream_to + recv loop --------------------

  defp generate_summary(messages, %Model{} = model, reserve_tokens, opts)
       when is_list(messages) and is_integer(reserve_tokens) and reserve_tokens > 0 do
    variant = Keyword.get(opts, :variant, :default)
    previous_summary = Keyword.get(opts, :previous_summary)
    custom_instructions = Keyword.get(opts, :custom_instructions)
    max_tokens = trunc(reserve_factor(variant) * reserve_tokens)

    base_prompt =
      variant
      |> base_prompt(previous_summary)
      |> append_custom(custom_instructions)

    convo = messages |> Messages.to_llm() |> Serialize.conversation()
    prompt_text = build_prompt(convo, previous_summary, base_prompt)

    user_message = %User{
      content: [%Text{text: prompt_text}],
      timestamp: System.system_time(:millisecond)
    }

    ai_ctx = %AIContext{
      system_prompt: Prompts.system(),
      messages: [user_message],
      tools: []
    }

    call_opts = [
      max_tokens: max_tokens,
      api_key: Keyword.get(opts, :api_key),
      headers: Keyword.get(opts, :headers),
      reasoning: resolve_reasoning(model, Keyword.get(opts, :thinking_level))
    ]

    producer = Keyword.get(opts, :producer, OctoPi.AI)
    consume_via_recv(producer, model, ai_ctx, call_opts)
  end

  # The shape of consumption depends on whether the producer is a
  # provider module (real streaming, sends events to self via
  # stream_to) or a test-injected function returning an Enumerable
  # of events directly.
  defp consume_via_recv(producer, model, ctx, call_opts) when is_atom(producer) do
    {:ok, producer_pid} = producer.stream_to(model, ctx, call_opts, self())
    monitor = Process.monitor(producer_pid)

    try do
      recv_loop(producer_pid, monitor)
    after
      Process.demonitor(monitor, [:flush])
      if Process.alive?(producer_pid), do: Process.exit(producer_pid, :shutdown)
    end
  end

  defp consume_via_recv(fun, model, ctx, call_opts) when is_function(fun, 3) do
    # Function-producer (test path): synchronously enumerate events.
    # Still honors :abort by checking the inbox after each event.
    model
    |> fun.(ctx, call_opts)
    |> Enum.reduce_while(:no_done, fn event, acc ->
      receive do
        :abort -> {:halt, :aborted}
      after
        0 ->
          case event do
            %Event.Done{message: %Assistant{content: content}} ->
              {:halt, {:ok, extract_text(content)}}

            %Event.Error{message: %Assistant{error_message: msg}} ->
              {:halt, {:error, msg || "Unknown error"}}

            _ ->
              {:cont, acc}
          end
      end
    end)
    |> finalize()
  end

  defp recv_loop(producer_pid, monitor) do
    receive do
      {^producer_pid, :event, %Event.Done{message: %Assistant{content: content}}} ->
        drain_until_done(producer_pid)
        {:ok, extract_text(content)}

      {^producer_pid, :event, %Event.Error{message: %Assistant{error_message: msg}}} ->
        drain_until_done(producer_pid)
        {:error, msg || "Unknown error"}

      {^producer_pid, :event, _other} ->
        recv_loop(producer_pid, monitor)

      {^producer_pid, :done} ->
        # Stream ended without Done/Error — defensively treat as error.
        {:error, "stream ended without Done"}

      {:DOWN, ^monitor, :process, ^producer_pid, _reason} ->
        {:error, "producer process exited"}

      :abort ->
        {:cancel, :aborted}
    end
  end

  defp drain_until_done(producer_pid) do
    # The producer always sends a final `:done` after the last event.
    # Drain it so it doesn't leak into the next compaction's mailbox.
    receive do
      {^producer_pid, :done} -> :ok
      {^producer_pid, :event, _} -> drain_until_done(producer_pid)
    after
      100 -> :ok
    end
  end

  defp finalize(:no_done), do: {:error, "stream ended without Done"}
  defp finalize(:aborted), do: {:cancel, :aborted}
  defp finalize(other), do: other

  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp reserve_factor(:turn_prefix), do: 0.5
  defp reserve_factor(_), do: 0.8

  defp resolve_reasoning(%Model{reasoning: true}, level) when level in [:minimal, :low, :medium, :high, :xhigh],
    do: level

  defp resolve_reasoning(_model, _level), do: nil

  defp base_prompt(:turn_prefix, _prev), do: Prompts.turn_prefix()
  defp base_prompt(_, nil), do: Prompts.summarize()
  defp base_prompt(_, _prev), do: Prompts.update()

  defp append_custom(prompt, nil), do: prompt
  defp append_custom(prompt, ""), do: prompt

  defp append_custom(prompt, instructions) when is_binary(instructions) do
    prompt <> "\n\nAdditional focus: " <> instructions
  end

  defp build_prompt(convo, nil, base_prompt) do
    "<conversation>\n" <> convo <> "\n</conversation>\n\n" <> base_prompt
  end

  defp build_prompt(convo, prev, base_prompt) do
    "<conversation>\n" <>
      convo <>
      "\n</conversation>\n\n" <>
      "<previous-summary>\n" <>
      prev <>
      "\n</previous-summary>\n\n" <>
      base_prompt
  end

  defp history_summary(%Preparation{messages_to_summarize: []}, _model, _opts), do: {:ok, "No prior history."}

  defp history_summary(%Preparation{} = prep, %Model{} = model, opts) do
    generate_summary(prep.messages_to_summarize, model, prep.settings.reserve_tokens, history_opts(prep, opts))
  end

  defp history_opts(%Preparation{} = prep, opts) do
    Enum.reject(
      [
        previous_summary: prep.previous_summary,
        custom_instructions: Keyword.get(opts, :custom_instructions),
        api_key: Keyword.get(opts, :api_key),
        headers: Keyword.get(opts, :headers),
        thinking_level: Keyword.get(opts, :thinking_level),
        producer: Keyword.get(opts, :producer)
      ],
      fn {_, v} -> is_nil(v) end
    )
  end

  defp turn_prefix_opts(opts) do
    Enum.reject(
      [
        variant: :turn_prefix,
        api_key: Keyword.get(opts, :api_key),
        headers: Keyword.get(opts, :headers),
        thinking_level: Keyword.get(opts, :thinking_level),
        producer: Keyword.get(opts, :producer)
      ],
      fn {_, v} -> is_nil(v) end
    )
  end

  defp build_result(%Preparation{} = prep, body) do
    lists = FileOps.compute_lists(prep.file_ops)
    summary = body <> FileOps.format(lists.read_files, lists.modified_files)

    details = %{
      "readFiles" => lists.read_files,
      "modifiedFiles" => lists.modified_files
    }

    %Result{
      summary: summary,
      first_kept_entry_id: prep.first_kept_entry_id,
      tokens_before: prep.tokens_before,
      details: details
    }
  end
end
