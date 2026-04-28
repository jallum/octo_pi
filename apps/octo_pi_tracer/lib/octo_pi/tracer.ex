defmodule OctoPi.Tracer do
  @moduledoc """
  Registry and coordinator for telemetry-based trace logging.

  Each application registers a spec at startup describing the telemetry events
  it emits and the log level(s) to use. Handlers are not attached until
  `attach_all/0` is called — typically by `OctoPi.Tracer.FileBackend.install/1`
  when `--log-telemetry` is passed on the CLI.

  ## Spec shape

  All events at a single level:

      OctoPi.Tracer.register(%{
        id: :agent,
        description: "Agent session, turn, and tool lifecycle events",
        events: [[:octo_pi_agent, :session, :start], ...],
        level: :info
      })

  Per-event levels (the map keys are log levels):

      OctoPi.Tracer.register(%{
        id: :coder_extension,
        description: "Coder extension load, dispatch, and error events",
        events: %{
          info:    [[:octo_pi_coder, :extension, :loaded], ...],
          warning: [[:octo_pi_coder, :extension, :load_error], ...],
          debug:   [[:octo_pi_coder, :extension, :emit]]
        }
      })
  """

  @table __MODULE__

  require Logger

  alias OctoPi.Tracer.Formatter

  @type events_list :: [[atom()]]
  @type events_by_level :: %{Logger.level() => [[atom()]]}

  @type spec :: %{
          required(:id) => atom(),
          required(:description) => String.t(),
          required(:events) => events_list() | events_by_level(),
          optional(:level) => Logger.level()
        }

  @doc false
  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @doc """
  Registers a tracer spec in the ETS registry.

  If a spec with the same `id` already exists it is replaced. Registration
  does not attach any telemetry handlers; call `attach_all/0` to do that.
  """
  @spec register(spec()) :: :ok
  def register(%{id: id} = spec) do
    :ets.insert(@table, {id, spec})
    :ok
  end

  @doc """
  Returns all registered specs sorted by id.
  """
  @spec registered() :: [spec()]
  def registered do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, spec} -> spec end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Attaches telemetry handlers for every registered spec.

  Captures a monotonic base timestamp at call time; all subsequent trace lines
  report elapsed time relative to that moment. Safe to call multiple times —
  existing handlers are detached before re-attaching.
  """
  @spec attach_all() :: :ok
  def attach_all do
    base_mono = System.monotonic_time(:microsecond)

    Enum.each(registered(), fn spec ->
      hid = handler_id(spec.id)
      :telemetry.detach(hid)

      :telemetry.attach_many(
        hid,
        flat_events(spec),
        &__MODULE__.handle_event/4,
        build_config(spec, base_mono)
      )
    end)
  end

  @doc false
  def handle_event(event, measurements, metadata, {base_mono, level}) when is_atom(level) do
    line = Formatter.format(event, measurements, metadata, base_mono)
    Logger.log(level, line, domain: [:octo_pi_tracer])
  end

  @doc false
  def handle_event(event, measurements, metadata, {base_mono, event_to_level})
      when is_map(event_to_level) do
    level = Map.fetch!(event_to_level, event)
    line = Formatter.format(event, measurements, metadata, base_mono)
    Logger.log(level, line, domain: [:octo_pi_tracer])
  end

  @doc """
  Detaches the telemetry handler for the spec with the given `id`.

  Returns `:ok` if the handler was removed, `{:error, :not_found}` if it was
  not attached.
  """
  @spec detach(atom()) :: :ok | {:error, :not_found}
  def detach(id), do: :telemetry.detach(handler_id(id))

  defp flat_events(%{events: events}) when is_list(events), do: events

  defp flat_events(%{events: events_by_level}) when is_map(events_by_level) do
    Enum.flat_map(events_by_level, fn {_level, evts} -> evts end)
  end

  defp build_config(%{events: events, level: default_level}, base_mono) when is_list(events),
    do: {base_mono, default_level}

  defp build_config(%{events: events_by_level}, base_mono) when is_map(events_by_level) do
    event_to_level =
      Enum.flat_map(events_by_level, fn {level, evts} -> Enum.map(evts, &{&1, level}) end)
      |> Map.new()

    {base_mono, event_to_level}
  end

  defp handler_id(id), do: "octo_pi_tracer_#{id}"
end
