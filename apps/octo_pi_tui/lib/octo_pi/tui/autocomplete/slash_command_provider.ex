defmodule OctoPi.TUI.Autocomplete.SlashCommandProvider do
  @moduledoc false

  @behaviour OctoPi.TUI.Autocomplete

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.Suggestion

  @type t :: %__MODULE__{commands: [Autocomplete.SlashCommand.t()]}
  defstruct commands: []

  @spec new([Autocomplete.SlashCommand.t()]) :: t()
  def new(commands), do: %__MODULE__{commands: commands}

  @impl true
  def get_suggestions(%__MODULE__{commands: commands}, "/" <> prefix) do
    suggestions =
      commands
      |> Enum.filter(&String.starts_with?(&1.name, prefix))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn cmd ->
        %Suggestion{
          label: "/#{cmd.name}",
          value: "/#{cmd.name}",
          description: cmd.description
        }
      end)

    {:ok, suggestions}
  end

  def get_suggestions(%__MODULE__{}, _input), do: {:ok, []}
end
