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
          send_user_message: (String.t() -> :ok),
          append_entry: (map() -> :ok),
          get_model: (-> term()),
          set_model: (term() -> :ok),
          get_thinking_level: (-> String.t() | nil),
          set_thinking_level: (String.t() -> :ok),
          abort: (-> :ok),
          compact: (keyword() -> :ok),
          get_system_prompt: (-> String.t()),
          get_active_tools: (-> [map()]),
          get_all_tools: (-> [map()]),
          set_active_tools: ([String.t()] -> :ok),
          get_session_name: (-> String.t() | nil),
          set_session_name: (String.t() -> :ok),
          set_label: (String.t() -> :ok),
          exec: (String.t(), map() -> term()),
          get_commands: (-> [map()])
        }

  @one_arity_actions [
    :send_message, :send_user_message, :append_entry,
    :set_model, :set_thinking_level,
    :compact, :set_active_tools,
    :set_session_name, :set_label
  ]

  @zero_arity_actions [
    :get_model, :get_thinking_level, :abort, :get_system_prompt,
    :get_active_tools, :get_all_tools, :get_session_name, :get_commands
  ]

  @two_arity_actions [:exec]

  @action_fields @one_arity_actions ++ @zero_arity_actions ++ @two_arity_actions

  defstruct [
    :extension_id,
    registered_handlers: [],
    registered_tools: [],
    registered_commands: []
  ] ++ Enum.map(@action_fields, &{&1, nil})

  @spec new(String.t()) :: t()
  def new(extension_id) do
    one_stubs = Map.new(@one_arity_actions, fn f -> {f, stub(f, 1)} end)
    zero_stubs = Map.new(@zero_arity_actions, fn f -> {f, stub(f, 0)} end)
    two_stubs = Map.new(@two_arity_actions, fn f -> {f, stub(f, 2)} end)

    attrs = Map.merge(one_stubs, zero_stubs) |> Map.merge(two_stubs)
    struct!(__MODULE__, Map.put(attrs, :extension_id, extension_id))
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

  defp stub(field, 0), do: fn -> raise RuntimeError, "#{field} not bound — call bind_core first" end
  defp stub(field, 1), do: fn _ -> raise RuntimeError, "#{field} not bound — call bind_core first" end
  defp stub(field, 2), do: fn _, _ -> raise RuntimeError, "#{field} not bound — call bind_core first" end
end
