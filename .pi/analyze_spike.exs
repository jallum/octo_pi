defmodule Spike do
  def main do
    path = System.argv() |> List.first() || "trace2.log"
    IO.puts("# analyzing #{path}")
    lines = File.stream!(path) |> Enum.to_list()

    # Q1: handle_info duration by kind
    handle_info =
      lines
      |> Enum.filter(&String.contains?(&1, "interactive.handle_info.stop"))
      |> Enum.map(&parse/1)
      |> Enum.group_by(& &1.kind)
      |> Enum.map(fn {kind, evs} ->
        durations = Enum.map(evs, &(&1.duration / 1000.0)) |> Enum.sort()
        {kind, durations}
      end)

    # Q2: markdown.render duration vs text_bytes (streaming + finalized)
    markdown =
      lines
      |> Enum.filter(&String.contains?(&1, "markdown.render.stop"))
      |> Enum.map(&parse/1)

    # Q3: key.latency vs mailbox_len_at_arrival
    keys =
      lines
      |> Enum.filter(&String.contains?(&1, "key.latency"))
      |> Enum.map(&parse/1)

    # Q4: transcript.render duration vs msg_count
    transcript =
      lines
      |> Enum.filter(&String.contains?(&1, "transcript.render.stop"))
      |> Enum.map(&parse/1)

    IO.puts("\n=== Q1: handle_info duration (us) by kind ===")
    Enum.each(handle_info, fn {kind, ds} ->
      n = length(ds)
      median = pct(ds, 0.5)
      p99 = pct(ds, 0.99)
      max = List.last(ds)
      mean = Enum.sum(ds) / n
      IO.puts("  #{kind}: n=#{n} median=#{f(median)} p99=#{f(p99)} max=#{f(max)} mean=#{f(mean)}")
    end)

    IO.puts("\n=== Q2: markdown.render duration vs text_bytes ===")
    bins = bin_by_text_bytes(markdown)
    Enum.each(bins, fn {bin, evs} ->
      ds = Enum.map(evs, &(&1.duration / 1000.0)) |> Enum.sort()
      n = length(ds)
      if n > 0 do
        IO.puts("  text_bytes #{bin}: n=#{n} median=#{f(pct(ds, 0.5))} p99=#{f(pct(ds, 0.99))}")
      end
    end)

    IO.puts("\n=== Q3: key.latency by mailbox_len_at_arrival ===")
    keys_by_q = Enum.group_by(keys, & &1.mailbox_len) |> Enum.sort_by(&elem(&1, 0))
    Enum.each(keys_by_q, fn {q, evs} ->
      ds = Enum.map(evs, &(&1.duration_us / 1000.0)) |> Enum.sort()
      n = length(ds)
      IO.puts("  mailbox=#{q}: n=#{n} median=#{f(pct(ds, 0.5))} p99=#{f(pct(ds, 0.99))} max=#{f(List.last(ds))}")
    end)

    IO.puts("\n=== Q4: transcript.render duration vs msg_count ===")
    trans_by_n = Enum.group_by(transcript, & &1.msg_count) |> Enum.sort_by(&elem(&1, 0))
    Enum.each(trans_by_n, fn {mc, evs} ->
      streaming = Enum.filter(evs, & &1.streaming) |> Enum.map(&(&1.duration / 1000.0)) |> Enum.sort()
      idle = Enum.filter(evs, &(not &1.streaming)) |> Enum.map(&(&1.duration / 1000.0)) |> Enum.sort()
      ns = length(streaming)
      ni = length(idle)
      sm = if ns > 0, do: f(pct(streaming, 0.5)), else: "-"
      sp = if ns > 0, do: f(pct(streaming, 0.99)), else: "-"
      im = if ni > 0, do: f(pct(idle, 0.5)), else: "-"
      ip = if ni > 0, do: f(pct(idle, 0.99)), else: "-"
      IO.puts("  msg_count=#{mc}: streaming(n=#{ns} med=#{sm} p99=#{sp})  idle(n=#{ni} med=#{im} p99=#{ip})")
    end)

    IO.puts("\n=== Headline numbers (the bar follow-ups must clear) ===")
    # Streaming-message handle_info p99
    agent_durations =
      lines
      |> Enum.filter(&String.contains?(&1, "interactive.handle_info.stop"))
      |> Enum.map(&parse/1)
      |> Enum.filter(&(&1.kind == "octo_pi_agent_event"))
      |> Enum.map(&(&1.duration / 1000.0))
      |> Enum.sort()

    IO.puts("  octo_pi_agent_event handle_info: p50=#{f(pct(agent_durations, 0.5))} p99=#{f(pct(agent_durations, 0.99))} max=#{f(List.last(agent_durations))}")

    key_durs = Enum.map(keys, &(&1.duration_us / 1000.0)) |> Enum.sort()
    IO.puts("  key.latency overall: p50=#{f(pct(key_durs, 0.5))} p99=#{f(pct(key_durs, 0.99))} max=#{f(List.last(key_durs))}")

    streaming_md = Enum.filter(markdown, & &1.streaming) |> Enum.sort_by(& &1.text_bytes)
    if streaming_md != [] do
      max_bytes = (streaming_md |> List.last()).text_bytes
      max_bytes_evs = Enum.filter(streaming_md, &(&1.text_bytes >= max_bytes * 0.9))
      ds = Enum.map(max_bytes_evs, &(&1.duration / 1000.0)) |> Enum.sort()
      IO.puts("  markdown.render at max text_bytes (~#{max_bytes}): p99=#{f(pct(ds, 0.99))} (n=#{length(ds)})")
    end

    transcript_max = Enum.max_by(transcript, & &1.msg_count)
    max_msg = transcript_max.msg_count
    max_evs = Enum.filter(transcript, &(&1.msg_count == max_msg)) |> Enum.map(&(&1.duration / 1000.0)) |> Enum.sort()
    IO.puts("  transcript.render at msg_count=#{max_msg}: p99=#{f(pct(max_evs, 0.99))} (n=#{length(max_evs)})")
  end

  defp parse(line) do
    %{
      kind: extract(line, ~r/kind=(\w+)/),
      duration: parse_int(extract(line, ~r/duration=(\d+)/)),
      duration_us: parse_int(extract(line, ~r/duration_us=(\d+)/)),
      text_bytes: parse_int(extract(line, ~r/text_bytes=(\d+)/)),
      mailbox_len: parse_int(extract(line, ~r/mailbox_len_at_arrival=(\d+)/)),
      msg_count: parse_int(extract(line, ~r/msg_count=(\d+)/)),
      streaming: extract(line, ~r/streaming\?=(\w+)/) == "true",
      line_count: parse_int(extract(line, ~r/line_count=(\d+)/))
    }
  end

  defp extract(line, re) do
    case Regex.run(re, line) do
      [_, val] -> val
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(s), do: String.to_integer(s)

  defp pct(sorted, p) when sorted == [], do: 0.0
  defp pct(sorted, p) do
    idx = max(0, min(length(sorted) - 1, round(p * length(sorted))))
    Enum.at(sorted, idx)
  end

  defp f(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp f(v) when is_integer(v), do: Integer.to_string(v)
  defp f(_), do: "-"

  defp bin_by_text_bytes(events) do
    bins = [
      {"0-256", 0, 256},
      {"256-1024", 256, 1024},
      {"1024-4096", 1024, 4096},
      {"4096-8192", 4096, 8192},
      {"8192+", 8192, 1_000_000}
    ]

    Enum.map(bins, fn {label, lo, hi} ->
      evs = Enum.filter(events, fn e -> e.text_bytes && e.text_bytes >= lo && e.text_bytes < hi end)
      {label, evs}
    end)
  end
end

Spike.main()
