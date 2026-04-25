defmodule OctoPi.TUI.RenderThrottle do
  @moduledoc false

  @default_interval_ms 16

  defstruct min_interval_ms: @default_interval_ms,
            render_count: 0,
            skip_count: 0,
            last_render_at: nil

  @type t :: %__MODULE__{
          min_interval_ms: non_neg_integer(),
          render_count: non_neg_integer(),
          skip_count: non_neg_integer(),
          last_render_at: integer() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      min_interval_ms: Keyword.get(opts, :min_interval_ms, @default_interval_ms)
    }
  end

  @spec should_render?(t()) :: {boolean(), t()}
  def should_render?(%__MODULE__{last_render_at: nil} = t), do: {true, t}

  def should_render?(%__MODULE__{} = t) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - t.last_render_at

    if elapsed >= t.min_interval_ms do
      {true, t}
    else
      {false, %{t | skip_count: t.skip_count + 1}}
    end
  end

  @spec record_render(t()) :: t()
  def record_render(%__MODULE__{} = t) do
    %{t | render_count: t.render_count + 1, last_render_at: System.monotonic_time(:millisecond)}
  end

  @spec metrics(t()) :: %{render_count: non_neg_integer(), skip_count: non_neg_integer()}
  def metrics(%__MODULE__{render_count: rc, skip_count: sc}) do
    %{render_count: rc, skip_count: sc}
  end

  @spec check_width_overflow([binary()], pos_integer()) ::
          :ok | {:overflow, [{non_neg_integer(), non_neg_integer()}]}
  def check_width_overflow(lines, width) do
    overflows =
      lines
      |> Enum.with_index()
      |> Enum.reduce([], fn {line, idx}, acc ->
        visible_len = line |> strip_ansi() |> String.length()

        if visible_len > width do
          [{idx, visible_len} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    case overflows do
      [] -> :ok
      list -> {:overflow, list}
    end
  end

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")
end
