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
    * `:shifted_key` — the codepoint the user actually typed (e.g. `?!`
      for shift+1) when the terminal reports it via Kitty CSI-u flag 4.
      `nil` when not reported (modifyOtherKeys, legacy CSI, etc.). Use
      this for *insertion* into text inputs; leave `:key` + `:shift`
      modifier alone for *binding* matches.
  """

  @type modifier :: :ctrl | :shift | :alt | :super
  @type event_type :: :press | :repeat | :release

  @type t :: %__MODULE__{
          key: atom() | non_neg_integer(),
          modifiers: [modifier()],
          event_type: event_type(),
          shifted_key: non_neg_integer() | nil
        }

  @enforce_keys [:key]
  defstruct key: nil, modifiers: [], event_type: :press, shifted_key: nil

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

  @named_keys ~w(
    enter escape tab backspace delete space up down left right
    home end pageUp pageDown insert clear
    f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
  )

  @doc """
  Test whether this `Key` satisfies a binding string like
  `"ctrl+c"`, `"ctrl+shift+p"`, or `"enter"`.

  Comparison is case-insensitive on the key token; modifier order
  in the binding does not matter. Named keys (`"enter"`, `"up"`,
  `"f1"`, …) match against the atom `:enter` / `:up` / `:f1`;
  single-character tokens match against their codepoint.

  Layout-aware matching relies on the key parser having already
  resolved non-Latin codepoints to their Latin base (see
  `OctoPi.TUI.Terminal.KeyParser` Kitty CSI-u alternate-key handling), so
  this function does not need to re-resolve layouts.
  """
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{} = key, binding) do
    {b_mods, b_key_token} = parse_binding(binding)
    b_key_matches?(key.key, b_key_token) and Enum.sort(key.modifiers) == Enum.sort(b_mods)
  end

  defp parse_binding(binding) do
    parts = binding |> String.trim() |> String.downcase() |> String.split("+", trim: true)
    {mods, [token]} = Enum.split(parts, length(parts) - 1)
    {Enum.map(mods, &parse_modifier/1), token}
  end

  defp parse_modifier("ctrl"), do: :ctrl
  defp parse_modifier("alt"), do: :alt
  defp parse_modifier("shift"), do: :shift
  defp parse_modifier("super"), do: :super
  defp parse_modifier(other), do: String.to_atom(other)

  defp b_key_matches?(k, token) when is_atom(k) do
    Atom.to_string(k) == normalize_token(token)
  end

  defp b_key_matches?(k, token) when is_integer(k) do
    # Named-key token cannot match a codepoint key.
    if token in @named_keys do
      false
    else
      case String.to_charlist(token) do
        [cp] -> k == cp
        _ -> Integer.to_string(k) == token
      end
    end
  end

  defp normalize_token("pageup"), do: "pageUp"
  defp normalize_token("pagedown"), do: "pageDown"
  defp normalize_token(t), do: t
end
