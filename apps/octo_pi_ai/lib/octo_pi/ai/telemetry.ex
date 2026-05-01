defmodule OctoPi.AI.Telemetry do
  @moduledoc """
  Standardized telemetry helpers for AI provider request lifecycle events.

  All three functions emit under the `[:octo_pi_ai, :request, *]` namespace
  so a single handler attachment covers every provider. Common metadata
  (`api`, `model`) is always present; the `extras` map is merged in for
  vendor-specific keys (e.g. `%{auth_type: :oauth}` from Anthropic).

  ## Convention

  Provider implementations are expected to call these instead of calling
  `:telemetry.execute/3` directly for request lifecycle events.

  ## Events emitted

    * `[:octo_pi_ai, :request, :start]`
      measurements: `%{system_time}`
      metadata: `%{api, model}` + extras

    * `[:octo_pi_ai, :request, :stop]`
      measurements: caller-supplied (should include `duration`, token counts)
      metadata: `%{api, model}` + extras

    * `[:octo_pi_ai, :request, :exception]`
      measurements: `%{duration}`
      metadata: `%{api, model, kind, reason}` + extras
  """

  alias OctoPi.AI.Model

  @spec request_start(Model.t(), map()) :: :ok
  def request_start(%Model{} = model, extras \\ %{}) do
    :telemetry.execute(
      [:octo_pi_ai, :request, :start],
      %{},
      Map.merge(%{api: model.api, model: model.id}, extras)
    )
  end

  @spec request_stop(Model.t(), map(), map()) :: :ok
  def request_stop(%Model{} = model, measurements, extras \\ %{}) do
    :telemetry.execute(
      [:octo_pi_ai, :request, :stop],
      measurements,
      Map.merge(%{api: model.api, model: model.id}, extras)
    )
  end

  @spec request_exception(Model.t(), integer(), atom(), term(), map()) :: :ok
  def request_exception(%Model{} = model, start_mono, kind, reason, extras \\ %{}) do
    :telemetry.execute(
      [:octo_pi_ai, :request, :exception],
      %{duration: System.monotonic_time() - start_mono},
      Map.merge(%{api: model.api, model: model.id, kind: kind, reason: reason}, extras)
    )
  end
end
