defmodule OctoPi.Coder.Extension do
  @moduledoc false

  alias OctoPi.Coder.Extension.Event

  @type handler_fn :: (map(), OctoPi.Coder.Extension.Context.t() -> term())

  @type command_spec :: %{
          description: String.t(),
          handler: (term() -> term())
        }

  @type message_renderer :: (String.t(), term() -> String.t())

  @type flag_spec :: %{
          name: String.t(),
          description: String.t(),
          default: term()
        }

  @type shortcut_spec :: %{
          key: String.t(),
          description: String.t(),
          handler: (term() -> term())
        }

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          handlers: %{Event.event_type() => [handler_fn()]},
          tools: %{String.t() => map()},
          commands: %{String.t() => command_spec()},
          message_renderers: %{String.t() => message_renderer()},
          flags: %{String.t() => flag_spec()},
          shortcuts: %{String.t() => shortcut_spec()}
        }

  defstruct id: nil,
            path: nil,
            handlers: %{},
            tools: %{},
            commands: %{},
            message_renderers: %{},
            flags: %{},
            shortcuts: %{}

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

  @spec add_message_renderer(t(), String.t(), message_renderer()) :: t()
  def add_message_renderer(%__MODULE__{} = ext, type, renderer)
      when is_binary(type) and is_function(renderer, 2) do
    put_in(ext.message_renderers[type], renderer)
  end

  @spec add_flag(t(), String.t(), flag_spec()) :: t()
  def add_flag(%__MODULE__{} = ext, name, spec) when is_binary(name) do
    put_in(ext.flags[name], spec)
  end

  @spec add_shortcut(t(), String.t(), shortcut_spec()) :: t()
  def add_shortcut(%__MODULE__{} = ext, key, spec) when is_binary(key) do
    put_in(ext.shortcuts[key], spec)
  end
end
