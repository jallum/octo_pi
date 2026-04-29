defmodule OctoPi.Coder.Compaction.Summary do
  @moduledoc """
  Generate a compaction summary from an oldest-first list of agent
  messages. Port of `generateSummary`
  (`tmp/pi-mono/.../compaction/compaction.ts:526-590`).

  ## Prompt construction

  - Conversation is rendered with `Serialize.conversation/1` and wrapped
    in `<conversation>...</conversation>`.
  - When `:previous_summary` is set, it's wrapped in
    `<previous-summary>...</previous-summary>` and the base prompt
    switches from `Prompts.summarize/0` to `Prompts.update/0`.
  - `:variant => :turn_prefix` switches the base prompt to
    `Prompts.turn_prefix/0` and uses the `0.5 ×` reserve_tokens budget
    instead of the default `0.8 ×`.
  - `:custom_instructions`, when non-empty, is appended to the base
    prompt with the `\\n\\nAdditional focus: ...` separator upstream uses.

  ## Producer plumbing

  By default the request is issued via
  `OctoPi.AI.Providers.Anthropic.stream/3` and drained until
  `OctoPi.AI.Event.Done` (or `Event.Error`) — equivalent to upstream's
  `completeSimple/3`. Tests inject a producer module or 3-arity
  function via the `:producer` option to skip the HTTP layer.

  Returns `{:ok, text}` on success or `{:error, message}` on producer
  error / aborted stream.
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Compaction.Serialize
  alias OctoPi.Coder.Session.Messages

  @type variant :: :default | :turn_prefix

  @type opts :: [
          custom_instructions: String.t() | nil,
          previous_summary: String.t() | nil,
          api_key: String.t() | nil,
          headers: map() | nil,
          producer: module() | (Model.t(), AIContext.t(), keyword() -> Enumerable.t()),
          variant: variant(),
          thinking_level: OctoPi.AI.thinking_level() | :off | nil
        ]

  @default_producer OctoPi.AI

  @spec generate([struct()], Model.t(), pos_integer(), opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def generate(messages, %Model{} = model, reserve_tokens, opts \\ [])
      when is_list(messages) and is_integer(reserve_tokens) and reserve_tokens > 0 do
    variant = Keyword.get(opts, :variant, :default)
    previous_summary = Keyword.get(opts, :previous_summary)
    custom_instructions = Keyword.get(opts, :custom_instructions)
    max_tokens = trunc(reserve_factor(variant) * reserve_tokens)

    base_prompt =
      variant
      |> base_prompt(previous_summary)
      |> append_custom(custom_instructions)

    # Wire-edge transform: synthetic message types
    # (CompactionSummaryMessage, BranchSummaryMessage, …) flatten into
    # plain user messages here before they touch the provider. Same
    # rule applied in `BranchSummarization.generate/2` and the agent
    # loop's `messages_provider`.
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

    producer = Keyword.get(opts, :producer, @default_producer)

    producer
    |> invoke(model, ai_ctx, call_opts)
    |> consume()
  end

  defp reserve_factor(:turn_prefix), do: 0.5
  defp reserve_factor(_), do: 0.8

  # Mirrors `compaction.ts:569-572` —
  # `model.reasoning && thinkingLevel && thinkingLevel !== "off"`.
  # Off / nil / non-reasoning model → omit `reasoning` from StreamOptions.
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

  defp invoke(producer, model, ctx, opts) when is_atom(producer) do
    producer.stream(model, ctx, opts)
  end

  defp invoke(fun, model, ctx, opts) when is_function(fun, 3) do
    fun.(model, ctx, opts)
  end

  defp consume(stream) do
    stream
    |> Enum.reduce_while(:no_done, fn
      %Event.Done{message: %Assistant{content: content}}, _acc ->
        {:halt, {:ok, extract_text(content)}}

      %Event.Error{message: %Assistant{error_message: msg}}, _acc ->
        {:halt, {:error, msg || "Unknown error"}}

      _other, acc ->
        {:cont, acc}
    end)
    |> finalize()
  end

  defp finalize({:ok, _} = ok), do: ok
  defp finalize({:error, _} = err), do: err
  defp finalize(:no_done), do: {:error, "stream ended without Done"}

  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end
end
