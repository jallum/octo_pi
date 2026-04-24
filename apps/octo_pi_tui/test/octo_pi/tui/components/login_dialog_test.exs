defmodule OctoPi.TUI.Components.LoginDialogTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.LoginDialog
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp key(name), do: %Key{key: name}

  defp type(dialog, string) do
    Enum.reduce(String.graphemes(string), dialog, fn char, d ->
      LoginDialog.handle_char(d, char)
    end)
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/1" do
    test "creates dialog with empty value" do
      d = LoginDialog.new(@theme)
      assert d.value == ""
      assert d.error == nil
    end

    test "accepts provider label" do
      d = LoginDialog.new(@theme, provider: "Anthropic")
      assert d.provider == "Anthropic"
    end
  end

  # ── Input ──────────────────────────────────────────────────────

  describe "handle_char/2" do
    test "typing appends characters" do
      d = LoginDialog.new(@theme) |> type("sk-ant-")
      assert d.value == "sk-ant-"
    end
  end

  describe "handle_key/2" do
    test "backspace removes last character" do
      d = LoginDialog.new(@theme) |> type("abc")
      {d, _} = LoginDialog.handle_key(d, key(:backspace))
      assert d.value == "ab"
    end

    test "backspace on empty is no-op" do
      d = LoginDialog.new(@theme)
      {d, _} = LoginDialog.handle_key(d, key(:backspace))
      assert d.value == ""
    end

    test "escape cancels" do
      d = LoginDialog.new(@theme)
      {_d, events} = LoginDialog.handle_key(d, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Submission ──────────────────────────────────────────────────

  describe "submit" do
    test "valid key emits api_key_entered" do
      d = LoginDialog.new(@theme) |> type("sk-ant-api03-validkeyhere1234567890abcdef")
      {_d, events} = LoginDialog.handle_key(d, key(:enter))
      assert [{:api_key_entered, "sk-ant-api03-validkeyhere1234567890abcdef"}] = events
    end

    test "empty input sets error" do
      d = LoginDialog.new(@theme)
      {d, events} = LoginDialog.handle_key(d, key(:enter))
      assert d.error != nil
      assert events == []
    end

    test "invalid format sets error" do
      d = LoginDialog.new(@theme) |> type("not-a-key")
      {d, events} = LoginDialog.handle_key(d, key(:enter))
      assert d.error != nil
      assert events == []
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2" do
    test "shows masked input" do
      d = LoginDialog.new(@theme) |> type("sk-ant-api03-secret1234")
      lines = LoginDialog.render(d, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      text = Enum.join(stripped, "\n")
      refute text =~ "sk-ant-api03"
      assert text =~ "1234"
    end

    test "shows provider name" do
      d = LoginDialog.new(@theme, provider: "Anthropic")
      lines = LoginDialog.render(d, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Anthropic"))
    end

    test "shows error message when present" do
      d = LoginDialog.new(@theme) |> type("bad")
      {d, _} = LoginDialog.handle_key(d, key(:enter))
      lines = LoginDialog.render(d, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, fn l -> String.contains?(l, d.error) end)
    end

    test "short input shows all masked" do
      d = LoginDialog.new(@theme) |> type("ab")
      lines = LoginDialog.render(d, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      text = Enum.join(stripped, "\n")
      assert text =~ "••"
    end
  end
end
