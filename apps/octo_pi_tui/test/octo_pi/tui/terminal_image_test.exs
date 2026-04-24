defmodule OctoPi.TUI.TerminalImageTest do
  # async: false — tests mutate TERM_* env vars around detect_capabilities
  use ExUnit.Case, async: false

  alias OctoPi.TUI.TerminalImage

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

    # --- upstream terminal-image.test.ts image_line? coverage ---

    test "detects iTerm2 escape with text before, in middle, and at end" do
      assert TerminalImage.image_line?(
               "Some text \e]1337;File=size=100,100;inline=1:base64data==\a more"
             )

      assert TerminalImage.image_line?(
               "Text before image..." <>
                 "\e]1337;File=inline=1:verylongbase64data==" <>
                 "...text after"
             )

      assert TerminalImage.image_line?(
               "Regular text ending with \e]1337;File=inline=1:base64data==\a"
             )

      assert TerminalImage.image_line?("\e]1337;File=:\a")
    end

    test "detects Kitty escape with text before and with surrounding whitespace" do
      assert TerminalImage.image_line?("Output: \e_Ga=T,f=100;data...\e\\")
      assert TerminalImage.image_line?("  \e_Ga=T,f=100...\e\\  ")
    end

    test "detects image sequences in very long lines (>300KB)" do
      long =
        "Text prefix " <>
          "\e]1337;File=size=800,600;inline=1:" <>
          String.duplicate("A", 300_000) <> " suffix"

      assert byte_size(long) > 300_000
      assert TerminalImage.image_line?(long)
    end

    test "detects image sequences exactly at the 58649-char crash-log size" do
      prefix = "Text"
      sequence = "\e_Ga=T,f=100"
      suffix = "End"
      fill_len = 58_649 - String.length(prefix) - String.length(sequence) - String.length(suffix)
      line = prefix <> sequence <> String.duplicate("A", fill_len) <> suffix
      assert String.length(line) == 58_649
      assert TerminalImage.image_line?(line)
    end

    test "detects image sequences with ANSI codes before and after" do
      assert TerminalImage.image_line?("\e[31mError\e[0m: \e]1337;File=inline=1:base64==\a")

      assert TerminalImage.image_line?("\e[33mWarning\e[0m: \e_Ga=T,data...\e\\")
      assert TerminalImage.image_line?("\e_Ga=T,f=100:data...\e\\\e_Gm=i=1;\e\\\e[0m reset")
    end

    test "detects mixed Kitty + iTerm2 and multiple iTerm2 segments in one line" do
      mixed = "Kitty: \e_Ga=T...\e\\\e_Gm=i=1;\e\\ iTerm2: \e]1337;File=inline=1:data==\a"
      assert TerminalImage.image_line?(mixed)

      complex = "Start \e]1337;File=img1==\a middle \e]1337;File=img2==\a end"
      assert TerminalImage.image_line?(complex)
    end

    test "negative: ANSI-only, cursor-only, empty, newline-only lines" do
      refute TerminalImage.image_line?("\e[31mRed\e[0m and \e[32mgreen\e[0m")
      refute TerminalImage.image_line?("\e[1A\e[2KLine cleared")
      refute TerminalImage.image_line?("")
      refute TerminalImage.image_line?("\n")
      refute TerminalImage.image_line?("\n\n")
    end

    test "negative: partial sequences without ESC" do
      refute TerminalImage.image_line?("Some text with ]1337;File but missing ESC")
      refute TerminalImage.image_line?("Some text with _G but missing ESC")
    end

    test "negative: file paths containing image-like keywords" do
      refute TerminalImage.image_line?("/path/to/File_1337_backup/image.jpg")
      refute TerminalImage.image_line?("/path/to/1337/image.jpg")
      refute TerminalImage.image_line?("/usr/local/bin/File_converter")
      refute TerminalImage.image_line?("~/Documents/1337File_backup.png")
      refute TerminalImage.image_line?("./_G_test_file.txt")
    end

    test "detects even in regular long text without image sequences" do
      refute TerminalImage.image_line?(String.duplicate("A", 100_000))
    end
  end

  describe "detect_capabilities/0 — upstream terminal-image.test.ts env-based coverage" do
    test "unknown terminal: hyperlinks false, images nil" do
      with_env(%{}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TMUX forces hyperlinks false even when outer TERM_PROGRAM would enable" do
      with_env(%{"TMUX" => "/tmp/tmux-1000/default,1234,0", "TERM_PROGRAM" => "ghostty"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TERM=tmux-256color forces hyperlinks false" do
      with_env(%{"TERM" => "tmux-256color", "TERM_PROGRAM" => "iterm.app"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "TERM=screen-256color forces hyperlinks false" do
      with_env(%{"TERM" => "screen-256color"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == false
        assert caps.images == nil
      end)
    end

    test "Ghostty enables hyperlinks and kitty images" do
      with_env(%{"TERM_PROGRAM" => "ghostty"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "KITTY_WINDOW_ID enables hyperlinks and kitty images" do
      with_env(%{"KITTY_WINDOW_ID" => "1"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "WEZTERM_PANE enables hyperlinks" do
      with_env(%{"WEZTERM_PANE" => "0"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "iTerm2 enables hyperlinks" do
      with_env(%{"TERM_PROGRAM" => "iterm.app"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end

    test "VSCode enables hyperlinks" do
      with_env(%{"TERM_PROGRAM" => "vscode"}, fn ->
        caps = TerminalImage.detect_capabilities()
        assert caps.hyperlinks == true
      end)
    end
  end

  describe "hyperlink/2" do
    test "wraps text in OSC 8 hyperlink" do
      result = TerminalImage.hyperlink("click me", "https://example.com")
      assert result =~ "\e]8;;"
      assert result =~ "https://example.com"
      assert result =~ "click me"
    end

    # --- upstream hyperlink tests (exact format + styling + file://) ---

    test "exact OSC 8 open/close bracketing" do
      assert TerminalImage.hyperlink("click me", "https://example.com") ==
               "\e]8;;https://example.com\e\\click me\e]8;;\e\\"
    end

    test "preserves ANSI styling inside the hyperlink" do
      styled = "\e[4m\e[34mclick me\e[0m"
      result = TerminalImage.hyperlink(styled, "https://example.com")
      assert String.starts_with?(result, "\e]8;;https://example.com\e\\")
      assert String.contains?(result, styled)
      assert String.ends_with?(result, "\e]8;;\e\\")
    end

    test "works with empty text" do
      assert TerminalImage.hyperlink("", "https://example.com") ==
               "\e]8;;https://example.com\e\\\e]8;;\e\\"
    end

    test "works with file:// URIs" do
      result = TerminalImage.hyperlink("README.md", "file:///home/user/README.md")
      assert String.contains?(result, "file:///home/user/README.md")
      assert String.contains?(result, "README.md")
    end
  end
end
