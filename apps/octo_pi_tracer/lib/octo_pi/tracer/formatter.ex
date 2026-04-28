defmodule OctoPi.Tracer.Formatter do
  @spec format([[atom()]], map(), map()) :: String.t()
  def format(event_name, measurements, metadata) do
    mono = System.monotonic_time(:microsecond)
    wall = DateTime.utc_now()

    name_str = Enum.map_join(event_name, ".", &to_string/1)
    kv = format_kv(measurements, metadata)

    "#{mono} #{DateTime.to_iso8601(wall)} [#{name_str}]#{if kv == "", do: "", else: " #{kv}"}"
  end

  defp format_kv(measurements, metadata) do
    meas_pairs = Enum.map(measurements, fn {k, v} -> "#{k}=#{format_value(v)}" end)

    meta_pairs =
      metadata
      |> Map.drop([:telemetry_span_context])
      |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)

    Enum.join(meas_pairs ++ meta_pairs, " ")
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_number(v), do: to_string(v)
  defp format_value(v) when is_atom(v), do: to_string(v)
  defp format_value(v), do: inspect(v)
end
