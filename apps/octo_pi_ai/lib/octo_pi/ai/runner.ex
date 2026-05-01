defmodule OctoPi.AI.Runner do
  @moduledoc """
  Behaviour every runner module implements.

  A *runner* is a vendor/deployment endpoint (Anthropic, OpenAI, Ollama,
  LM Studio, OpenRouter, ...). It owns:

    * the **wire codec** (`api/0`) it dispatches to — see `OctoPi.AI.Api`
    * a **default base URL** (`default_base_url/0`)
    * an **auth strategy** (`auth/0`) — resolved by `OctoPi.AI.Auth`
    * a **catalog** — either static (hand-edited models.json) or live via
      `lookup/2` and `discover/1`

  Runners are named by atoms in `OctoPi.AI.RunnerRegistry`. The atom is
  also the JSON key in the user's `models.json`. If the JSON key doesn't
  match a registered runner, the entry must specify `"runner": "<atom>"`
  to disambiguate.
  """

  alias OctoPi.AI.Model

  @type auth_strategy ::
          :none
          | {:env, String.t()}
          | {:literal, String.t()}
          | {:cmd, String.t()}

  @type config :: %{optional(atom()) => term()}

  @doc "Wire codec atom (`:anthropic_messages`, `:openai_completions`, ...)."
  @callback api() :: atom()

  @doc "Default base URL when the JSON entry doesn't override it. `nil` if there is no sensible default."
  @callback default_base_url() :: String.t() | nil

  @doc "Default auth strategy. May be overridden per-instance in `auth.json`."
  @callback auth() :: auth_strategy()

  @doc """
  Validate the runner-specific portion of a `models.json` entry.

  Receives the full entry map (with string keys). Returns `:ok` or
  `{:error, message}`. The generic schema is enforced by `ModelRegistry`
  before this is called.
  """
  @callback validate(config()) :: :ok | {:error, String.t()}

  @doc """
  Resolve a single model id against this runner's live catalog.

  Returns `{:ok, %Model{}}` on hit, `:not_found` if the runner can answer
  but doesn't have the id, or `:unsupported` if the runner has no catalog
  endpoint (callers must add the model to `models.json` by hand).
  """
  @callback lookup(id :: String.t(), config()) ::
              {:ok, Model.t()} | :not_found | :unsupported

  @doc """
  Bulk discovery. Returns the runner's full available catalog.

  `:unsupported` for runners without a queryable `/models`-style endpoint.
  """
  @callback discover(config()) ::
              {:ok, [Model.t()]} | {:error, term()} | :unsupported
end
