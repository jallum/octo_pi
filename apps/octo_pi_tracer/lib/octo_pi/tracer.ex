defmodule OctoPi.Tracer do
  @moduledoc false

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

  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @spec register(spec()) :: :ok
  def register(%{id: id} = spec) do
    :ets.insert(@table, {id, spec})
    :ok
  end

  @spec registered() :: [spec()]
  def registered do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, spec} -> spec end)
    |> Enum.sort_by(& &1.id)
  end

  @spec attach_all() :: :ok
  def attach_all do
    base_mono = System.monotonic_time(:microsecond)

    Enum.each(registered(), fn spec ->
      hid = handler_id(spec.id)
      :telemetry.detach(hid)
      :telemetry.attach_many(hid, flat_events(spec), build_handler(spec), base_mono)
    end)
  end

  @spec detach(atom()) :: :ok | {:error, :not_found}
  def detach(id), do: :telemetry.detach(handler_id(id))

  defp flat_events(%{events: events}) when is_list(events), do: events

  defp flat_events(%{events: events_by_level}) when is_map(events_by_level) do
    Enum.flat_map(events_by_level, fn {_level, evts} -> evts end)
  end

  defp build_handler(%{events: events, level: default_level}) when is_list(events) do
    fn event, measurements, metadata, base_mono ->
      line = Formatter.format(event, measurements, metadata, base_mono)
      Logger.log(default_level, line, domain: [:octo_pi_tracer])
    end
  end

  defp build_handler(%{events: events_by_level}) when is_map(events_by_level) do
    event_to_level =
      Enum.flat_map(events_by_level, fn {level, evts} -> Enum.map(evts, &{&1, level}) end)
      |> Map.new()

    fn event, measurements, metadata, base_mono ->
      level = Map.fetch!(event_to_level, event)
      line = Formatter.format(event, measurements, metadata, base_mono)
      Logger.log(level, line, domain: [:octo_pi_tracer])
    end
  end

  defp handler_id(id), do: "octo_pi_tracer_#{id}"
end
