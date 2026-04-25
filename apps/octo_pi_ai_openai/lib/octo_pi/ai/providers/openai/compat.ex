defmodule OctoPi.AI.Providers.OpenAI.Compat do
  @moduledoc """
  Provider-specific compatibility knobs for the OpenAI Completions API
  dialect. A resolved compat struct tunes request building and stream
  decoding for provider quirks (e.g. xAI doesn't support `store`,
  OpenRouter wraps reasoning in a nested object, chutes.ai uses the
  legacy `max_tokens` field).

  `detect/1` auto-detects defaults from `model.provider` and
  `model.base_url`. `resolve/1` merges explicit `model.compat`
  overrides onto the detected defaults.

  Ported from `openai-completions.ts` L1004-1088.
  """

  alias OctoPi.AI.Model

  @type thinking_format :: :openai | :openrouter | :zai | :qwen | :qwen_chat_template
  @type max_tokens_field :: :max_completion_tokens | :max_tokens

  @type t :: %__MODULE__{
          supports_store: boolean(),
          supports_developer_role: boolean(),
          supports_reasoning_effort: boolean(),
          reasoning_effort_map: %{optional(atom()) => String.t()},
          supports_usage_in_streaming: boolean(),
          max_tokens_field: max_tokens_field(),
          requires_tool_result_name: boolean(),
          requires_assistant_after_tool_result: boolean(),
          requires_thinking_as_text: boolean(),
          thinking_format: thinking_format(),
          supports_strict_mode: boolean(),
          cache_control_format: :anthropic | nil,
          send_session_affinity_headers: boolean(),
          zai_tool_stream: boolean(),
          open_router_routing: map(),
          vercel_gateway_routing: map()
        }

  defstruct supports_store: true,
            supports_developer_role: true,
            supports_reasoning_effort: true,
            reasoning_effort_map: %{},
            supports_usage_in_streaming: true,
            max_tokens_field: :max_completion_tokens,
            requires_tool_result_name: false,
            requires_assistant_after_tool_result: false,
            requires_thinking_as_text: false,
            thinking_format: :openai,
            supports_strict_mode: true,
            cache_control_format: nil,
            send_session_affinity_headers: false,
            zai_tool_stream: false,
            open_router_routing: %{},
            vercel_gateway_routing: %{}

  @doc """
  Auto-detect compat settings from `model.provider` and `model.base_url`.
  """
  @spec detect(Model.t()) :: t()
  def detect(%Model{} = model) do
    flags = classify(model)

    %__MODULE__{
      supports_store: not flags.non_standard,
      supports_developer_role: not flags.non_standard,
      supports_reasoning_effort: not flags.grok and not flags.zai,
      reasoning_effort_map: reasoning_effort_map(flags, model),
      supports_usage_in_streaming: true,
      max_tokens_field: max_tokens_field(model.base_url),
      requires_tool_result_name: false,
      requires_assistant_after_tool_result: false,
      requires_thinking_as_text: false,
      thinking_format: thinking_format(flags, model),
      supports_strict_mode: true,
      cache_control_format: cache_control_format(model),
      send_session_affinity_headers: false,
      zai_tool_stream: false,
      open_router_routing: %{},
      vercel_gateway_routing: %{}
    }
  end

  defp classify(%Model{provider: provider, base_url: base_url}) do
    zai = provider == :zai or String.contains?(base_url, "api.z.ai")
    grok = provider == :xai or String.contains?(base_url, "api.x.ai")
    groq = provider == :groq or String.contains?(base_url, "groq.com")

    %{
      zai: zai,
      grok: grok,
      groq: groq,
      non_standard: non_standard?(provider, base_url, zai, grok)
    }
  end

  defp non_standard?(provider, base_url, zai, grok) do
    grok or zai or
      provider == :cerebras or String.contains?(base_url, "cerebras.ai") or
      String.contains?(base_url, "chutes.ai") or
      String.contains?(base_url, "deepseek.com") or
      provider == :opencode or String.contains?(base_url, "opencode.ai")
  end

  defp cache_control_format(%Model{provider: :openrouter, id: id}) do
    if String.starts_with?(id, "anthropic/"), do: :anthropic, else: nil
  end

  defp cache_control_format(_model), do: nil

  defp reasoning_effort_map(%{groq: true}, %Model{id: "qwen/qwen3-32b"}) do
    %{minimal: "default", low: "default", medium: "default", high: "default", xhigh: "default"}
  end

  defp reasoning_effort_map(_flags, _model), do: %{}

  defp thinking_format(%{zai: true}, _model), do: :zai

  defp thinking_format(_flags, %Model{provider: :openrouter}), do: :openrouter

  defp thinking_format(_flags, %Model{base_url: base_url}) do
    if String.contains?(base_url, "openrouter.ai"), do: :openrouter, else: :openai
  end

  defp max_tokens_field(base_url) do
    if String.contains?(base_url, "chutes.ai"), do: :max_tokens, else: :max_completion_tokens
  end

  @doc """
  Resolve compat for a model: merge explicit `model.compat` overrides
  onto auto-detected defaults. Returns detected defaults when
  `model.compat` is nil.
  """
  @spec resolve(Model.t()) :: t()
  def resolve(%Model{compat: nil} = model), do: detect(model)

  def resolve(%Model{compat: overrides} = model) when is_map(overrides) do
    detected = detect(model)

    fields =
      for {key, detected_val} <- Map.from_struct(detected), into: %{} do
        case Map.fetch(overrides, key) do
          {:ok, val} when not is_nil(val) -> {key, val}
          _ -> {key, detected_val}
        end
      end

    struct!(__MODULE__, fields)
  end
end
