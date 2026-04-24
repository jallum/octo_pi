defmodule OctoPi.Coder.Extension do
  @moduledoc false

  alias OctoPi.Coder.Extension.Event

  @type handler_fn :: (event :: map(), context :: OctoPi.Coder.Extension.Context.t() -> term())

  @type command_spec :: %{
          description: String.t(),
          handler: (term() -> term())
        }

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          handlers: %{Event.event_type() => [handler_fn()]},
          tools: %{String.t() => map()},
          commands: %{String.t() => command_spec()}
        }

  defstruct id: nil,
            path: nil,
            handlers: %{},
            tools: %{},
            commands: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(id, path), do: %__MODULE__{id: id, path: path}

  @spec add_handler(t(), Event.event_type(), handler_fn()) :: t()
  def add_handler(%__MODULE__{} = ext, event_type, handler) when is_function(handler, 2) do
    unless Event.valid?(event_type),
      do: raise(ArgumentError, "unknown event type: #{inspect(event_type)}")

    update_in(ext.handlers[event_type], fn
      nil -> [handler]
      existing -> existing ++ [handler]
    end)
  end

  @spec get_handlers(t(), Event.event_type()) :: [handler_fn()]
  def get_handlers(%__MODULE__{handlers: handlers}, event_type) do
    Map.get(handlers, event_type, [])
  end

  @spec add_tool(t(), map()) :: t()
  def add_tool(%__MODULE__{} = ext, %{name: name} = tool) do
    put_in(ext.tools[name], tool)
  end

  @spec add_command(t(), String.t(), command_spec()) :: t()
  def add_command(%__MODULE__{} = ext, name, command) when is_binary(name) do
    put_in(ext.commands[name], command)
  end
end
