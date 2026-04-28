defmodule OctoPi.TUI.Terminal.Image do
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

  import Bitwise

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
    term_program = "TERM_PROGRAM" |> System.get_env("") |> String.downcase()
    term = "TERM" |> System.get_env("") |> String.downcase()
    color_term = "COLORTERM" |> System.get_env("") |> String.downcase()

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

  @spec get_image_dimensions(String.t(), String.t()) :: {:ok, dimensions()} | :error
  def get_image_dimensions(base64_data, mime_type) do
    case mime_type do
      "image/png" -> get_png_dimensions(base64_data)
      "image/jpeg" -> get_jpeg_dimensions(base64_data)
      "image/gif" -> get_gif_dimensions(base64_data)
      "image/webp" -> get_webp_dimensions(base64_data)
      _ -> :error
    end
  end

  @spec get_png_dimensions(String.t()) :: {:ok, dimensions()} | :error
  def get_png_dimensions(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, <<0x89, 0x50, 0x4E, 0x47, _::binary-size(8), _ihdr::binary-size(4), w::32, h::32, _::binary>>} ->
        {:ok, %{width: w, height: h}}

      _ ->
        :error
    end
  end

  @spec get_jpeg_dimensions(String.t()) :: {:ok, dimensions()} | :error
  def get_jpeg_dimensions(base64_data) do
    with {:ok, data} <- Base.decode64(base64_data),
         {:ok, h, w} <- parse_jpeg_sof(data, 2) do
      {:ok, %{width: w, height: h}}
    else
      _ -> :error
    end
  end

  @spec get_gif_dimensions(String.t()) :: {:ok, dimensions()} | :error
  def get_gif_dimensions(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, <<"GIF", _ver::binary-size(3), width::little-16, height::little-16, _::binary>>} ->
        {:ok, %{width: width, height: height}}

      _ ->
        :error
    end
  end

  @spec get_webp_dimensions(String.t()) :: {:ok, dimensions()} | :error
  def get_webp_dimensions(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, <<"RIFF", _size::32, "WEBP", chunk_type::binary-size(4), _::binary>> = data} ->
        parse_webp_chunk(data, chunk_type)

      _ ->
        :error
    end
  end

  @spec render_image(String.t(), dimensions(), keyword()) ::
          {:ok, String.t(), pos_integer()} | {:fallback, String.t()}
  def render_image(base64_data, image_dims, opts \\ []) do
    target_width = Keyword.get(opts, :width, 80)
    cell_dims = Keyword.get(opts, :cell_dims, @default_cell_dims)
    rows = calculate_image_rows(image_dims, target_width, cell_dims)

    case detect_capabilities() do
      %{images: :kitty} -> {:ok, encode_kitty(base64_data, Keyword.put(opts, :rows, rows)), rows}
      %{images: :iterm2} -> {:ok, encode_iterm2(base64_data, Keyword.put(opts, :rows, rows)), rows}
      %{images: nil} -> {:fallback, image_fallback(Keyword.get(opts, :mime_type, "image"), opts)}
    end
  end

  @spec delete_kitty_image(pos_integer()) :: String.t()
  def delete_kitty_image(image_id), do: "\e_Ga=d,d=I,i=#{image_id}\e\\"

  @spec delete_all_kitty_images() :: String.t()
  def delete_all_kitty_images, do: "\e_Ga=d\e\\"

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

  defp parse_jpeg_sof(data, i) do
    data_len = byte_size(data)

    if i + 3 >= data_len do
      :error
    else
      marker = :binary.at(data, i)
      type = :binary.at(data, i + 1)

      cond do
        marker != 0xFF ->
          :error

        type in [0xC0, 0xC2] and i + 8 < data_len ->
          h = :binary.decode_unsigned(binary_part(data, i + 5, 2), :big)
          w = :binary.decode_unsigned(binary_part(data, i + 7, 2), :big)
          {:ok, h, w}

        i + 3 < data_len ->
          length = :binary.decode_unsigned(binary_part(data, i + 2, 2), :big)
          parse_jpeg_sof(data, i + 2 + length)

        true ->
          :error
      end
    end
  end

  defp parse_webp_chunk(data, "VP8 ") do
    case data do
      <<_::binary-size(23), 0x9D, 0x01, 0x2A, w_bits::little-16, h_bits::little-16, _::binary>> ->
        {:ok, %{width: w_bits &&& 0x3FFF, height: h_bits &&& 0x3FFF}}

      _ ->
        :error
    end
  end

  defp parse_webp_chunk(data, "VP8L") do
    case data do
      <<_::binary-size(21), b0, b1, b2, b3, _::binary>> ->
        bits = b0 ||| b1 <<< 8 ||| b2 <<< 16 ||| b3 <<< 24
        {:ok, %{width: (bits &&& 0x3FFF) + 1, height: (bits >>> 14 &&& 0x3FFF) + 1}}

      _ ->
        :error
    end
  end

  defp parse_webp_chunk(_data, _type), do: :error

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
