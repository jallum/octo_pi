defmodule OctoPi.TUI.Components.SessionSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SessionSelector
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp key(name), do: %Key{key: name}

  defp press(selector, key_spec) do
    case SessionSelector.handle_key(selector, key_spec) do
      {new, _events} -> new
      new -> new
    end
  end

  defp test_sessions do
    [
      %{
        id: "s1",
        name: "Debug auth flow",
        message_count: 12,
        model: "opus",
        updated_at: ~U[2026-04-20 10:00:00Z]
      },
      %{
        id: "s2",
        name: "Refactor parser",
        message_count: 8,
        model: "sonnet",
        updated_at: ~U[2026-04-22 15:30:00Z]
      },
      %{
        id: "s3",
        name: "Write tests",
        message_count: 3,
        model: "opus",
        updated_at: ~U[2026-04-24 09:00:00Z]
      }
    ]
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/3" do
    test "creates selector with sessions" do
      sel = SessionSelector.new(test_sessions(), @theme)
      assert sel.selected == 0
      assert length(sel.sessions) == 3
    end

    test "marks current session" do
      sel = SessionSelector.new(test_sessions(), @theme, current: "s2")
      assert sel.current_id == "s2"
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    test "Down moves selection" do
      sel = SessionSelector.new(test_sessions(), @theme) |> press(key(:down))
      assert sel.selected == 1
    end

    test "Up wraps" do
      sel = SessionSelector.new(test_sessions(), @theme) |> press(key(:up))
      assert sel.selected == 2
    end
  end

  # ── Selection ──────────────────────────────────────────────────

  describe "selection" do
    test "Enter emits resume event" do
      sel = SessionSelector.new(test_sessions(), @theme)
      {_sel, events} = SessionSelector.handle_key(sel, key(:enter))
      assert [{:resume_session, session}] = events
      assert session.id == "s1"
    end

    test "Escape cancels" do
      sel = SessionSelector.new(test_sessions(), @theme)
      {_sel, events} = SessionSelector.handle_key(sel, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Delete ─────────────────────────────────────────────────────

  describe "delete" do
    test "Ctrl+D emits delete event" do
      sel = SessionSelector.new(test_sessions(), @theme)
      {_sel, events} = SessionSelector.handle_key(sel, %Key{key: ?d, modifiers: [:ctrl]})
      assert [{:delete_session, session}] = events
      assert session.id == "s1"
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2" do
    test "shows session names" do
      sel = SessionSelector.new(test_sessions(), @theme)
      lines = sel |> SessionSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "Debug auth flow"))
      assert Enum.any?(lines, &(&1 =~ "Write tests"))
    end

    test "marks current session with checkmark" do
      sel = SessionSelector.new(test_sessions(), @theme, current: "s2")
      lines = sel |> SessionSelector.render(60) |> Enum.map(&strip_ansi/1)
      refactor_line = Enum.find(lines, &(&1 =~ "Refactor parser"))
      assert refactor_line =~ "✓"
    end

    test "shows message count" do
      sel = SessionSelector.new(test_sessions(), @theme)
      lines = sel |> SessionSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "12"))
    end
  end

  # ── Filter ─────────────────────────────────────────────────────

  describe "filtering" do
    test "filters by name" do
      sel = SessionSelector.new(test_sessions(), @theme) |> SessionSelector.filter("debug")
      assert length(sel.filtered_sessions) == 1
    end

    test "empty filter shows all" do
      sel = SessionSelector.new(test_sessions(), @theme) |> SessionSelector.filter("")
      assert length(sel.filtered_sessions) == 3
    end
  end
end
