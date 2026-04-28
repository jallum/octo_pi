defmodule OctoPi.TUI.ClipboardTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Clipboard

  describe "osc52/1" do
    test "encodes text as OSC 52 escape sequence" do
      result = Clipboard.osc52("hello")
      encoded = Base.encode64("hello")
      assert result == "\e]52;c;#{encoded}\a"
    end

    test "handles empty string" do
      result = Clipboard.osc52("")
      assert result == "\e]52;c;#{Base.encode64("")}\a"
    end

    test "handles unicode" do
      result = Clipboard.osc52("héllo")
      encoded = Base.encode64("héllo")
      assert result == "\e]52;c;#{encoded}\a"
    end
  end

  describe "platform_command/0" do
    test "returns a command tuple for the current platform" do
      result = Clipboard.platform_command()
      assert is_tuple(result) or result == nil
    end
  end

  describe "copy/2" do
    test "returns :ok with osc52 output" do
      {result, osc} = Clipboard.copy("test text", write_osc: false)
      assert result == :ok
      assert osc =~ "\e]52;c;"
    end

    test "copy with empty string" do
      {result, _osc} = Clipboard.copy("", write_osc: false)
      assert result == :ok
    end
  end

  describe "extract_code_blocks/1" do
    test "extracts fenced code blocks" do
      markdown = """
      Some text

      ```elixir
      defmodule Foo do
        def bar, do: :ok
      end
      ```

      More text
      """

      blocks = Clipboard.extract_code_blocks(markdown)
      assert length(blocks) == 1
      assert hd(blocks) =~ "defmodule Foo"
    end

    test "extracts multiple code blocks" do
      markdown = """
      ```
      first
      ```

      ```python
      second
      ```
      """

      blocks = Clipboard.extract_code_blocks(markdown)
      assert length(blocks) == 2
      assert Enum.at(blocks, 0) =~ "first"
      assert Enum.at(blocks, 1) =~ "second"
    end

    test "returns empty list when no code blocks" do
      assert Clipboard.extract_code_blocks("no code here") == []
    end
  end

  describe "paste_image_from_clipboard/0" do
    test "never raises; returns :error or {:ok, map} with binary data and mime_type" do
      result = Clipboard.paste_image_from_clipboard()

      case result do
        :error ->
          assert true

        {:ok, %{data: data, mime_type: mime}} ->
          assert is_binary(data)
          assert is_binary(mime)
      end
    end
  end
end
