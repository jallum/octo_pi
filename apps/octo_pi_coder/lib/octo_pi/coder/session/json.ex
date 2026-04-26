defmodule OctoPi.Coder.Session.JSON do
  @moduledoc """
  Ordered JSON object encoder used by `Header` and `Entry.*` modules to
  preserve key order on the wire (byte-compatible with upstream `pi`).

  Each encodable struct exposes a `pairs/1` returning a list of
  `{json_key, value}` pairs in the desired emit order. `object/1` walks
  that list and assembles the JSON object directly so map ordering
  cannot perturb the output.
  """

  @spec object([{String.t(), term()}]) :: String.t()
  def object(pairs) when is_list(pairs) do
    inner =
      Enum.map_join(pairs, ",", fn {k, v} ->
        Jason.encode!(k) <> ":" <> Jason.encode!(v)
      end)

    "{" <> inner <> "}"
  end

  @doc """
  Append `{key, value}` to `pairs` only when `value` is not nil.
  Used for encoding TS `?` optional fields, which JSON.stringify omits.
  """
  @spec maybe_put([{String.t(), term()}], String.t(), term()) :: [{String.t(), term()}]
  def maybe_put(pairs, _key, nil), do: pairs
  def maybe_put(pairs, key, value), do: pairs ++ [{key, value}]
end
