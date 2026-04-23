defmodule OctoPi.AI do
  @moduledoc """
  Facade for the `octo_pi_ai` app: multi-provider streaming LLM client,
  ported from `badlogic/pi-mono`'s `packages/ai`.

  Public entry points:

      OctoPi.AI.stream(model, context, opts)        # → Stream of Event.t()
      OctoPi.AI.stream_simple(model, context, opts) # same, with reasoning knob

  The canonical types (`Context`, `Model`, `Message`, `Event`, …) and
  the `Provider` behaviour live in `OctoPi.AI.*` submodules. Provider
  implementations live in `OctoPi.AI.Providers.*`.

  See `docs/port-map/anthropic.md` for the port reference.
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

  @spec provider_module(atom()) :: module()
  defp provider_module(:anthropic_messages), do: OctoPi.AI.Providers.Anthropic

  defp provider_module(api),
    do: raise(ArgumentError, "no provider registered for api: #{inspect(api)}")
end
