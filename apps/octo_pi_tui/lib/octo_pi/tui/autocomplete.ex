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
      %SlashCommand{name: "model", description: "Switch the active model"},
      %SlashCommand{name: "theme", description: "Switch the color theme"},
      %SlashCommand{name: "config", description: "Show current configuration"}
    ]
  end
end
