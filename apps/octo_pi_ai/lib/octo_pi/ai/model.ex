defmodule OctoPi.AI.Model do
  @moduledoc """
  Provider-agnostic model descriptor. `api` identifies which provider
  transport/codec to use (e.g. `:anthropic_messages`); `provider` is
  the vendor atom (e.g. `:anthropic`). `base_url` is the HTTP endpoint;
  `cost` gives per-million-token pricing.

  `reasoning` is true for models that support thinking/reasoning (and
  expose a `thinking` / `reasoning_effort` knob). `input` lists the
  input modalities the model accepts (e.g. `[:text, :image]`).
  """

  alias OctoPi.AI.Model.Cost

  @type input_modality :: :text | :image

  @enforce_keys [:id, :name, :api, :provider, :base_url, :context_window, :max_tokens]
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          api: atom(),
          provider: atom(),
          base_url: String.t(),
          reasoning: boolean(),
          input: [input_modality()],
          cost: Cost.t(),
          context_window: pos_integer(),
          max_tokens: pos_integer(),
          compat: map() | nil
        }

  defstruct [
    :id,
    :name,
    :api,
    :provider,
    :base_url,
    :context_window,
    :max_tokens,
    reasoning: false,
    input: [:text],
    cost: %Cost{},
    compat: nil
  ]

  alias OctoPi.AI.Usage

  @doc """
  Calculates the dollar cost for `usage` given `model`'s per-million-token
  pricing. Returns an updated `%Usage{}` with `cost` filled in.
  Mirrors `calculateCost` in `pi-ai/src/models.ts`.
  """
  @spec calculate_cost(t(), Usage.t()) :: Usage.t()
  def calculate_cost(%__MODULE__{cost: pricing}, %Usage{} = usage) do
    input_cost = pricing.input / 1_000_000 * usage.input
    output_cost = pricing.output / 1_000_000 * usage.output
    cache_read_cost = pricing.cache_read / 1_000_000 * usage.cache_read
    cache_write_cost = pricing.cache_write / 1_000_000 * usage.cache_write

    cost = %Usage.Cost{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost,
      total: input_cost + output_cost + cache_read_cost + cache_write_cost
    }

    %{usage | cost: cost}
  end
end
