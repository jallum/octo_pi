defmodule OctoPi.TUI.Theme do
  @moduledoc false

  import Bitwise

  @type color_mode :: :truecolor | :"256color"

  @type color_key ::
          :accent
          | :border
          | :border_accent
          | :border_muted
          | :success
          | :error
          | :warning
          | :muted
          | :dim
          | :text
          | :thinking_text
          | :user_message_text
          | :custom_message_text
          | :custom_message_label
          | :tool_title
          | :tool_output
          | :md_heading
          | :md_link
          | :md_link_url
          | :md_code
          | :md_code_block
          | :md_code_block_border
          | :md_quote
          | :md_quote_border
          | :md_hr
          | :md_list_bullet
          | :tool_diff_added
          | :tool_diff_removed
          | :tool_diff_context
          | :syntax_comment
          | :syntax_keyword
          | :syntax_function
          | :syntax_variable
          | :syntax_string
          | :syntax_number
          | :syntax_type
          | :syntax_operator
          | :syntax_punctuation
          | :thinking_off
          | :thinking_minimal
          | :thinking_low
          | :thinking_medium
          | :thinking_high
          | :thinking_xhigh
          | :bash_mode

  @type bg_key ::
          :selected_bg
          | :user_message_bg
          | :custom_message_bg
          | :tool_pending_bg
          | :tool_success_bg
          | :tool_error_bg

  @type t :: %__MODULE__{
          name: String.t(),
          mode: color_mode(),
          fg_colors: %{color_key() => String.t()},
          bg_colors: %{bg_key() => String.t()}
        }

  defstruct [:name, :mode, fg_colors: %{}, bg_colors: %{}]

  @color_keys [
    :accent,
    :border,
    :border_accent,
    :border_muted,
    :success,
    :error,
    :warning,
    :muted,
    :dim,
    :text,
    :thinking_text,
    :user_message_text,
    :custom_message_text,
    :custom_message_label,
    :tool_title,
    :tool_output,
    :md_heading,
    :md_link,
    :md_link_url,
    :md_code,
    :md_code_block,
    :md_code_block_border,
    :md_quote,
    :md_quote_border,
    :md_hr,
    :md_list_bullet,
    :tool_diff_added,
    :tool_diff_removed,
    :tool_diff_context,
    :syntax_comment,
    :syntax_keyword,
    :syntax_function,
    :syntax_variable,
    :syntax_string,
    :syntax_number,
    :syntax_type,
    :syntax_operator,
    :syntax_punctuation,
    :thinking_off,
    :thinking_minimal,
    :thinking_low,
    :thinking_medium,
    :thinking_high,
    :thinking_xhigh,
    :bash_mode
  ]

  @bg_keys [
    :selected_bg,
    :user_message_bg,
    :custom_message_bg,
    :tool_pending_bg,
    :tool_success_bg,
    :tool_error_bg
  ]

  @key_to_json Map.new(
                 [
                   {:border_accent, "borderAccent"},
                   {:border_muted, "borderMuted"},
                   {:thinking_text, "thinkingText"},
                   {:selected_bg, "selectedBg"},
                   {:user_message_bg, "userMessageBg"},
                   {:user_message_text, "userMessageText"},
                   {:custom_message_bg, "customMessageBg"},
                   {:custom_message_text, "customMessageText"},
                   {:custom_message_label, "customMessageLabel"},
                   {:tool_pending_bg, "toolPendingBg"},
                   {:tool_success_bg, "toolSuccessBg"},
                   {:tool_error_bg, "toolErrorBg"},
                   {:tool_title, "toolTitle"},
                   {:tool_output, "toolOutput"},
                   {:md_heading, "mdHeading"},
                   {:md_link, "mdLink"},
                   {:md_link_url, "mdLinkUrl"},
                   {:md_code, "mdCode"},
                   {:md_code_block, "mdCodeBlock"},
                   {:md_code_block_border, "mdCodeBlockBorder"},
                   {:md_quote, "mdQuote"},
                   {:md_quote_border, "mdQuoteBorder"},
                   {:md_hr, "mdHr"},
                   {:md_list_bullet, "mdListBullet"},
                   {:tool_diff_added, "toolDiffAdded"},
                   {:tool_diff_removed, "toolDiffRemoved"},
                   {:tool_diff_context, "toolDiffContext"},
                   {:syntax_comment, "syntaxComment"},
                   {:syntax_keyword, "syntaxKeyword"},
                   {:syntax_function, "syntaxFunction"},
                   {:syntax_variable, "syntaxVariable"},
                   {:syntax_string, "syntaxString"},
                   {:syntax_number, "syntaxNumber"},
                   {:syntax_type, "syntaxType"},
                   {:syntax_operator, "syntaxOperator"},
                   {:syntax_punctuation, "syntaxPunctuation"},
                   {:thinking_off, "thinkingOff"},
                   {:thinking_minimal, "thinkingMinimal"},
                   {:thinking_low, "thinkingLow"},
                   {:thinking_medium, "thinkingMedium"},
                   {:thinking_high, "thinkingHigh"},
                   {:thinking_xhigh, "thinkingXhigh"},
                   {:bash_mode, "bashMode"}
                 ],
                 fn {k, v} -> {k, v} end
               )

  @json_to_key Map.new(@key_to_json, fn {k, v} -> {v, k} end)

  # Simple keys where atom == JSON key
  @simple_keys [:accent, :border, :success, :error, :warning, :muted, :dim, :text]
  @simple_map Map.new(@simple_keys, fn k -> {Atom.to_string(k), k} end)
  @json_to_key Map.merge(@json_to_key, @simple_map)
  @key_to_json Map.merge(@key_to_json, Map.new(@simple_keys, fn k -> {k, Atom.to_string(k)} end))

  # ── Public API ──────────────────────────────────────────────────

  @spec color_keys() :: [color_key()]
  def color_keys, do: @color_keys

  @spec bg_keys() :: [bg_key()]
  def bg_keys, do: @bg_keys

  @spec color_key_to_json(color_key() | bg_key()) :: String.t()
  def color_key_to_json(key), do: Map.fetch!(@key_to_json, key)

  @spec from_json(map(), color_mode()) :: t()
  def from_json(%{"name" => name, "colors" => colors} = json, mode) do
    vars = Map.get(json, "vars", %{})
    resolved = resolve_all_colors(colors, vars)

    {fg, bg} =
      Enum.reduce(resolved, {%{}, %{}}, fn {json_key, value}, acc ->
        case Map.get(@json_to_key, json_key) do
          nil -> acc
          atom_key -> classify_color(atom_key, value, mode, acc)
        end
      end)

    %__MODULE__{name: name, mode: mode, fg_colors: fg, bg_colors: bg}
  end

  @spec load_builtin(:dark | :light, color_mode()) :: t()
  def load_builtin(name, mode) when name in [:dark, :light] do
    path = Path.join(:code.priv_dir(:octo_pi_tui), "themes/#{name}.json")
    json = Jason.decode!(File.read!(path))
    from_json(json, mode)
  end

  def load_builtin(name, _mode) do
    raise ArgumentError, "unknown built-in theme: #{inspect(name)}"
  end

  @spec available_themes() :: [String.t()]
  def available_themes do
    dir = Path.join(:code.priv_dir(:octo_pi_tui), "themes")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&String.trim_trailing(&1, ".json"))
    |> Enum.sort()
  end

  @spec detect_color_mode() :: color_mode()
  def detect_color_mode do
    colorterm = System.get_env("COLORTERM", "")

    cond do
      colorterm in ["truecolor", "24bit"] -> :truecolor
      apple_terminal?() -> :"256color"
      dumb_term?() -> :"256color"
      screen_term?() -> :"256color"
      true -> :truecolor
    end
  end

  # ── Fluent coloring API ─────────────────────────────────────────

  @spec fg(t(), color_key(), String.t()) :: String.t()
  def fg(%__MODULE__{fg_colors: fg}, key, text) do
    case Map.fetch(fg, key) do
      {:ok, ansi} -> "#{ansi}#{text}\e[39m"
      :error -> raise ArgumentError, "unknown theme color: #{inspect(key)}"
    end
  end

  @spec bg(t(), bg_key(), String.t()) :: String.t()
  def bg(%__MODULE__{bg_colors: bg}, key, text) do
    case Map.fetch(bg, key) do
      {:ok, ansi} -> "#{ansi}#{text}\e[49m"
      :error -> raise ArgumentError, "unknown theme background color: #{inspect(key)}"
    end
  end

  @spec get_fg_ansi(t(), color_key()) :: String.t()
  def get_fg_ansi(%__MODULE__{fg_colors: fg}, key) do
    case Map.fetch(fg, key) do
      {:ok, ansi} -> ansi
      :error -> raise ArgumentError, "unknown theme color: #{inspect(key)}"
    end
  end

  @spec get_bg_ansi(t(), bg_key()) :: String.t()
  def get_bg_ansi(%__MODULE__{bg_colors: bg}, key) do
    case Map.fetch(bg, key) do
      {:ok, ansi} -> ansi
      :error -> raise ArgumentError, "unknown theme background color: #{inspect(key)}"
    end
  end

  @spec bold(String.t()) :: String.t()
  def bold(text), do: "\e[1m#{text}\e[22m"

  @spec italic(String.t()) :: String.t()
  def italic(text), do: "\e[3m#{text}\e[23m"

  @spec underline(String.t()) :: String.t()
  def underline(text), do: "\e[4m#{text}\e[24m"

  @spec inverse(String.t()) :: String.t()
  def inverse(text), do: "\e[7m#{text}\e[27m"

  @spec strikethrough(String.t()) :: String.t()
  def strikethrough(text), do: "\e[9m#{text}\e[29m"

  # ── Color utilities (public for testing) ────────────────────────

  @spec hex_to_rgb(String.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def hex_to_rgb(hex) do
    cleaned = String.trim_leading(hex, "#")

    if byte_size(cleaned) != 6,
      do: raise(ArgumentError, "invalid hex color: #{hex}")

    case Integer.parse(cleaned, 16) do
      {n, ""} ->
        {n >>> 16 &&& 0xFF, n >>> 8 &&& 0xFF, n &&& 0xFF}

      _ ->
        raise ArgumentError, "invalid hex color: #{hex}"
    end
  end

  @cube_values [0, 95, 135, 175, 215, 255]
  @gray_values Enum.map(0..23, fn i -> 8 + i * 10 end)

  @spec rgb_to_256(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: 0..255
  def rgb_to_256(r, g, b) do
    ri = closest_cube_index(r)
    gi = closest_cube_index(g)
    bi = closest_cube_index(b)
    cube_r = Enum.at(@cube_values, ri)
    cube_g = Enum.at(@cube_values, gi)
    cube_b = Enum.at(@cube_values, bi)
    cube_index = 16 + 36 * ri + 6 * gi + bi
    cube_dist = color_distance(r, g, b, cube_r, cube_g, cube_b)

    gray = round(0.299 * r + 0.587 * g + 0.114 * b)
    gray_idx = closest_gray_index(gray)
    gray_val = Enum.at(@gray_values, gray_idx)
    gray_index = 232 + gray_idx
    gray_dist = color_distance(r, g, b, gray_val, gray_val, gray_val)

    spread = Enum.max([r, g, b]) - Enum.min([r, g, b])

    if spread < 10 and gray_dist < cube_dist do
      gray_index
    else
      cube_index
    end
  end

  @spec fg_ansi(String.t() | integer(), color_mode()) :: String.t()
  def fg_ansi("", _mode), do: "\e[39m"
  def fg_ansi(idx, _mode) when is_integer(idx), do: "\e[38;5;#{idx}m"

  def fg_ansi("#" <> _ = hex, :truecolor) do
    {r, g, b} = hex_to_rgb(hex)
    "\e[38;2;#{r};#{g};#{b}m"
  end

  def fg_ansi("#" <> _ = hex, :"256color") do
    {r, g, b} = hex_to_rgb(hex)
    "\e[38;5;#{rgb_to_256(r, g, b)}m"
  end

  @spec bg_ansi(String.t() | integer(), color_mode()) :: String.t()
  def bg_ansi("", _mode), do: "\e[49m"
  def bg_ansi(idx, _mode) when is_integer(idx), do: "\e[48;5;#{idx}m"

  def bg_ansi("#" <> _ = hex, :truecolor) do
    {r, g, b} = hex_to_rgb(hex)
    "\e[48;2;#{r};#{g};#{b}m"
  end

  def bg_ansi("#" <> _ = hex, :"256color") do
    {r, g, b} = hex_to_rgb(hex)
    "\e[48;5;#{rgb_to_256(r, g, b)}m"
  end

  @spec resolve_color(String.t() | integer(), map()) :: String.t() | integer()
  def resolve_color(value, _vars) when is_integer(value), do: value
  def resolve_color("", _vars), do: ""
  def resolve_color("#" <> _ = hex, _vars), do: hex

  def resolve_color(ref, vars) do
    do_resolve(ref, vars, %{})
  end

  # ── Private ─────────────────────────────────────────────────────

  @bg_key_set MapSet.new(@bg_keys)

  defp classify_color(key, value, mode, {fg_acc, bg_acc}) do
    if MapSet.member?(@bg_key_set, key) do
      {fg_acc, Map.put(bg_acc, key, bg_ansi(value, mode))}
    else
      {Map.put(fg_acc, key, fg_ansi(value, mode)), bg_acc}
    end
  end

  defp do_resolve(value, _vars, _visited) when is_integer(value), do: value
  defp do_resolve("", _vars, _visited), do: ""
  defp do_resolve("#" <> _ = hex, _vars, _visited), do: hex

  defp do_resolve(ref, vars, visited) do
    if Map.has_key?(visited, ref),
      do: raise(ArgumentError, "circular variable reference: #{ref}")

    case Map.fetch(vars, ref) do
      {:ok, value} -> do_resolve(value, vars, Map.put(visited, ref, true))
      :error -> raise ArgumentError, "variable reference not found: #{ref}"
    end
  end

  defp resolve_all_colors(colors, vars) do
    Map.new(colors, fn {key, value} -> {key, resolve_color(value, vars)} end)
  end

  defp closest_cube_index(value) do
    @cube_values
    |> Enum.with_index()
    |> Enum.min_by(fn {v, _i} -> abs(value - v) end)
    |> elem(1)
  end

  defp closest_gray_index(gray) do
    @gray_values
    |> Enum.with_index()
    |> Enum.min_by(fn {v, _i} -> abs(gray - v) end)
    |> elem(1)
  end

  defp color_distance(r1, g1, b1, r2, g2, b2) do
    dr = r1 - r2
    dg = g1 - g2
    db = b1 - b2
    dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114
  end

  defp apple_terminal? do
    System.get_env("TERM_PROGRAM") == "Apple_Terminal"
  end

  defp dumb_term? do
    term = System.get_env("TERM", "")
    term in ["dumb", "", "linux"]
  end

  defp screen_term? do
    term = System.get_env("TERM", "")

    term == "screen" or String.starts_with?(term, "screen-") or
      String.starts_with?(term, "screen.")
  end
end
