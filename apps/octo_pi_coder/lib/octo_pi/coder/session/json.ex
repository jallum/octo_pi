defmodule OctoPi.Coder.Session.JSON do
  @moduledoc """
  Ordered JSON object encoder used by `Header` and `Entry.*` modules to
  preserve key order on the wire (byte-compatible with upstream `pi`).

  Each encodable struct exposes a `pairs/1` returning a list of
  `{json_key, value}` pairs in the desired emit order. `object/1`
  wraps that list in `Jason.OrderedObject` so Jason emits the keys
  exactly in list order — its built-in mechanism for ordered objects.
  """

  @spec object([{String.t(), term()}]) :: String.t()
  def object(pairs) when is_list(pairs), do: pairs |> Jason.OrderedObject.new() |> Jason.encode!()

  @doc """
  Append `{key, value}` to `pairs` only when `value` is not nil.
  Used for encoding TS `?` optional fields, which JSON.stringify omits.
  """
  @spec maybe_put([{String.t(), term()}], String.t(), term()) :: [{String.t(), term()}]
  def maybe_put(pairs, _key, nil), do: pairs
  def maybe_put(pairs, key, value), do: pairs ++ [{key, value}]

  @doc """
  Capture every key in `map` not present in `known_keys` into a plain
  string-keyed map. Used by entry decoders to preserve unknown wire
  fields so a decode → encode → decode cycle is lossless even when
  the source file mixes session versions or carries fields this port
  has not yet modelled.
  """
  @spec extras(map(), [String.t()]) :: %{optional(String.t()) => term()}
  def extras(map, known_keys) when is_map(map) and is_list(known_keys) do
    known = MapSet.new(known_keys)
    Map.reject(map, fn {k, _v} -> MapSet.member?(known, k) end)
  end

  @doc """
  Append captured `extras` to `pairs`, emitted in alphabetical key
  order so the wire output is deterministic. Empty extras pass through
  untouched.
  """
  @spec append_extras([{String.t(), term()}], map()) :: [{String.t(), term()}]
  def append_extras(pairs, extras) when extras == %{}, do: pairs

  def append_extras(pairs, extras) when is_map(extras), do: pairs ++ Enum.sort_by(extras, fn {k, _} -> k end)
end
