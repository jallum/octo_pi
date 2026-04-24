defmodule OctoPi.Coder.Extension.ProviderConfig do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          base_url: String.t(),
          api_key: String.t() | nil,
          api: :anthropic | :openai_completions | :openai_responses | :google | :bedrock,
          headers: %{String.t() => String.t()},
          auth_header: String.t() | nil,
          models: [ModelConfig.t()],
          stream_simple: (map() -> term()) | nil,
          oauth: oauth_config() | nil
        }

  @type oauth_config :: %{
          login: (map() -> term()),
          refresh_token: (String.t() -> term()),
          get_api_key: (-> String.t()),
          modify_models: ([ModelConfig.t()] -> [ModelConfig.t()]) | nil
        }

  defstruct id: nil,
            base_url: nil,
            api_key: nil,
            api: :openai_completions,
            headers: %{},
            auth_header: nil,
            models: [],
            stream_simple: nil,
            oauth: nil

  defimpl Inspect do
    def inspect(%{api_key: nil} = config, opts) do
      Inspect.Map.inspect(config, opts)
    end

    def inspect(config, opts) do
      Inspect.Map.inspect(%{config | api_key: "[REDACTED]"}, opts)
    end
  end

  defmodule ModelConfig do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t() | nil,
            api: atom() | nil,
            reasoning: boolean(),
            input_types: [:text | :image],
            cost: cost() | nil,
            context_window: non_neg_integer(),
            max_tokens: non_neg_integer(),
            compat: map() | nil
          }

    @type cost :: %{
            input_per_million: float(),
            output_per_million: float(),
            cache_read_per_million: float() | nil,
            cache_write_per_million: float() | nil
          }

    defstruct id: nil,
              name: nil,
              api: nil,
              reasoning: false,
              input_types: [:text],
              cost: nil,
              context_window: 128_000,
              max_tokens: 4_096,
              compat: nil
  end
end
