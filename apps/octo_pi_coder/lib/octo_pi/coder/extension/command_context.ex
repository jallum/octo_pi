defmodule OctoPi.Coder.Extension.CommandContext do
  @moduledoc false

  alias OctoPi.Coder.Extension.Context

  @type t :: %__MODULE__{
          base: Context.t(),
          wait_for_idle: (-> :ok),
          new_session: ((t() -> :ok) -> :ok),
          fork: (String.t(), keyword() -> :ok),
          navigate_tree: (String.t(), keyword() -> :ok),
          switch_session: (String.t() -> :ok),
          reload: (-> :ok)
        }

  @session_actions [:wait_for_idle, :new_session, :fork, :navigate_tree, :switch_session, :reload]

  defstruct [:base | @session_actions]

  @spec new(Context.t()) :: t()
  def new(%Context{} = base) do
    stubs =
      Map.new(@session_actions, fn
        :wait_for_idle -> {:wait_for_idle, stub(:wait_for_idle, 0)}
        :reload -> {:reload, stub(:reload, 0)}
        :new_session -> {:new_session, stub(:new_session, 1)}
        :switch_session -> {:switch_session, stub(:switch_session, 1)}
        :fork -> {:fork, stub(:fork, 2)}
        :navigate_tree -> {:navigate_tree, stub(:navigate_tree, 2)}
      end)

    struct!(__MODULE__, Map.put(stubs, :base, base))
  end

  @spec bind(t(), map()) :: t()
  def bind(%__MODULE__{} = ctx, actions) do
    Enum.reduce(@session_actions, ctx, fn field, ctx ->
      case Map.get(actions, field) do
        nil -> ctx
        fun -> Map.put(ctx, field, fun)
      end
    end)
  end

  defp stub(field, 0),
    do: fn -> raise RuntimeError, "#{field} not bound — interactive mode only" end

  defp stub(field, 1),
    do: fn _ -> raise RuntimeError, "#{field} not bound — interactive mode only" end

  defp stub(field, 2),
    do: fn _, _ -> raise RuntimeError, "#{field} not bound — interactive mode only" end
end
