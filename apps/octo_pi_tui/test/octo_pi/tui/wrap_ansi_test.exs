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
               "expected U+#{Integer.to_string(cp, 16) |> String.upcase()} width 2"
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
        Regex.scan(~r/\e\]8;;https:[^\e]+\e\\/, hd(lines)) |> length()

      close_count =
        Regex.scan(~r/\e\]8;;\e\\/, hd(lines)) |> length()

      assert open_count == 1
      assert close_count == 1
    end
  end
end
