defmodule OctoPi.TUI.Autocomplete do
  @moduledoc false

  alias OctoPi.TUI.Autocomplete.Suggestion

  defmodule SlashCommand do
    @moduledoc false
    @enforce_keys [:name]
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            argument_hint: String.t() | nil
          }
    defstruct [:name, :description, :argument_hint]
  end

  @callback get_suggestions(provider :: struct(), input :: String.t()) ::
              {:ok, [Suggestion.t()]}

  @spec get_suggestions(struct(), String.t()) :: {:ok, [Suggestion.t()]}
  def get_suggestions(%mod{} = provider, input), do: mod.get_suggestions(provider, input)

  @spec builtin_commands() :: [SlashCommand.t()]
  def builtin_commands do
    [
      %SlashCommand{name: "help", description: "Show available commands and key bindings"},
      %SlashCommand{name: "clear", description: "Clear the conversation"},
      %SlashCommand{name: "compact", description: "Compact conversation context"},
      %SlashCommand{name: "cost", description: "Show token usage and costs"},
      %SlashCommand{name: "login", description: "Configure provider authentication"},
      %SlashCommand{name: "model", description: "Switch the active model"},
      %SlashCommand{name: "sessions", description: "Show recent sessions"},
      %SlashCommand{name: "settings", description: "Open settings menu"},
      %SlashCommand{name: "scoped-models", description: "Enable/disable models for Ctrl+P cycling"},
      %SlashCommand{name: "export", description: "Export session to HTML or JSON"},
      %SlashCommand{name: "import", description: "Import and resume a session from JSON"},
      %SlashCommand{name: "theme", description: "Switch the color theme"},
      %SlashCommand{name: "tree", description: "Show conversation tree"},
      %SlashCommand{name: "continue", description: "Continue the last agent action"},
      %SlashCommand{name: "config", description: "Show current configuration"},
      %SlashCommand{name: "session", description: "Show current session info and stats"},
      %SlashCommand{name: "copy", description: "Copy last agent message to clipboard"},
      %SlashCommand{name: "name", description: "Set or show the session display name"},
      %SlashCommand{name: "new", description: "Start a new session"},
      %SlashCommand{name: "quit", description: "Quit the app"},
      %SlashCommand{name: "changelog", description: "Show changelog entries"},
      %SlashCommand{name: "hotkeys", description: "Show keyboard shortcuts"},
      %SlashCommand{name: "resume", description: "Browse and resume a previous session"},
      %SlashCommand{name: "fork", description: "Fork session at a prior user message"},
      %SlashCommand{name: "clone", description: "Clone session at current position"},
      %SlashCommand{name: "logout", description: "Remove stored credentials for a provider"},
      %SlashCommand{name: "reload", description: "Reload keybindings and configuration"},
      %SlashCommand{name: "share", description: "Share session as a GitHub Gist"}
    ]
  end
end
