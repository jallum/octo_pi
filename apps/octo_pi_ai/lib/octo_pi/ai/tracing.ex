defmodule OctoPi.AI.Tracing do
  @moduledoc """
  Optional stderr tracing handler for OctoPi.AI telemetry events.

  Auto-attached at app start when `OCTO_PI_TRACE=1` (or any of `1` /
  `true`) is set in the environment, or when `config :octo_pi_ai, :trace,
  true` is set. Skipped in `MIX_ENV=test` unless the test explicitly
  calls `attach/0`.

  Manual control via `attach/0` and `detach/0`. Both are idempotent.

  Each event is formatted as one line:

      [trace] octo_pi_ai.runner.lookup.stop runner=lmstudio id=qwen3-8b outcome=ok dur=412ms

  Auth events log the `strategy` tag but never the resolved secret value.
  """

  @handler_id :octo_pi_ai_tracing

  @events [
    [:octo_pi_ai, :model_registry, :load, :start],
    [:octo_pi_ai, :model_registry, :load, :stop],
    [:octo_pi_ai, :model_registry, :resolve, :start],
    [:octo_pi_ai, :model_registry, :resolve, :stop],
    [:octo_pi_ai, :model_registry, :resolve, :exception],
    [:octo_pi_ai, :auth, :resolve, :start],
    [:octo_pi_ai, :auth, :resolve, :stop],
    [:octo_pi_ai, :auth, :resolve, :exception],
    [:octo_pi_ai, :runner, :lookup, :start],
    [:octo_pi_ai, :runner, :lookup, :stop],
    [:octo_pi_ai, :runner, :lookup, :exception],
    [:octo_pi_ai, :runner, :discover, :start],
    [:octo_pi_ai, :runner, :discover, :stop],
    [:octo_pi_ai, :runner, :discover, :exception],
    [:octo_pi_ai, :request, :start],
    [:octo_pi_ai, :request, :stop],
    [:octo_pi_ai, :request, :exception]
  ]

  @spec events() :: [[atom()]]
  def events, do: @events

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok
  def detach do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc "Attach when env / config opts in and we are not in MIX_ENV=test."
  @spec maybe_attach() :: :ok | {:error, :already_exists} | :skipped
  def maybe_attach do
    cond do
      Application.get_env(:octo_pi_ai, :trace, false) -> attach()
      System.get_env("OCTO_PI_TRACE") in ["1", "true"] and not test_env?() -> attach()
      true -> :skipped
    end
  end

  defp test_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    IO.puts(:stderr, format_line(event, measurements, metadata))
  end

  defp format_line(event, measurements, metadata) do
    name = Enum.map_join(event, ".", &Atom.to_string/1)
    meta_parts = filter_meta(event, metadata)
    duration_part = duration_part(measurements)

    suffix =
      Enum.map_join(meta_parts ++ duration_part, "", fn {k, v} -> " #{k}=#{format_val(v)}" end)

    "[trace] #{name}#{suffix}"
  end

  defp duration_part(%{duration: ns}) when is_integer(ns) do
    [{:dur, "#{System.convert_time_unit(ns, :native, :millisecond)}ms"}]
  end

  defp duration_part(_), do: []

  defp filter_meta([:octo_pi_ai, :auth, :resolve | _], metadata) do
    metadata |> Map.take([:runner, :strategy, :outcome]) |> Enum.to_list()
  end

  defp filter_meta(_event, metadata) do
    metadata
    |> Map.delete(:telemetry_span_context)
    |> Enum.to_list()
  end

  defp format_val(v) when is_atom(v), do: Atom.to_string(v)
  defp format_val(v) when is_binary(v), do: v
  defp format_val(v) when is_integer(v) or is_float(v), do: v
  defp format_val(v), do: inspect(v)
end
