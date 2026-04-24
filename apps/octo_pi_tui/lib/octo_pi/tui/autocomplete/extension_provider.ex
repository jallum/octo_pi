defmodule OctoPi.TUI.Autocomplete.ExtensionProvider do
  @moduledoc false

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.{CombinedProvider, Suggestion}

  @type t :: %__MODULE__{suggest_fn: (String.t() -> [String.t()])}
  defstruct [:suggest_fn]

  @behaviour Autocomplete

  @spec new((String.t() -> [String.t()])) :: t()
  def new(suggest_fn) when is_function(suggest_fn, 1) do
    %__MODULE__{suggest_fn: suggest_fn}
  end

  @impl true
  def get_suggestions(%__MODULE__{suggest_fn: fun}, input) do
    results = fun.(input)

    suggestions =
      Enum.map(results, fn
        %Suggestion{} = s -> s
        label when is_binary(label) -> %Suggestion{label: label, value: label}
      end)

    {:ok, suggestions}
  end

  @spec add_provider(struct() | nil, struct()) :: CombinedProvider.t()
  def add_provider(nil, provider), do: CombinedProvider.new([provider])

  def add_provider(%CombinedProvider{providers: providers}, provider) do
    CombinedProvider.new(providers ++ [provider])
  end

  def add_provider(existing, provider) do
    CombinedProvider.new([existing, provider])
  end
end
