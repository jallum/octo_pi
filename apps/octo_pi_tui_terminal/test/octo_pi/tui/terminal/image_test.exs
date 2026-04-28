defmodule OctoPi.TUI.Terminal.ImageTest do
  # async: false — tests mutate TERM_* env vars around detect_capabilities
  use ExUnit.Case, async: false

  alias OctoPi.TUI.Terminal.Image

  @env_keys ~w(TERM TERM_PROGRAM COLORTERM TMUX KITTY_WINDOW_ID GHOSTTY_RESOURCES_DIR WEZTERM_PANE ITERM_SESSION_ID)

  defp with_env(overrides, fun) do
    saved = Map.new(@env_keys, fn k -> {k, System.get_env(k)} end)

    # Clear every tracked key so leakage from outer env doesn't taint.
    for k <- @env_keys, do: System.delete_env(k)
    for {k, v} <- overrides, v != nil, do: System.put_env(k, v)

    try do
      fun.()
    after
      for k <- @env_keys do
        case saved[k] do
          nil -> System.delete_env(k)
          v -> System.put_env(k, v)
        end
      end
    end
  end

  describe "detect_capabilities/0" do
    test "returns a capabilities map" do
      caps = Image.detect_capabilities()
      assert is_map(caps)
      assert Map.has_key?(caps, :images)
      assert Map.has_key?(caps, :true_color)
      assert Map.has_key?(caps, :hyperlinks)
    end
  end

  describe "encode_kitty/2" do
    test "encodes short data in a single chunk" do
      data = Base.encode64("tiny")
      result = Image.encode_kitty(data)
      assert result =~ "\e_G"
      assert result =~ "a=T"
      assert result =~ "f=100"
      assert result =~ data
      assert String.ends_with?(result, "\e\\")
    end

    test "respects columns and rows options" do
      data = Base.encode64("x")
      result = Image.encode_kitty(data, columns: 40, rows: 10)
      assert result =~ "c=40"
      assert result =~ "r=10"
    end

    test "chunks large data" do
      data = Base.encode64(String.duplicate("x", 5000))
      result = Image.encode_kitty(data)
      assert result =~ "m=1"
      assert result =~ "m=0"
    end
  end

  describe "encode_iterm2/2" do
    test "encodes inline image" do
      data = Base.encode64("img")
      result = Image.encode_iterm2(data)
      assert result =~ "\e]1337;File="
      assert result =~ "inline=1"
      assert result =~ data
      assert String.ends_with?(result, "\a")
    end

    test "respects width option" do
      data = Base.encode64("img")
      result = Image.encode_iterm2(data, width: 60)
      assert result =~ "width=60"
    end
  end

  describe "get_png_dimensions/1" do
    test "extracts dimensions from valid PNG header" do
      header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
          0x00, 0x64, 0x00, 0x00, 0x00, 0x32>>

      data = Base.encode64(header)
      assert {:ok, %{width: 100, height: 50}} = Image.get_png_dimensions(data)
    end

    test "returns error for non-PNG data" do
      data = Base.encode64("not a png")
      assert :error = Image.get_png_dimensions(data)
    end
  end

  describe "calculate_image_rows/3" do
    test "calculates rows from image dimensions" do
      rows = Image.calculate_image_rows(%{width: 800, height: 600}, 40)
      assert is_integer(rows)
      assert rows >= 1
    end

    test "returns at least 1 row" do
      rows = Image.calculate_image_rows(%{width: 1, height: 1}, 80)
      assert rows >= 1
    end
  end

  describe "image_fallback/2" do
    test "returns placeholder text" do
      result = Image.image_fallback("image/png")
      assert result =~ "[Image:"
      assert result =~ "image/png"
    end

    test "includes dimensions when provided" do
      result = Image.image_fallback("image/png", dimensions: %{width: 100, height: 50})
      assert result =~ "100x50"
    end

    test "includes filename when provided" do
      result = Image.image_fallback("image/png", filename: "photo.png")
      assert result =~ "photo.png"
    end
  end

  describe "image_line?/1" do
    test "detects Kitty image lines" do
      assert Image.image_line?("\e_Ga=T;data\e\\")
    end

    test "detects iTerm2 image lines" do
      assert Image.image_line?("\e]1337;File=inline=1:data\a")
    end

    test "returns false for regular text" do
      refute Image.image_line?("just text")
    end

    # --- upstream terminal-image.test.ts image_line? coverage ---

    test "detects iTerm2 escape with text before, in middle, and at end" do
      assert Image.image_line?("Some text \e]1337;File=size=100,100;inline=1:base64data==\a more")

      assert Image.image_line?(
               "Text before image..." <>
                 "\e]1337;File=inline=1:verylongbase64data==" <>
                 "...text after"
             )

      assert Image.image_line?("Regular text ending with \e]1337;File=inline=1:base64data==\a")

      assert Image.image_line?("\e]1337;File=:\a")
    end

    test "detects Kitty escape with text before and with surrounding whitespace" do
      assert Image.image_line?("Output: \e_Ga=T,f=100;data...\e\\")
      assert Image.image_line?("  \e_Ga=T,f=100...\e\\  ")
    end

    test "detects image sequences in very long lines (>300KB)" do
      long =
        "Text prefix " <>
          "\e]1337;File=size=800,600;inline=1:" <>
          String.duplicate("A", 300_000) <> " suffix"

      assert byte_size(long) > 300_000
      assert Image.image_line?(long)
    end

    test "detects image sequences exactly at the 58649-char crash-log size" do
      prefix = "Text"
      sequence = "\e_Ga=T,f=100"
      suffix = "End"
      fill_len = 58_649 - String.length(prefix) - String.length(sequence) - String.length(suffix)
      line = prefix <> sequence <> String.duplicate("A", fill_len) <> suffix
      assert String.length(line) == 58_649
      assert Image.image_line?(line)
    end

    test "detects image sequences with ANSI codes before and after" do
      assert Image.image_line?("\e[31mError\e[0m: \e]1337;File=inline=1:base64==\a")

      assert Image.image_line?("\e[33mWarning\e[0m: \e_Ga=T,data...\e\\")
      assert Image.image_line?("\e_Ga=T,f=100:data...\e\\\e_Gm=i=1;\e\\\e[0m reset")
    end

    test "detects mixed Kitty + iTerm2 and multiple iTerm2 segments in one line" do
      mixed = "Kitty: \e_Ga=T...\e\\\e_Gm=i=1;\e\\ iTerm2: \e]1337;File=inline=1:data==\a"
      assert Image.image_line?(mixed)

      complex = "Start \e]1337;File=img1==\a middle \e]1337;File=img2==\a end"
      assert Image.image_line?(complex)
    end

    test "negative: ANSI-only, cursor-only, empty, newline-only lines" do
      refute Image.image_line?("\e[31mRed\e[0m and \e[32mgreen\e[0m")
      refute Image.image_line?("\e[1A\e[2KLine cleared")
      refute Image.image_line?("")
      refute Image.image_line?("\n")
      refute Image.image_line?("\n\n")
    end

    test "negative: partial sequences without ESC" do
      refute Image.image_line?("Some text with ]1337;File but missing ESC")
      refute Image.image_line?("Some text with _G but missing ESC")
    end

    test "negative: file paths containing image-like keywords" do
      refute Image.image_line?("/path/to/File_1337_backup/image.jpg")
      refute Image.image_line?("/path/to/1337/image.jpg")
      refute Image.image_line?("/usr/local/bin/File_converter")
      refute Image.image_line?("~/Documents/1337File_backup.png")
      refute Image.image_line?("./_G_test_file.txt")
    end

    test "detects even in regular long text without image sequences" do
      refute Image.image_line?(String.duplicate("A", 100_000))
    end
  end

  describe "get_jpeg_dimensions/1" do
    test "extracts width and height from minimal JPEG with SOF0 marker" do
      # SOI(FF D8) + SOF0(FF C0) + length(00 0B) + precision(08) + height(00 64) + width(00 32) + ncomp(01 01 11 00)
      jpeg =
        <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x64, 0x00, 0x32, 0x01, 0x01, 0x11,
          0x00>>

      assert {:ok, %{width: 50, height: 100}} = Image.get_jpeg_dimensions(Base.encode64(jpeg))
    end

    test "skips APP0 marker before SOF0" do
      # APP0(FF E0) + length(00 10 = 16) + 14 bytes junk + SOF0 with 200x100
      app0 = <<0xFF, 0xE0, 0x00, 0x10>> <> String.duplicate(<<0x00>>, 14)

      sof0 =
        <<0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0xC8, 0x00, 0x64, 0x01, 0x01, 0x11, 0x00>>

      jpeg = <<0xFF, 0xD8>> <> app0 <> sof0
      assert {:ok, %{width: 100, height: 200}} = Image.get_jpeg_dimensions(Base.encode64(jpeg))
    end

    test "returns error for non-JPEG data" do
      assert :error = Image.get_jpeg_dimensions(Base.encode64("not a jpeg"))
    end
  end

  describe "get_gif_dimensions/1" do
    test "extracts width and height from GIF89a header" do
      gif = <<"GIF89a", 100::little-16, 50::little-16, 0x00>>
      assert {:ok, %{width: 100, height: 50}} = Image.get_gif_dimensions(Base.encode64(gif))
    end

    test "extracts width and height from GIF87a header" do
      gif = <<"GIF87a", 320::little-16, 240::little-16, 0x00>>
      assert {:ok, %{width: 320, height: 240}} = Image.get_gif_dimensions(Base.encode64(gif))
    end

    test "returns error for non-GIF data" do
      assert :error = Image.get_gif_dimensions(Base.encode64("not a gif"))
    end
  end

  describe "get_webp_dimensions/1" do
    test "extracts width and height from VP8 (lossy) WebP" do
      # RIFF(4) + size(4) + WEBP(4) + "VP8 "(4) + chunk_size(4) = 20 bytes header
      # Then VP8 bitstream: frame_tag(3) + magic(3) + w_bits(2 LE) + h_bits(2 LE)
      webp =
        "RIFF" <>
          <<0, 0, 0, 0>> <>
          "WEBP" <>
          "VP8 " <>
          <<0, 0, 0, 0>> <>
          <<0, 0, 0, 0x9D, 0x01, 0x2A>> <>
          <<100::little-16, 50::little-16>>

      assert {:ok, %{width: 100, height: 50}} = Image.get_webp_dimensions(Base.encode64(webp))
    end

    test "extracts width and height from VP8L (lossless) WebP" do
      # VP8L bitstream at offset 21: width-1 in bits 0-13, height-1 in bits 14-27 (LSB-first packing)
      # width=100 → width-1=99=0x63, height=50 → height-1=49=0x31
      # Byte 0: bits 0-7 of width-1 = 0x63
      # Byte 1: bits 8-13 of width-1 (all 0) + bits 0-1 of height-1 (01 in pos 6-7) = 0x40
      # Byte 2: bits 2-7 of height-1 = 0b001100 in pos 0-5 = 0x0C
      # decoded: bits = 0x63 | (0x40 << 8) | (0x0C << 16) = 0xC4063
      #          width = (0xC4063 & 0x3FFF) + 1 = 99 + 1 = 100
      #          height = ((0xC4063 >> 14) & 0x3FFF) + 1 = 49 + 1 = 50
      webp =
        "RIFF" <>
          <<0, 0, 0, 0>> <>
          "WEBP" <>
          "VP8L" <>
          <<0, 0, 0, 0>> <>
          <<0x2F, 0x63, 0x40, 0x0C, 0x00>>

      assert {:ok, %{width: 100, height: 50}} = Image.get_webp_dimensions(Base.encode64(webp))
    end

    test "returns error for non-WebP data" do
      assert :error = Image.get_webp_dimensions(Base.encode64("not a webp"))
    end
  end

  describe "get_image_dimensions/2" do
    test "dispatches to PNG parser" do
      header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x32>>

      assert {:ok, %{width: 100, height: 50}} =
               Image.get_image_dimensions(Base.encode64(header), "image/png")
    end

    test "dispatches to GIF parser" do
      gif = <<"GIF89a", 10::little-16, 5::little-16, 0x00>>
      assert {:ok, %{width: 10, height: 5}} = Image.get_image_dimensions(Base.encode64(gif), "image/gif")
    end

    test "returns error for unknown mime type" do
      assert :error = Image.get_image_dimensions(Base.encode64("data"), "image/tiff")
    end
  end

  describe "render_image/3" do
    test "returns fallback when no image capability" do
      with_env(%{}, fn ->
        result = Image.render_image(Base.encode64("data"), %{width: 800, height: 600})
        assert {:fallback, text} = result
        assert is_binary(text)
      end)
    end

    test "returns kitty-encoded bytes when kitty capability present" do
      with_env(%{"KITTY_WINDOW_ID" => "1"}, fn ->
        data = Base.encode64(String.duplicate("x", 10))
        {:ok, encoded, rows} = Image.render_image(data, %{width: 800, height: 600})
        assert encoded =~ "\e_G"
        assert is_integer(rows) and rows >= 1
      end)
    end
  end

  describe "delete_kitty_image/1 and delete_all_kitty_images/0" do
    test "delete_kitty_image builds correct escape sequence" do
      result = Image.delete_kitty_image(42)
      assert result =~ "\e_G"
      assert result =~ "a=d"
      assert result =~ "i=42"
    end

    test "delete_all_kitty_images builds correct escape sequence" do
      result = Image.delete_all_kitty_images()
      assert result =~ "\e_G"
      assert result =~ "a=d"
    end
  end

  describe "detect_capabilities/0 — upstream terminal-image.test.ts env-based coverage" do
    test "unknown terminal: hyperlinks false, images nil" do
      with_env(%{}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TMUX forces hyperlinks false even when outer TERM_PROGRAM would enable" do
      with_env(%{"TMUX" => "/tmp/tmux-1000/default,1234,0", "TERM_PROGRAM" => "ghostty"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TERM=tmux-256color forces hyperlinks false" do
      with_env(%{"TERM" => "tmux-256color", "TERM_PROGRAM" => "iterm.app"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TERM=screen-256color forces hyperlinks false" do
      with_env(%{"TERM" => "screen-256color"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "Ghostty enables hyperlinks and kitty images" do
      with_env(%{"TERM_PROGRAM" => "ghostty"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "KITTY_WINDOW_ID enables hyperlinks and kitty images" do
      with_env(%{"KITTY_WINDOW_ID" => "1"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "WEZTERM_PANE enables hyperlinks" do
      with_env(%{"WEZTERM_PANE" => "0"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "iTerm2 enables hyperlinks" do
      with_env(%{"TERM_PROGRAM" => "iterm.app"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "VSCode enables hyperlinks" do
      with_env(%{"TERM_PROGRAM" => "vscode"}, fn ->
        caps = Image.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end
  end

  describe "hyperlink/2" do
    test "wraps text in OSC 8 hyperlink" do
      result = Image.hyperlink("click me", "https://example.com")
      assert result =~ "\e]8;;"
      assert result =~ "https://example.com"
      assert result =~ "click me"
    end

    # --- upstream hyperlink tests (exact format + styling + file://) ---

    test "exact OSC 8 open/close bracketing" do
      assert Image.hyperlink("click me", "https://example.com") ==
               "\e]8;;https://example.com\e\\click me\e]8;;\e\\"
    end

    test "preserves ANSI styling inside the hyperlink" do
      styled = "\e[4m\e[34mclick me\e[0m"
      result = Image.hyperlink(styled, "https://example.com")
      assert String.starts_with?(result, "\e]8;;https://example.com\e\\")
      assert String.contains?(result, styled)
      assert String.ends_with?(result, "\e]8;;\e\\")
    end

    test "works with empty text" do
      assert Image.hyperlink("", "https://example.com") ==
               "\e]8;;https://example.com\e\\\e]8;;\e\\"
    end

    test "works with file:// URIs" do
      result = Image.hyperlink("README.md", "file:///home/user/README.md")
      assert String.contains?(result, "file:///home/user/README.md")
      assert String.contains?(result, "README.md")
    end
  end
end
