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
          headers: %{optional(String.t()) => String.t()} | nil
        }

  defstruct [
    :id,
    :name,
    :api,
    :provider,
    :base_url,
    :context_window,
    :max_tokens,
    :headers,
    reasoning: false,
    input: [:text],
    cost: %Cost{}
  ]
end
