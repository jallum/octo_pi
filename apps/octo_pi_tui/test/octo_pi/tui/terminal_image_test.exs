defmodule OctoPi.TUI.TerminalImageTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.TerminalImage

  describe "detect_capabilities/0" do
    test "returns a capabilities map" do
      caps = TerminalImage.detect_capabilities()
      assert is_map(caps)
      assert Map.has_key?(caps, :images)
      assert Map.has_key?(caps, :true_color)
      assert Map.has_key?(caps, :hyperlinks)
    end
  end

  describe "encode_kitty/2" do
    test "encodes short data in a single chunk" do
      data = Base.encode64("tiny")
      result = TerminalImage.encode_kitty(data)
      assert result =~ "\e_G"
      assert result =~ "a=T"
      assert result =~ "f=100"
      assert result =~ data
      assert String.ends_with?(result, "\e\\")
    end

    test "respects columns and rows options" do
      data = Base.encode64("x")
      result = TerminalImage.encode_kitty(data, columns: 40, rows: 10)
      assert result =~ "c=40"
      assert result =~ "r=10"
    end

    test "chunks large data" do
      data = Base.encode64(String.duplicate("x", 5000))
      result = TerminalImage.encode_kitty(data)
      assert result =~ "m=1"
      assert result =~ "m=0"
    end
  end

  describe "encode_iterm2/2" do
    test "encodes inline image" do
      data = Base.encode64("img")
      result = TerminalImage.encode_iterm2(data)
      assert result =~ "\e]1337;File="
      assert result =~ "inline=1"
      assert result =~ data
      assert String.ends_with?(result, "\a")
    end

    test "respects width option" do
      data = Base.encode64("img")
      result = TerminalImage.encode_iterm2(data, width: 60)
      assert result =~ "width=60"
    end
  end

  describe "get_png_dimensions/1" do
    test "extracts dimensions from valid PNG header" do
      header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x32>>

      data = Base.encode64(header)
      assert {:ok, %{width: 100, height: 50}} = TerminalImage.get_png_dimensions(data)
    end

    test "returns error for non-PNG data" do
      data = Base.encode64("not a png")
      assert :error = TerminalImage.get_png_dimensions(data)
    end
  end

  describe "calculate_image_rows/3" do
    test "calculates rows from image dimensions" do
      rows = TerminalImage.calculate_image_rows(%{width: 800, height: 600}, 40)
      assert is_integer(rows)
      assert rows >= 1
    end

    test "returns at least 1 row" do
      rows = TerminalImage.calculate_image_rows(%{width: 1, height: 1}, 80)
      assert rows >= 1
    end
  end

  describe "image_fallback/2" do
    test "returns placeholder text" do
      result = TerminalImage.image_fallback("image/png")
      assert result =~ "[Image:"
      assert result =~ "image/png"
    end

    test "includes dimensions when provided" do
      result = TerminalImage.image_fallback("image/png", dimensions: %{width: 100, height: 50})
      assert result =~ "100x50"
    end

    test "includes filename when provided" do
      result = TerminalImage.image_fallback("image/png", filename: "photo.png")
      assert result =~ "photo.png"
    end
  end

  describe "image_line?/1" do
    test "detects Kitty image lines" do
      assert TerminalImage.image_line?("\e_Ga=T;data\e\\")
    end

    test "detects iTerm2 image lines" do
      assert TerminalImage.image_line?("\e]1337;File=inline=1:data\a")
    end

    test "returns false for regular text" do
      refute TerminalImage.image_line?("just text")
    end
  end

  describe "hyperlink/2" do
    test "wraps text in OSC 8 hyperlink" do
      result = TerminalImage.hyperlink("click me", "https://example.com")
      assert result =~ "\e]8;;"
      assert result =~ "https://example.com"
      assert result =~ "click me"
    end
  end
end
