defmodule OctoPi.Tracer.Formatter do
  @moduledoc false
  @spec format([[atom()]], map(), map(), integer()) :: String.t()
  def format(event_name, measurements, metadata, base_mono) do
    elapsed = System.monotonic_time(:microsecond) - base_mono
    wall = DateTime.utc_now()

    name_str = Enum.map_join(event_name, ".", &to_string/1)
    kv = format_kv(measurements, metadata)

    "+#{format_elapsed(elapsed)} #{DateTime.to_iso8601(wall)} [#{name_str}]#{if kv == "", do: "", else: " #{kv}"}"
  end

  defp format_elapsed(us) do
    s = div(us, 1_000_000)
    frac = rem(us, 1_000_000)

    "#{String.pad_leading(Integer.to_string(s), 5)}.#{String.pad_leading(Integer.to_string(frac), 6, "0")}"
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
