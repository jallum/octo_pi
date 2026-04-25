defmodule OctoPi.TUI.Autocomplete.CombinedProvider do
  @moduledoc false

  @behaviour OctoPi.TUI.Autocomplete

  alias OctoPi.TUI.Autocomplete

  @type t :: %__MODULE__{providers: [struct()]}
  defstruct providers: []

  @spec new([struct()]) :: t()
  def new(providers), do: %__MODULE__{providers: providers}

  @impl true
  def get_suggestions(%__MODULE__{providers: providers}, input) do
    suggestions =
      providers
      |> Enum.flat_map(fn provider ->
        {:ok, items} = Autocomplete.get_suggestions(provider, input)
        items
      end)
      |> Enum.uniq_by(& &1.value)

    {:ok, suggestions}
  end
end
