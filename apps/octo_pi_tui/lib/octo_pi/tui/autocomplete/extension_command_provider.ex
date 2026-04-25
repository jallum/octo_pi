defmodule OctoPi.TUI.Autocomplete.ExtensionCommandProvider do
  @moduledoc false

  @behaviour OctoPi.TUI.Autocomplete

  alias OctoPi.TUI.Autocomplete.Suggestion

  @type t :: %__MODULE__{
          commands: [{String.t(), map(), String.t()}],
          conflicts: [{String.t(), String.t()}]
        }

  defstruct commands: [], conflicts: []

  @spec new([{String.t(), map(), String.t()}], MapSet.t()) :: t()
  def new(commands, builtin_names) do
    {conflicts, kept} =
      Enum.split_with(commands, fn {name, _spec, _ext_id} ->
        MapSet.member?(builtin_names, name)
      end)

    conflict_pairs = Enum.map(conflicts, fn {name, _spec, ext_id} -> {name, ext_id} end)

    %__MODULE__{commands: kept, conflicts: conflict_pairs}
  end

  @impl true
  def get_suggestions(%__MODULE__{commands: commands}, "/" <> prefix) do
    suggestions =
      commands
      |> Enum.filter(fn {name, _spec, _ext_id} -> String.starts_with?(name, prefix) end)
      |> Enum.map(fn {name, spec, _ext_id} ->
        %Suggestion{
          label: "/#{name}",
          value: "/#{name}",
          description: Map.get(spec, :description)
        }
      end)

    {:ok, suggestions}
  end

  def get_suggestions(%__MODULE__{}, _input), do: {:ok, []}
end
