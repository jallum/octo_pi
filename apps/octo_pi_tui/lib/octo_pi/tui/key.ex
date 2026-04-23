defmodule OctoPi.TUI.Key do
  @moduledoc """
  A parsed keyboard event.

    * `:key` — named keys are atoms (`:up`, `:enter`, `:f1`, etc.);
      printable keys are codepoint integers (e.g. `?a == 97`) so
      they pattern-match cleanly alongside modifier combinations.
    * `:modifiers` — list of `:ctrl | :shift | :alt | :super`,
      sorted alphabetically for stable equality.
    * `:event_type` — `:press | :repeat | :release`. `:press` for
      non-Kitty sources; Kitty CSI-u with flag 2 reports the full set.
  """

  @type modifier :: :ctrl | :shift | :alt | :super
  @type event_type :: :press | :repeat | :release

  @type t :: %__MODULE__{
          key: atom() | non_neg_integer(),
          modifiers: [modifier()],
          event_type: event_type()
        }

  @enforce_keys [:key]
  defstruct key: nil, modifiers: [], event_type: :press

  @doc """
  Render a `Key` as a stable string id (e.g. `"ctrl+97"`, `"up"`)
  for lookup in keybinding tables.
  """
  @spec id(t()) :: String.t()
  def id(%__MODULE__{key: k, modifiers: []}), do: key_name(k)

  def id(%__MODULE__{key: k, modifiers: mods}),
    do: Enum.map_join(Enum.sort(mods), "+", &Atom.to_string/1) <> "+" <> key_name(k)

  defp key_name(k) when is_atom(k), do: Atom.to_string(k)
  defp key_name(k) when is_integer(k), do: Integer.to_string(k)
end
