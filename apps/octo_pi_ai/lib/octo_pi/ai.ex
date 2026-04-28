defmodule OctoPi.AI do
  @moduledoc """
  Facade for the `octo_pi_ai` app: multi-provider streaming LLM client,
  ported from `badlogic/pi-mono`'s `packages/ai`.

  Public entry points:

      OctoPi.AI.stream(model, context, opts)     # → Stream of Event.t()
      OctoPi.AI.stream_to(model, context, opts, pid, ref) # push primitive

  The canonical types (`Context`, `Model`, `Message`, `Event`, …) and
  the `Provider` behaviour live in `OctoPi.AI.*` submodules. Provider
  implementations ship as sibling umbrella apps (e.g.
  `octo_pi_ai_anthropic`) and register themselves in the
  `OctoPi.AI.ProviderRegistry` on startup.

  See `docs/port-map/anthropic.md` for the Anthropic reference port.
  """

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Context
  alias OctoPi.AI.Model
  alias OctoPi.AI.ProviderRegistry

  @type thinking_level :: :minimal | :low | :medium | :high | :xhigh

  @type thinking_budgets :: %{optional(thinking_level()) => pos_integer()}

  @type stream_opt ::
          {:temperature, float()}
          | {:max_tokens, pos_integer()}
          | {:api_key, String.t()}
          | {:metadata, map()}
          | {:headers, %{optional(String.t()) => String.t()}}
          | {:reasoning, thinking_level()}
          | {:thinking_budgets, thinking_budgets()}
          | {:on_payload, (map(), Model.t() -> map() | nil) | nil}
          | {:on_response, (map(), Model.t() -> :ok) | nil}

  @type stream_opts :: [stream_opt()]

  @doc """
  Open a streaming request against the provider for `model.api`.
  Returns a lazy `Stream` of `OctoPi.AI.Event.t()`. The stream always
  terminates with exactly one of `Event.Done` or `Event.Error` — no
  exceptions escape the `Stream` boundary.

  """
  @spec stream(Model.t(), Context.t(), stream_opts()) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    provider = provider_module(model.api)
    call_opts = build_call_opts(opts)

    Stream.resource(
      fn ->
        ref = make_ref()
        {:ok, pid} = provider.stream_to(model, context, call_opts, self(), ref)
        mon = Process.monitor(pid)
        {pid, ref, mon}
      end,
      fn {_pid, ref, mon} = acc ->
        receive do
          {^ref, :event, event} -> {[event], acc}
          {^ref, :done} -> {:halt, acc}
          {:DOWN, ^mon, :process, _, _} -> {:halt, acc}
        end
      end,
      fn {pid, _ref, mon} ->
        Process.demonitor(mon, [:flush])
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      end
    )
  end

  @doc """
  Push primitive — spawns a producer task that sends `{ref, :event, event}`
  messages to `pid` and finishes with `{ref, :done}`. Returns `{:ok, producer_pid}`.

  """
  @spec stream_to(Model.t(), Context.t(), stream_opts(), pid(), reference()) :: {:ok, pid()}
  def stream_to(%Model{} = model, %Context{} = context, opts \\ [], pid, ref) do
    provider = provider_module(model.api)
    call_opts = build_call_opts(opts)
    provider.stream_to(model, context, call_opts, pid, ref)
  end

  defp build_call_opts(opts) when is_list(opts) do
    struct(
      CallOptions,
      Keyword.take(opts, [
        :temperature,
        :max_tokens,
        :api_key,
        :metadata,
        :headers,
        :reasoning,
        :thinking_budgets,
        :on_payload,
        :on_response
      ])
    )
  end

  @doc """
  Return the registered provider module for a given `api` atom, or
  raise if nothing is registered. Providers self-register on their
  `Application.start/2`.
  """
  @spec provider_module(atom()) :: module()
  def provider_module(api) when is_atom(api) do
    case ProviderRegistry.lookup(api) do
      nil ->
        raise ArgumentError,
              "no provider registered for api: #{inspect(api)}. " <>
                "Ensure the matching provider app is listed as a dependency " <>
                "and started (e.g. :octo_pi_ai_anthropic for :anthropic_messages)."

      module ->
        module
    end
  end
end
