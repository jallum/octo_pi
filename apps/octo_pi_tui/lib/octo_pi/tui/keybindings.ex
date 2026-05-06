defmodule OctoPi.TUI.Keybindings do
  @moduledoc false

  alias OctoPi.TUI.Key

  defstruct bindings: %{}, definitions: %{}, conflicts: []

  @type conflict :: %{key: String.t(), bindings: [String.t()]}

  @type t :: %__MODULE__{
          bindings: %{String.t() => [String.t()]},
          definitions: %{String.t() => map()},
          conflicts: [conflict()]
        }

  @defaults %{
    "tui.editor.cursorUp" => %{keys: ["up"], description: "Move cursor up"},
    "tui.editor.cursorDown" => %{keys: ["down"], description: "Move cursor down"},
    "tui.editor.cursorLeft" => %{keys: ["left", "ctrl+b"], description: "Move cursor left"},
    "tui.editor.cursorRight" => %{keys: ["right", "ctrl+f"], description: "Move cursor right"},
    "tui.editor.cursorWordLeft" => %{
      keys: ["alt+left", "ctrl+left", "alt+b"],
      description: "Move cursor word left"
    },
    "tui.editor.cursorWordRight" => %{
      keys: ["alt+right", "ctrl+right", "alt+f"],
      description: "Move cursor word right"
    },
    "tui.editor.cursorLineStart" => %{
      keys: ["home", "ctrl+a"],
      description: "Move to line start"
    },
    "tui.editor.cursorLineEnd" => %{keys: ["end", "ctrl+e"], description: "Move to line end"},
    "tui.editor.pageUp" => %{keys: ["page_up"], description: "Page up"},
    "tui.editor.pageDown" => %{keys: ["page_down"], description: "Page down"},
    "tui.editor.deleteCharBackward" => %{
      keys: ["backspace"],
      description: "Delete character backward"
    },
    "tui.editor.deleteCharForward" => %{
      keys: ["delete", "ctrl+d"],
      description: "Delete character forward"
    },
    "tui.editor.deleteWordBackward" => %{
      keys: ["ctrl+w", "alt+backspace"],
      description: "Delete word backward"
    },
    "tui.editor.deleteWordForward" => %{
      keys: ["alt+d", "alt+delete"],
      description: "Delete word forward"
    },
    "tui.editor.deleteToLineStart" => %{keys: ["ctrl+u"], description: "Delete to line start"},
    "tui.editor.deleteToLineEnd" => %{keys: ["ctrl+k"], description: "Delete to line end"},
    "tui.editor.yank" => %{keys: ["ctrl+y"], description: "Yank"},
    "tui.editor.yankPop" => %{keys: ["alt+y"], description: "Yank pop"},
    "tui.editor.undo" => %{keys: ["ctrl+-"], description: "Undo"},
    "tui.input.newLine" => %{keys: ["shift+enter"], description: "Insert newline"},
    "tui.input.submit" => %{keys: ["enter"], description: "Submit input"},
    "tui.input.tab" => %{keys: ["tab"], description: "Tab / autocomplete"},
    "tui.input.copy" => %{keys: ["ctrl+c"], description: "Copy selection"},
    "tui.select.up" => %{keys: ["up"], description: "Move selection up"},
    "tui.select.down" => %{keys: ["down"], description: "Move selection down"},
    "tui.select.pageUp" => %{keys: ["page_up"], description: "Selection page up"},
    "tui.select.pageDown" => %{keys: ["page_down"], description: "Selection page down"},
    "tui.select.confirm" => %{keys: ["enter"], description: "Confirm selection"},
    "tui.select.cancel" => %{keys: ["escape", "ctrl+c"], description: "Cancel selection"},
    "app.interrupt" => %{keys: ["escape"], description: "Cancel/abort"},
    "app.clear" => %{keys: ["ctrl+c"], description: "Clear editor"},
    "app.exit" => %{keys: ["ctrl+d"], description: "Exit when editor is empty"},
    "app.suspend" => %{keys: ["ctrl+z"], description: "Suspend to shell"},
    "app.thinking.cycle" => %{keys: ["shift+tab"], description: "Cycle thinking level"},
    "app.model.cycleForward" => %{keys: ["ctrl+p"], description: "Next model"},
    "app.model.cycleBackward" => %{keys: ["shift+ctrl+p"], description: "Previous model"},
    "app.model.select" => %{keys: ["ctrl+l"], description: "Open model selector"},
    "app.tools.expand" => %{keys: ["ctrl+o"], description: "Toggle tool output expansion"},
    "app.thinking.toggle" => %{keys: ["ctrl+t"], description: "Toggle thinking block visibility"},
    "app.editor.external" => %{keys: ["ctrl+g"], description: "Open external editor"},
    "app.message.followUp" => %{keys: ["alt+enter"], description: "Queue follow-up message"},
    "app.message.dequeue" => %{keys: ["alt+up"], description: "Edit queued messages"},
    "app.clipboard.pasteImage" => %{keys: ["ctrl+v"], description: "Paste image from clipboard"},
    "app.tree.filter.default" => %{keys: ["ctrl+d"], description: "Tree filter: default view"},
    "app.tree.filter.noTools" => %{keys: ["ctrl+t"], description: "Tree filter: hide tool results"},
    "app.tree.filter.userOnly" => %{keys: ["ctrl+u"], description: "Tree filter: user messages only"},
    "app.tree.filter.labeledOnly" => %{keys: ["ctrl+l"], description: "Tree filter: labeled entries only"},
    "app.tree.filter.all" => %{keys: ["ctrl+a"], description: "Tree filter: show all entries"},
    "app.tree.filter.cycleForward" => %{keys: ["ctrl+o"], description: "Tree filter: cycle forward"},
    "app.tree.filter.cycleBackward" => %{keys: ["shift+ctrl+o"], description: "Tree filter: cycle backward"},
    "app.tree.toggleLabelTimestamp" => %{keys: ["shift+t"], description: "Tree: toggle label timestamps"}
  }

  @spec new(map()) :: t()
  def new(user_bindings \\ %{}) do
    build(@defaults, user_bindings)
  end

  @spec matches?(t(), Key.t(), String.t()) :: boolean()
  def matches?(%__MODULE__{bindings: bindings}, %Key{} = key, action) do
    key_id = Key.id(key)

    case Map.get(bindings, action) do
      nil -> false
      keys -> Enum.any?(keys, &(normalize_key_id(&1) == key_id))
    end
  end

  @spec get_keys(t(), String.t()) :: [String.t()]
  def get_keys(%__MODULE__{bindings: bindings}, action) do
    Map.get(bindings, action, [])
  end

  @spec conflicts(t()) :: [conflict()]
  def conflicts(%__MODULE__{conflicts: conflicts}), do: conflicts

  @spec set_user_bindings(t(), map()) :: t()
  def set_user_bindings(%__MODULE__{definitions: defs}, user_bindings) do
    build(defs, user_bindings)
  end

  defp build(definitions, user_bindings) do
    bindings =
      for {action, %{keys: default_keys}} <- definitions, into: %{} do
        keys =
          case Map.get(user_bindings, action) do
            nil -> default_keys
            override -> List.wrap(override)
          end

        {action, Enum.uniq(keys)}
      end

    conflicts = detect_conflicts(bindings, user_bindings, definitions)

    %__MODULE__{bindings: bindings, definitions: definitions, conflicts: conflicts}
  end

  @named_keys ~w(
    enter escape tab backspace delete space up down left right
    home end page_up page_down pageUp pageDown insert
    f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
  )

  defp normalize_named_key("pageUp"), do: "page_up"
  defp normalize_named_key("pageDown"), do: "page_down"
  defp normalize_named_key(k), do: k

  defp normalize_key_id(id) do
    parts = String.split(id, "+")
    {mod_parts, [key_part]} = Enum.split(parts, length(parts) - 1)

    normalized_key =
      if key_part in @named_keys do
        normalize_named_key(key_part)
      else
        case String.to_charlist(key_part) do
          [cp] -> Integer.to_string(cp)
          _ -> key_part
        end
      end

    case mod_parts do
      [] -> normalized_key
      mods -> Enum.join(Enum.sort(mods) ++ [normalized_key], "+")
    end
  end

  defp detect_conflicts(bindings, user_bindings, definitions) do
    user_actions = user_bindings |> Map.keys() |> MapSet.new()

    bindings
    |> Enum.filter(fn {action, _} ->
      MapSet.member?(user_actions, action) and Map.has_key?(definitions, action)
    end)
    |> Enum.flat_map(fn {action, keys} ->
      Enum.map(keys, &{&1, action})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_key, actions} -> length(actions) > 1 end)
    |> Enum.map(fn {key, actions} -> %{key: key, bindings: Enum.sort(actions)} end)
  end
end
