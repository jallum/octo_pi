defmodule OctoPi.Coder.Extension.API do
  @moduledoc false

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Event

  @type t :: %__MODULE__{
          extension_id: String.t(),
          registered_handlers: [{Event.event_type(), Extension.handler_fn()}],
          registered_tools: [map()],
          registered_commands: [{String.t(), map()}],
          send_message: (String.t() -> :ok),
          get_model: (-> term()),
          set_model: (term() -> :ok),
          get_thinking_level: (-> String.t() | nil),
          set_thinking_level: (String.t() -> :ok),
          abort: (-> :ok),
          compact: (keyword() -> :ok),
          get_system_prompt: (-> String.t()),
          get_active_tools: (-> [map()]),
          set_active_tools: ([String.t()] -> :ok)
        }

  defstruct extension_id: nil,
            registered_handlers: [],
            registered_tools: [],
            registered_commands: [],
            send_message: nil,
            get_model: nil,
            set_model: nil,
            get_thinking_level: nil,
            set_thinking_level: nil,
            abort: nil,
            compact: nil,
            get_system_prompt: nil,
            get_active_tools: nil,
            set_active_tools: nil

  @action_fields [
    :send_message, :get_model, :set_model, :get_thinking_level,
    :set_thinking_level, :abort, :compact, :get_system_prompt,
    :get_active_tools, :set_active_tools
  ]

  @spec new(String.t()) :: t()
  def new(extension_id) do
    stubs =
      Map.new(@action_fields, fn field ->
        {field, fn _ -> raise RuntimeError, "#{field} not bound — call bind_core first" end}
      end)

    struct!(__MODULE__, Map.put(stubs, :extension_id, extension_id))
    |> fix_arity_stubs()
  end

  @spec on(t(), Event.event_type(), Extension.handler_fn()) :: {:ok, t()} | {:error, String.t()}
  def on(%__MODULE__{} = api, event_type, handler) when is_function(handler, 2) do
    if Event.valid?(event_type) do
      {:ok, %{api | registered_handlers: api.registered_handlers ++ [{event_type, handler}]}}
    else
      {:error, "unknown event type: #{inspect(event_type)}"}
    end
  end

  @spec register_tool(t(), map()) :: {:ok, t()}
  def register_tool(%__MODULE__{} = api, %{name: _} = tool) do
    {:ok, %{api | registered_tools: api.registered_tools ++ [tool]}}
  end

  @spec register_command(t(), String.t(), map()) :: {:ok, t()}
  def register_command(%__MODULE__{} = api, name, command) when is_binary(name) do
    {:ok, %{api | registered_commands: api.registered_commands ++ [{name, command}]}}
  end

  @spec build_extension(t(), String.t()) :: Extension.t()
  def build_extension(%__MODULE__{} = api, path) do
    ext = Extension.new(api.extension_id, path)

    ext =
      Enum.reduce(api.registered_handlers, ext, fn {event_type, handler}, ext ->
        Extension.add_handler(ext, event_type, handler)
      end)

    ext =
      Enum.reduce(api.registered_tools, ext, fn tool, ext ->
        Extension.add_tool(ext, tool)
      end)

    Enum.reduce(api.registered_commands, ext, fn {name, cmd}, ext ->
      Extension.add_command(ext, name, cmd)
    end)
  end

  @spec bind_core(t(), map()) :: t()
  def bind_core(%__MODULE__{} = api, actions) do
    Enum.reduce(@action_fields, api, fn field, api ->
      case Map.get(actions, field) do
        nil -> api
        fun -> Map.put(api, field, fun)
      end
    end)
  end

  defp fix_arity_stubs(api) do
    zero_arity = [:get_model, :get_thinking_level, :abort, :get_system_prompt, :get_active_tools]

    Enum.reduce(zero_arity, api, fn field, api ->
      Map.put(api, field, fn -> raise RuntimeError, "#{field} not bound — call bind_core first" end)
    end)
  end
end
