defmodule OctoPi.TUI.TerminalImage do
  @moduledoc """
  Terminal image protocol helpers: Kitty/iTerm2 encoding, capability
  detection, OSC 8 hyperlinks, and `image_line?/1` detection.

  ## Divergence from upstream: no startup cell-size query

  Upstream pi-mono's TUI emits `\\e[16t` at startup on image-capable
  terminals and parses the `\\e[6;H;Wt` reply into cached pixel
  dimensions used to size images in rows. We deliberately decline
  that mechanism:

  * Our image rendering path is not wired through an interactive TUI
    with a startup handshake — images appear via `encode_kitty/2` /
    `encode_iterm2/2` called from tool renderers.
  * `calculate_image_rows/3` accepts `cell_dims` as a pure-function
    parameter defaulting to `%{width_px: 9, height_px: 18}`. Callers
    that need real dimensions pass them explicitly.
  * Consuming the reply requires a stdin parser that recognises
    `\\e[6;H;Wt`, caches state, and does not forward the reply to
    focused components. That belongs to a TUI runtime we have not
    built; paying the complexity without the runtime is premature.

  Upstream's tui-cell-size-input.test.ts (audit opi-q5k.20) asserts
  two behaviours of that runtime. Both are N/A for us by this
  decision; no Elixir tests are ported.
  """

  @kitty_prefix "\e_G"
  @iterm2_prefix "\e]1337;File="
  @chunk_size 4096

  @type image_protocol :: :kitty | :iterm2 | nil
  @type capabilities :: %{images: image_protocol(), true_color: boolean(), hyperlinks: boolean()}
  @type dimensions :: %{width: non_neg_integer(), height: non_neg_integer()}
  @type cell_dims :: %{width_px: non_neg_integer(), height_px: non_neg_integer()}

  @default_cell_dims %{width_px: 9, height_px: 18}

  @spec detect_capabilities() :: capabilities()
  def detect_capabilities do
    term_program = System.get_env("TERM_PROGRAM", "") |> String.downcase()
    term = System.get_env("TERM", "") |> String.downcase()
    color_term = System.get_env("COLORTERM", "") |> String.downcase()

    cond do
      in_tmux_or_screen?(term) ->
        true_color = color_term in ["truecolor", "24bit"]
        %{images: nil, true_color: true_color, hyperlinks: false}

      kitty_terminal?(term_program) ->
        %{images: :kitty, true_color: true, hyperlinks: true}

      ghostty_terminal?(term_program, term) ->
        %{images: :kitty, true_color: true, hyperlinks: true}

      wezterm_terminal?(term_program) ->
        %{images: :kitty, true_color: true, hyperlinks: true}

      iterm2_terminal?(term_program) ->
        %{images: :iterm2, true_color: true, hyperlinks: true}

      term_program in ["vscode", "alacritty"] ->
        %{images: nil, true_color: true, hyperlinks: true}

      true ->
        true_color = color_term in ["truecolor", "24bit"]
        %{images: nil, true_color: true_color, hyperlinks: false}
    end
  end

  @spec encode_kitty(String.t(), keyword()) :: String.t()
  def encode_kitty(base64_data, opts \\ []) do
    params = build_kitty_params(opts)

    if byte_size(base64_data) <= @chunk_size do
      "\e_G#{params};#{base64_data}\e\\"
    else
      encode_kitty_chunked(base64_data, params)
    end
  end

  @spec encode_iterm2(String.t(), keyword()) :: String.t()
  def encode_iterm2(base64_data, opts \\ []) do
    params = build_iterm2_params(opts)
    "\e]1337;File=#{params}:#{base64_data}\a"
  end

  @spec get_png_dimensions(String.t()) :: {:ok, dimensions()} | :error
  def get_png_dimensions(base64_data) do
    case Base.decode64(base64_data) do
      {:ok,
       <<0x89, 0x50, 0x4E, 0x47, _::binary-size(8), _ihdr::binary-size(4), w::32, h::32,
         _::binary>>} ->
        {:ok, %{width: w, height: h}}

      _ ->
        :error
    end
  end

  @spec calculate_image_rows(dimensions(), pos_integer(), cell_dims()) :: pos_integer()
  def calculate_image_rows(image_dims, target_width_cells, cell_dims \\ @default_cell_dims) do
    target_width_px = target_width_cells * cell_dims.width_px
    scale = target_width_px / image_dims.width
    scaled_height_px = image_dims.height * scale
    max(1, ceil(scaled_height_px / cell_dims.height_px))
  end

  @spec image_fallback(String.t(), keyword()) :: String.t()
  def image_fallback(mime_type, opts \\ []) do
    parts =
      []
      |> maybe_add(Keyword.get(opts, :filename))
      |> Kernel.++(["[#{mime_type}]"])
      |> maybe_add_dims(Keyword.get(opts, :dimensions))

    "[Image: #{Enum.join(parts, " ")}]"
  end

  @spec image_line?(String.t()) :: boolean()
  def image_line?(line) do
    String.contains?(line, @kitty_prefix) or String.contains?(line, @iterm2_prefix)
  end

  @spec hyperlink(String.t(), String.t()) :: String.t()
  def hyperlink(text, url) do
    "\e]8;;#{url}\e\\#{text}\e]8;;\e\\"
  end

  # --- private ---

  defp in_tmux_or_screen?(term) do
    System.get_env("TMUX") != nil or
      String.starts_with?(term, "tmux") or
      String.starts_with?(term, "screen")
  end

  defp kitty_terminal?(term_program) do
    System.get_env("KITTY_WINDOW_ID") != nil or term_program == "kitty"
  end

  defp ghostty_terminal?(term_program, term) do
    term_program == "ghostty" or String.contains?(term, "ghostty") or
      System.get_env("GHOSTTY_RESOURCES_DIR") != nil
  end

  defp wezterm_terminal?(term_program) do
    System.get_env("WEZTERM_PANE") != nil or term_program == "wezterm"
  end

  defp iterm2_terminal?(term_program) do
    System.get_env("ITERM_SESSION_ID") != nil or term_program == "iterm.app"
  end

  defp build_kitty_params(opts) do
    base = "a=T,f=100,q=2"

    base
    |> maybe_param("c", Keyword.get(opts, :columns))
    |> maybe_param("r", Keyword.get(opts, :rows))
    |> maybe_param("i", Keyword.get(opts, :image_id))
  end

  defp maybe_param(params, _key, nil), do: params
  defp maybe_param(params, key, value), do: "#{params},#{key}=#{value}"

  defp encode_kitty_chunked(data, params) do
    chunks = chunk_base64(data)
    encode_chunks(chunks, params, [])
  end

  defp chunk_base64(data) do
    if byte_size(data) <= @chunk_size do
      [data]
    else
      chunk = binary_part(data, 0, @chunk_size)
      rest = binary_part(data, @chunk_size, byte_size(data) - @chunk_size)
      [chunk | chunk_base64(rest)]
    end
  end

  defp encode_chunks([chunk], _params, acc) do
    Enum.join(Enum.reverse(["\e_Gm=0;#{chunk}\e\\" | acc]))
  end

  defp encode_chunks([chunk | rest], params, []) do
    encode_chunks(rest, params, ["\e_G#{params},m=1;#{chunk}\e\\"])
  end

  defp encode_chunks([chunk | rest], params, acc) do
    encode_chunks(rest, params, ["\e_Gm=1;#{chunk}\e\\" | acc])
  end

  defp build_iterm2_params(opts) do
    parts = ["inline=1"]
    parts = if w = Keyword.get(opts, :width), do: parts ++ ["width=#{w}"], else: parts
    parts = if h = Keyword.get(opts, :height), do: parts ++ ["height=#{h}"], else: parts

    if Keyword.get(opts, :preserve_aspect_ratio) == false do
      Enum.join(parts ++ ["preserveAspectRatio=0"], ";")
    else
      Enum.join(parts, ";")
    end
  end

  defp maybe_add(parts, nil), do: parts
  defp maybe_add(parts, name), do: parts ++ [name]

  defp maybe_add_dims(parts, nil), do: parts
  defp maybe_add_dims(parts, %{width: w, height: h}), do: parts ++ ["#{w}x#{h}"]
end
