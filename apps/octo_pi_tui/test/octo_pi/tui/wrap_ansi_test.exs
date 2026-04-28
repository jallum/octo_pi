defmodule OctoPi.TUI.WrapAnsiTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.WrapAnsi

  describe "visible_width/1" do
    test "plain ASCII" do
      assert WrapAnsi.visible_width("hello") == 5
    end

    test "ignores CSI SGR codes" do
      assert WrapAnsi.visible_width("\e[31mhello\e[0m") == 5
    end

    test "ignores OSC 133 semantic markers (BEL terminated)" do
      assert WrapAnsi.visible_width("\e]133;A\x07hello\e]133;B\x07") == 5
    end

    test "ignores OSC sequences terminated with ST" do
      assert WrapAnsi.visible_width("\e]133;A\e\\hello\e]133;B\e\\") == 5
    end

    test "treats isolated regional indicators as width 2" do
      assert WrapAnsi.visible_width("🇨") == 2
      assert WrapAnsi.visible_width("🇨🇳") == 2
    end

    test "partial flag in list line measures to surrounding + flag width" do
      # 6 spaces + "- " (2) + 🇨 (2) = 10
      assert WrapAnsi.visible_width("      - 🇨") == 10
    end

    test "every regional-indicator singleton (U+1F1E6..U+1F1FF) is width 2" do
      for cp <- 0x1F1E6..0x1F1FF do
        grapheme = <<cp::utf8>>

        assert WrapAnsi.visible_width(grapheme) == 2,
               "expected U+#{cp |> Integer.to_string(16) |> String.upcase()} width 2"
      end
    end

    test "full flag pairs measure as width 2" do
      for flag <- ["🇯🇵", "🇺🇸", "🇬🇧", "🇨🇳", "🇩🇪", "🇫🇷"] do
        assert WrapAnsi.visible_width(flag) == 2, "expected #{flag} width 2"
      end
    end

    test "common streaming emoji intermediates remain width 2" do
      for sample <- ["👍", "👍🏻", "✅", "⚡", "⚡️", "👨", "👨‍💻", "🏳️‍🌈"] do
        assert WrapAnsi.visible_width(sample) == 2, "expected #{sample} width 2"
      end
    end

    test "CJK characters are width 2" do
      assert WrapAnsi.visible_width("日本") == 4
    end

    test "fullwidth forms are width 2" do
      assert WrapAnsi.visible_width("ＡＢ") == 4
    end

    test "tab is width 3 inline (matches upstream normalization)" do
      assert WrapAnsi.visible_width("\t") == 3
      assert WrapAnsi.visible_width("\t\e[31m界\e[0m") == 5
    end

    test "truncated multi-byte UTF-8 followed by ANSI code does not crash" do
      # 0xE2 0x94 = first two bytes of a 3-byte box-drawing char (e.g. ─ = 0xE2 0x94 0x80),
      # followed immediately by an ESC SGR code — the incomplete sequence must be dropped.
      bad = <<0xE2, 0x94, 0x1B, 0x5B, 0x33, 0x39, 0x6D>>
      assert is_integer(WrapAnsi.visible_width(bad))
    end

    test "arbitrary invalid UTF-8 bytes do not crash" do
      assert is_integer(WrapAnsi.visible_width(<<0xFF, 0xFE, 0x80>>))
    end
  end

  describe "truncate_to_width/4" do
    test "returns empty string when max_width <= 0" do
      assert WrapAnsi.truncate_to_width("hello", 0, "...", false) == ""
    end

    test "empty input returns empty string when not padded" do
      assert WrapAnsi.truncate_to_width("", 5, "...", false) == ""
    end

    test "empty input pads to max_width when pad is true" do
      assert WrapAnsi.truncate_to_width("", 5, "...", true) == "     "
    end

    test "returns original text when it already fits" do
      assert WrapAnsi.truncate_to_width("hello", 10, "...", false) == "hello"
    end

    test "returns original text that fits even if ellipsis is wider than width" do
      assert WrapAnsi.truncate_to_width("a", 2, "🙂", false) == "a"
      assert WrapAnsi.truncate_to_width("界", 2, "🙂", false) == "界"
    end

    test "wide ellipsis clipping when ellipsis wider than max_width" do
      assert WrapAnsi.truncate_to_width("abcdef", 1, "🙂", false) == ""
      assert WrapAnsi.truncate_to_width("abcdef", 2, "🙂", false) == "\e[0m🙂\e[0m"
      assert WrapAnsi.visible_width(WrapAnsi.truncate_to_width("abcdef", 2, "🙂", false)) <= 2
    end

    test "keeps output within width for very large unicode input" do
      text = String.duplicate("🙂界", 100_000)
      result = WrapAnsi.truncate_to_width(text, 40, "…", false)
      assert WrapAnsi.visible_width(result) <= 40
      assert String.ends_with?(result, "…\e[0m")
    end

    test "preserves ANSI styling for kept text and resets before/after ellipsis" do
      text = "\e[31m" <> String.duplicate("hello ", 1000) <> "\e[0m"
      result = WrapAnsi.truncate_to_width(text, 20, "…", false)
      assert WrapAnsi.visible_width(result) <= 20
      assert String.contains?(result, "\e[31m")
      assert String.ends_with?(result, "\e[0m…\e[0m")
    end

    test "handles malformed ANSI prefixes without hanging" do
      text = "abc\enot-ansi " <> String.duplicate("🙂", 1000)
      result = WrapAnsi.truncate_to_width(text, 20, "…", false)
      assert WrapAnsi.visible_width(result) <= 20
    end

    test "pads truncated output to requested width" do
      result = WrapAnsi.truncate_to_width("🙂界🙂界🙂界", 8, "…", true)
      assert WrapAnsi.visible_width(result) == 8
    end

    test "no-ellipsis mode adds trailing reset after truncation" do
      text = "\e[31m" <> String.duplicate("hello", 100)
      result = WrapAnsi.truncate_to_width(text, 10, "", false)
      assert WrapAnsi.visible_width(result) <= 10
      assert String.ends_with?(result, "\e[0m")
    end

    test "keeps contiguous prefix (does not skip wide grapheme and resume)" do
      # "🙂" (2) + "\t" (3) + "界" (2) = 7 kept-or-rejected; "界" fits
      # in visible budget but breaks contiguous prefix after "🙂\t"
      # since kept(5) + 2 > targetWidth(6). Ellipsis "…" (1) is added
      # with reset brackets; padded to 7 with trailing space.
      assert WrapAnsi.truncate_to_width("🙂\t界 \e_abc\x07", 7, "…", true) ==
               "🙂\t\e[0m…\e[0m "
    end
  end

  describe "basic wrapping" do
    test "wraps plain text correctly" do
      wrapped = WrapAnsi.wrap("hello world this is a test", 10)
      assert length(wrapped) > 1

      for line <- wrapped do
        assert WrapAnsi.visible_width(line) <= 10
      end
    end

    test "short text stays on one line" do
      assert WrapAnsi.wrap("hello", 80) == ["hello"]
    end

    test "handles embedded newlines" do
      assert WrapAnsi.wrap("hello\nworld", 80) == ["hello", "world"]
    end

    test "truncates trailing whitespace that exceeds width" do
      wrapped = WrapAnsi.wrap("  ", 1)
      assert WrapAnsi.visible_width(hd(wrapped)) <= 1
    end

    test "wraps CJK at grapheme boundaries" do
      text = "日本語テスト"
      wrapped = WrapAnsi.wrap(text, 6)
      assert length(wrapped) > 1

      for line <- wrapped do
        assert WrapAnsi.visible_width(line) <= 6
      end
    end

    test "breaks long words that exceed width" do
      wrapped = WrapAnsi.wrap("abcdefghij", 4)
      assert wrapped == ["abcd", "efgh", "ij"]
    end

    test "wraps partial-flag list line before overflow" do
      # Width 9 cannot fit "      - 🇨" (10 cols); must wrap rather
      # than let the terminal auto-wrap and drift.
      wrapped = WrapAnsi.wrap("      - 🇨", 9)
      assert length(wrapped) == 2
      assert WrapAnsi.visible_width(Enum.at(wrapped, 0)) == 7
      assert WrapAnsi.visible_width(Enum.at(wrapped, 1)) == 2
    end
  end

  describe "underline styling" do
    test "does not apply underline style before the styled text" do
      underline_on = "\e[4m"
      url = "https://example.com/very/long/path/that/will/wrap"
      text = "read this thread #{underline_on}#{url}\e[24m"
      wrapped = WrapAnsi.wrap(text, 40)

      assert hd(wrapped) == "read this thread"
      assert String.starts_with?(Enum.at(wrapped, 1), underline_on)
    end

    test "does not have whitespace before underline reset code" do
      underline_on = "\e[4m"
      underline_off = "\e[24m"
      text = "#{underline_on}underlined text here #{underline_off}more"
      wrapped = WrapAnsi.wrap(text, 18)
      refute String.contains?(hd(wrapped), " #{underline_off}")
    end

    test "does not bleed underline to padding — middle lines end with underline-off, not full reset" do
      underline_on = "\e[4m"
      underline_off = "\e[24m"
      url = "https://example.com/very/long/path/that/will/definitely/wrap"
      text = "prefix #{underline_on}#{url}#{underline_off} suffix"
      wrapped = WrapAnsi.wrap(text, 30)

      for i <- 1..(length(wrapped) - 2) do
        line = Enum.at(wrapped, i)

        if String.contains?(line, underline_on) do
          assert String.ends_with?(line, underline_off),
                 "Line #{i} should end with underline-off: #{inspect(line)}"

          refute String.ends_with?(line, "\e[0m"),
                 "Line #{i} should not end with full reset: #{inspect(line)}"
        end
      end
    end
  end

  describe "background color preservation" do
    test "preserves background color across wrapped lines without full reset" do
      bg_blue = "\e[44m"
      text = "#{bg_blue}hello world this is blue background text\e[0m"
      wrapped = WrapAnsi.wrap(text, 15)

      for line <- wrapped do
        assert String.contains?(line, bg_blue),
               "Line should have background color: #{inspect(line)}"
      end

      for i <- 0..(length(wrapped) - 2) do
        refute String.ends_with?(Enum.at(wrapped, i), "\e[0m"),
               "Middle line #{i} should not end with full reset"
      end
    end

    test "resets underline but preserves background when wrapping underlined text inside background" do
      underline_on = "\e[4m"
      underline_off = "\e[24m"

      text =
        "\e[41mprefix #{underline_on}UNDERLINED_CONTENT_THAT_WRAPS#{underline_off} suffix\e[0m"

      wrapped = WrapAnsi.wrap(text, 20)

      for line <- wrapped do
        has_bg =
          String.contains?(line, "[41m") or
            String.contains?(line, ";41m") or
            String.contains?(line, "[41;")

        assert has_bg, "Line should have bg color 41: #{inspect(line)}"
      end

      for i <- 0..(length(wrapped) - 2) do
        line = Enum.at(wrapped, i)

        has_underline =
          (String.contains?(line, "[4m") or
             String.contains?(line, "[4;") or
             String.contains?(line, ";4m")) and
            not String.contains?(line, underline_off)

        if has_underline do
          assert String.ends_with?(line, underline_off)
          refute String.ends_with?(line, "\e[0m")
        end
      end
    end
  end

  describe "color code preservation" do
    test "preserves color codes across wraps" do
      red = "\e[31m"
      text = "#{red}hello world this is red\e[0m"
      wrapped = WrapAnsi.wrap(text, 10)

      for i <- 1..(length(wrapped) - 1) do
        assert String.starts_with?(Enum.at(wrapped, i), red),
               "Continuation line #{i} should start with red"
      end

      for i <- 0..(length(wrapped) - 2) do
        refute String.ends_with?(Enum.at(wrapped, i), "\e[0m"),
               "Middle line #{i} should not end with full reset"
      end
    end
  end

  describe "OSC 8 hyperlinks" do
    @osc_open "\e]8;;https://example.com\e\\"
    @osc_close "\e]8;;\e\\"

    test "re-emits OSC 8 open at start of continuation lines" do
      input = "#{@osc_open}0123456789#{@osc_close}"
      lines = WrapAnsi.wrap(input, 6)

      for line <- lines do
        stripped =
          line
          |> String.replace(~r/\e\]8;;[^\e\x07]*\e\\/, "")
          |> String.replace(~r/\e\[[0-9;]*m/, "")

        if String.trim(stripped) != "" do
          assert String.contains?(line, @osc_open),
                 "Line with visible text should have OSC 8 open: #{inspect(line)}"
        end
      end
    end

    test "closes OSC 8 before each line break" do
      input = "#{@osc_open}0123456789#{@osc_close}"
      lines = WrapAnsi.wrap(input, 6)

      for i <- 0..(length(lines) - 2) do
        line = Enum.at(lines, i)

        if String.contains?(line, @osc_open) do
          assert String.ends_with?(line, @osc_close),
                 "Non-final line should close hyperlink: #{inspect(line)}"
        end
      end
    end

    test "does not emit OSC 8 sequences on lines outside the hyperlink" do
      input = "before #{@osc_open}link#{@osc_close} after"
      lines = WrapAnsi.wrap(input, 80)
      assert length(lines) == 1

      open_count =
        ~r/\e\]8;;https:[^\e]+\e\\/ |> Regex.scan(hd(lines)) |> length()

      close_count =
        ~r/\e\]8;;\e\\/ |> Regex.scan(hd(lines)) |> length()

      assert open_count == 1
      assert close_count == 1
    end
  end
end
