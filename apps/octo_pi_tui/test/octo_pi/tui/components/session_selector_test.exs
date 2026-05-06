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
  defp ctrl(ch), do: %Key{key: ch, modifiers: [:ctrl]}

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
        path: "/home/user/.pi/sessions/s1.jsonl",
        message_count: 12,
        model: "opus",
        updated_at: ~U[2026-04-20 10:00:00Z],
        created_at: ~U[2026-04-20 09:00:00Z]
      },
      %{
        id: "s2",
        name: "Refactor parser",
        path: "/home/user/.pi/sessions/s2.jsonl",
        message_count: 8,
        model: "sonnet",
        updated_at: ~U[2026-04-22 15:30:00Z],
        created_at: ~U[2026-04-22 14:00:00Z]
      },
      %{
        id: "s3",
        name: "Write tests",
        path: "/home/user/.pi/sessions/s3.jsonl",
        message_count: 3,
        model: "opus",
        updated_at: ~U[2026-04-24 09:00:00Z],
        created_at: ~U[2026-04-24 08:00:00Z]
      }
    ]
  end

  defp unnamed_sessions do
    [
      %{id: "uuid-1", name: "uuid-1", message_count: 2, updated_at: ~U[2026-04-23 10:00:00Z]},
      %{id: "uuid-2", name: "My Session", message_count: 5, updated_at: ~U[2026-04-24 10:00:00Z]}
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

    test "sorts by modified time descending by default" do
      sel = SessionSelector.new(test_sessions(), @theme)
      ids = Enum.map(sel.filtered_sessions, & &1.id)
      assert ids == ["s3", "s2", "s1"]
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    test "Down moves selection" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(key(:down))
      assert sel.selected == 1
    end

    test "Up wraps" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(key(:up))
      assert sel.selected == 2
    end
  end

  # ── Selection ──────────────────────────────────────────────────

  describe "selection" do
    test "Enter emits resume event" do
      sel = SessionSelector.new(test_sessions(), @theme)
      {_sel, events} = SessionSelector.handle_key(sel, key(:enter))
      assert [{:resume_session, session}] = events
      assert session.id == "s3"
    end

    test "Escape cancels" do
      sel = SessionSelector.new(test_sessions(), @theme)
      {_sel, events} = SessionSelector.handle_key(sel, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Sort ───────────────────────────────────────────────────────

  describe "sort" do
    test "Ctrl+S cycles to next sort mode" do
      sel = test_sessions() |> SessionSelector.new(@theme)
      assert sel.sort_mode == :modified
      sel = press(sel, ctrl(?s))
      assert sel.sort_mode == :name
      sel = press(sel, ctrl(?s))
      assert sel.sort_mode == :created
      sel = press(sel, ctrl(?s))
      assert sel.sort_mode == :modified
    end

    test "sort by name orders alphabetically" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?s))
      names = Enum.map(sel.filtered_sessions, & &1.name)
      assert names == Enum.sort(names)
    end

    test "sort by created orders by created_at descending" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?s)) |> press(ctrl(?s))
      assert sel.sort_mode == :created
      ids = Enum.map(sel.filtered_sessions, & &1.id)
      assert ids == ["s3", "s2", "s1"]
    end
  end

  # ── Named-only filter ──────────────────────────────────────────

  describe "named_only" do
    test "Ctrl+N toggles named-only filter" do
      sel = unnamed_sessions() |> SessionSelector.new(@theme)
      assert sel.named_only == false
      sel = press(sel, ctrl(?n))
      assert sel.named_only == true
    end

    test "named-only hides sessions where name equals id" do
      sel = unnamed_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?n))
      assert length(sel.filtered_sessions) == 1
      assert hd(sel.filtered_sessions).name == "My Session"
    end

    test "toggling named-only off restores all sessions" do
      sel = unnamed_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?n)) |> press(ctrl(?n))
      assert length(sel.filtered_sessions) == 2
    end
  end

  # ── Path toggle ────────────────────────────────────────────────

  describe "show_path" do
    test "Ctrl+P toggles path display" do
      sel = test_sessions() |> SessionSelector.new(@theme)
      refute sel.show_path
      sel = press(sel, ctrl(?p))
      assert sel.show_path
    end

    test "path mode shows file path in render" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?p))
      lines = sel |> SessionSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &String.contains?(&1, ".pi/sessions"))
    end

    test "default mode shows session name" do
      sel = SessionSelector.new(test_sessions(), @theme)
      lines = sel |> SessionSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "Debug auth flow"))
    end
  end

  # ── Delete ─────────────────────────────────────────────────────

  describe "delete with confirm" do
    test "Ctrl+D enters confirm mode" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel = press(sel, ctrl(?d))
      assert sel.confirm_delete != nil
    end

    test "y confirms deletion" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel = press(sel, ctrl(?d))
      {_sel, events} = SessionSelector.handle_key(sel, key(?y))
      assert [{:delete_session, _}] = events
    end

    test "n cancels deletion" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel = press(sel, ctrl(?d))
      sel = press(sel, key(?n))
      assert sel.confirm_delete == nil
    end

    test "escape cancels deletion" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel = press(sel, ctrl(?d))
      sel = press(sel, key(:escape))
      assert sel.confirm_delete == nil
    end

    test "other keys are absorbed while confirming" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel_with_confirm = press(sel, ctrl(?d))
      sel_after = press(sel_with_confirm, key(:down))
      assert sel_after.selected == sel_with_confirm.selected
    end

    test "confirm prompt appears in render" do
      sel = SessionSelector.new(test_sessions(), @theme)
      sel = press(sel, ctrl(?d))
      lines = sel |> SessionSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "y/n"))
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

    test "shows count badge" do
      sel = SessionSelector.new(test_sessions(), @theme)
      lines = sel |> SessionSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "(1/3)"))
    end

    test "shows status line with sort mode" do
      sel = SessionSelector.new(test_sessions(), @theme)
      lines = sel |> SessionSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "sort: modified"))
    end

    test "status line shows named-only hint when active" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> press(ctrl(?n))
      lines = sel |> SessionSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "named only"))
    end
  end

  # ── Filter ─────────────────────────────────────────────────────

  describe "filtering" do
    test "filters by name" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> SessionSelector.filter("debug")
      assert length(sel.filtered_sessions) == 1
    end

    test "empty filter shows all" do
      sel = test_sessions() |> SessionSelector.new(@theme) |> SessionSelector.filter("")
      assert length(sel.filtered_sessions) == 3
    end
  end
end
