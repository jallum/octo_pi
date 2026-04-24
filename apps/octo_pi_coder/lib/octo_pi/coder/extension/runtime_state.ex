defmodule OctoPi.Coder.Extension.RuntimeState do
  @moduledoc false

  @type t :: %__MODULE__{
          active?: boolean(),
          invalidation_message: String.t() | nil,
          flag_values: %{String.t() => term()}
        }

  defstruct active?: true,
            invalidation_message: nil,
            flag_values: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec assert_active!(t()) :: :ok
  def assert_active!(%__MODULE__{active?: true}), do: :ok

  def assert_active!(%__MODULE__{active?: false, invalidation_message: msg}) do
    raise RuntimeError, "Extension instance is stale: #{msg || "invalidated"}"
  end

  @spec invalidate(t(), String.t() | nil) :: t()
  def invalidate(%__MODULE__{} = state, message \\ nil) do
    %{state | active?: false, invalidation_message: message}
  end

  @spec set_flag(t(), String.t(), term()) :: t()
  def set_flag(%__MODULE__{} = state, key, value) do
    %{state | flag_values: Map.put(state.flag_values, key, value)}
  end

  @spec get_flag(t(), String.t(), term()) :: term()
  def get_flag(%__MODULE__{flag_values: flags}, key, default \\ nil) do
    Map.get(flags, key, default)
  end
end
