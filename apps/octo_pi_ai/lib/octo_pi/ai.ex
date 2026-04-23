defmodule OctoPi.AI do
  @moduledoc """
  Facade for the `octo_pi_ai` app: multi-provider streaming LLM client,
  ported from `badlogic/pi-mono`'s `packages/ai`.

  Public entry points:

      OctoPi.AI.stream(model, context, opts)        # → Stream of Event.t()
      OctoPi.AI.stream_simple(model, context, opts) # same, with reasoning knob

  The canonical types (`Context`, `Model`, `Message`, `Event`, …) and
  the `Provider` behaviour live in `OctoPi.AI.*` submodules. Provider
  implementations ship as sibling umbrella apps (e.g.
  `octo_pi_ai_anthropic`) and register themselves in the providers
  registry under application env `{:octo_pi_ai, :providers}` on
  startup.

  See `docs/port-map/anthropic.md` for the Anthropic reference port.
  """

  alias OctoPi.AI.{Context, Model, StreamOptions}

  @doc """
  Open a streaming request against the provider for `model.api`.
  Returns a lazy `Stream` of `OctoPi.AI.Event.t()`. The stream always
  terminates with exactly one of `Event.Done` or `Event.Error` — no
  exceptions escape the `Stream` boundary.
  """
  @spec stream(Model.t(), Context.t(), StreamOptions.t() | nil) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ nil) do
    provider_module(model.api).stream(model, context, opts || %StreamOptions{})
  end

  @doc """
  Like `stream/3` but accepts `:reasoning` + `:thinking_budgets` on
  the options struct; providers translate those to their native
  config. Same return shape as `stream/3`.
  """
  @spec stream_simple(Model.t(), Context.t(), StreamOptions.t() | nil) :: Enumerable.t()
  def stream_simple(%Model{} = model, %Context{} = context, opts \\ nil) do
    provider_module(model.api).stream_simple(model, context, opts || %StreamOptions{})
  end

  @doc """
  Return the registered provider module for a given `api` atom, or
  raise if nothing is registered. Providers self-register on their
  `Application.start/2`.
  """
  @spec provider_module(atom()) :: module()
  def provider_module(api) when is_atom(api) do
    :octo_pi_ai
    |> Application.get_env(:providers, %{})
    |> Map.get(api)
    |> case do
      nil ->
        raise ArgumentError,
              "no provider registered for api: #{inspect(api)}. " <>
                "Ensure the matching provider app is listed as a dependency " <>
                "and started (e.g. :octo_pi_ai_anthropic for :anthropic_messages)."

      module when is_atom(module) ->
        module
    end
  end
end
