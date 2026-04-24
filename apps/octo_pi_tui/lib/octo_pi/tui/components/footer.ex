defmodule OctoPi.TUI.Components.Footer do
  @moduledoc """
  Footer status bar: pwd/branch, token stats, and model name.
  Renders 2-3 lines anchored to the bottom of the terminal.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          cwd: String.t(),
          git_branch: String.t() | nil,
          session_name: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: float(),
          context_percent: float() | nil,
          context_window: non_neg_integer(),
          model_id: String.t(),
          thinking_level: String.t() | nil,
          extension_statuses: %{String.t() => String.t()}
        }

  defstruct cwd: ".",
            git_branch: nil,
            session_name: nil,
            input_tokens: 0,
            output_tokens: 0,
            cache_read: 0,
            cache_write: 0,
            cost: 0.0,
            context_percent: nil,
            context_window: 0,
            model_id: "no-model",
            thinking_level: nil,
            extension_statuses: %{}

  @impl true
  def render(%__MODULE__{} = f, width) do
    pwd_line = build_pwd_line(f, width)
    stats_line = build_stats_line(f, width)
    lines = [pwd_line, stats_line]

    case build_extension_line(f, width) do
      nil -> lines
      ext -> lines ++ [ext]
    end
  end

  @impl true
  def handle_key(s, _key), do: s

  # --- line builders ---

  defp build_pwd_line(f, width) do
    pwd = shorten_home(f.cwd)
    pwd = if f.git_branch, do: "#{pwd} (#{f.git_branch})", else: pwd
    pwd = if f.session_name, do: "#{pwd} · #{f.session_name}", else: pwd
    truncate_dim(pwd, width)
  end

  defp build_stats_line(f, width) do
    left_parts = token_parts(f) ++ [context_part(f)]
    left = Enum.join(left_parts, " ")
    right = model_part(f)

    left_w = WrapAnsi.visible_width(left)
    right_w = WrapAnsi.visible_width(right)

    cond do
      left_w + 2 + right_w <= width ->
        padding = String.duplicate(" ", width - left_w - right_w)
        dim(left) <> dim(padding) <> dim(right)

      left_w + 2 <= width ->
        avail = width - left_w - 2
        trunc_right = String.slice(right, 0, avail)
        padding = String.duplicate(" ", max(0, width - left_w - String.length(trunc_right)))
        dim(left) <> dim(padding) <> dim(trunc_right)

      true ->
        dim(left)
    end
  end

  defp build_extension_line(%{extension_statuses: ext}, _width) when map_size(ext) == 0, do: nil

  defp build_extension_line(%{extension_statuses: ext}, width) do
    line =
      ext
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, v} -> sanitize_status(v) end)
      |> Enum.join(" ")

    truncate_dim(line, width)
  end

  # --- token formatting ---

  defp token_parts(f) do
    parts = []
    parts = if f.input_tokens > 0, do: parts ++ ["↑#{format_tokens(f.input_tokens)}"], else: parts

    parts =
      if f.output_tokens > 0, do: parts ++ ["↓#{format_tokens(f.output_tokens)}"], else: parts

    parts = if f.cache_read > 0, do: parts ++ ["R#{format_tokens(f.cache_read)}"], else: parts
    parts = if f.cache_write > 0, do: parts ++ ["W#{format_tokens(f.cache_write)}"], else: parts

    parts =
      if f.cost > 0,
        do: parts ++ ["$#{:erlang.float_to_binary(f.cost, decimals: 3)}"],
        else: parts

    parts
  end

  @doc false
  def format_tokens(n) when n < 1_000, do: Integer.to_string(n)
  def format_tokens(n) when n < 10_000, do: "#{Float.round(n / 1_000, 1)}k"
  def format_tokens(n) when n < 1_000_000, do: "#{round(n / 1_000)}k"
  def format_tokens(n) when n < 10_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_tokens(n), do: "#{round(n / 1_000_000)}M"

  defp context_part(f) do
    pct_display =
      case f.context_percent do
        nil -> "?"
        p -> "#{Float.round(p, 1)}"
      end

    window_display = format_tokens(f.context_window)
    text = "#{pct_display}%/#{window_display}"

    case f.context_percent do
      p when is_float(p) and p > 90 -> "\e[31m#{text}\e[39m"
      p when is_float(p) and p > 70 -> "\e[33m#{text}\e[39m"
      _ -> text
    end
  end

  defp model_part(f) do
    case f.thinking_level do
      nil -> f.model_id
      level -> "#{f.model_id} · #{level}"
    end
  end

  # --- helpers ---

  defp shorten_home(cwd) do
    home = System.get_env("HOME") || ""

    if home != "" and String.starts_with?(cwd, home) do
      "~" <> String.slice(cwd, String.length(home)..-1//1)
    else
      cwd
    end
  end

  defp sanitize_status(text) do
    text
    |> String.replace(~r/[\r\n\t]/, " ")
    |> String.replace(~r/ +/, " ")
    |> String.trim()
  end

  defp truncate_dim(text, width) do
    if WrapAnsi.visible_width(text) > width do
      dim(String.slice(text, 0, width - 3) <> "...")
    else
      dim(text)
    end
  end

  defp dim(text), do: "\e[2m#{text}\e[22m"
end
