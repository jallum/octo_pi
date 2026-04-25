defmodule OctoPi.Coder.Extension.API do
  @moduledoc false

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.ProviderConfig

  @type events :: %{
          emit: (String.t(), term() -> :ok),
          on: (String.t(), (term() -> term()) -> (-> :ok))
        }

  @type t :: %__MODULE__{
          extension_id: String.t(),
          registered_handlers: [{Event.event_type(), Extension.handler_fn()}],
          registered_tools: [map()],
          registered_commands: [{String.t(), map()}],
          events: events(),
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
          register_tool: (map() -> :ok),
          exec: (String.t(), [String.t()] -> term()),
          get_commands: (-> [map()]),
          get_context_usage: (-> map() | nil)
        }

  @one_arity_actions [
    :send_message,
    :send_user_message,
    :append_entry,
    :set_model,
    :set_thinking_level,
    :compact,
    :set_active_tools,
    :set_session_name,
    :set_label,
    :register_tool
  ]

  @zero_arity_actions [
    :get_model,
    :get_thinking_level,
    :abort,
    :get_system_prompt,
    :get_active_tools,
    :get_all_tools,
    :get_session_name,
    :get_commands,
    :get_context_usage
  ]

  @two_arity_actions [:exec]

  @action_fields @one_arity_actions ++ @zero_arity_actions ++ @two_arity_actions

  defstruct [
              :extension_id,
              registered_handlers: [],
              registered_tools: [],
              registered_commands: [],
              registered_renderers: [],
              registered_flags: [],
              registered_shortcuts: [],
              pending_providers: [],
              bound?: false,
              events: nil
            ] ++ Enum.map(@action_fields, &{&1, nil})

  @spec new(String.t()) :: t()
  def new(extension_id) do
    one_stubs = Map.new(@one_arity_actions, fn f -> {f, stub(f, 1)} end)
    zero_stubs = Map.new(@zero_arity_actions, fn f -> {f, stub(f, 0)} end)
    two_stubs = Map.new(@two_arity_actions, fn f -> {f, stub(f, 2)} end)

    attrs =
      one_stubs
      |> Map.merge(zero_stubs)
      |> Map.merge(two_stubs)
      |> Map.put(:extension_id, extension_id)
      |> Map.put(:events, events_stub())

    struct!(__MODULE__, attrs)
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

  @spec register_message_renderer(t(), String.t(), Extension.message_renderer()) :: {:ok, t()}
  def register_message_renderer(%__MODULE__{} = api, type, renderer)
      when is_binary(type) and is_function(renderer, 2) do
    {:ok, %{api | registered_renderers: api.registered_renderers ++ [{type, renderer}]}}
  end

  @spec register_flag(t(), String.t(), Extension.flag_spec()) :: {:ok, t()}
  def register_flag(%__MODULE__{} = api, name, spec) when is_binary(name) do
    {:ok, %{api | registered_flags: api.registered_flags ++ [{name, spec}]}}
  end

  @spec register_shortcut(t(), String.t(), Extension.shortcut_spec()) :: {:ok, t()}
  def register_shortcut(%__MODULE__{} = api, key, spec) when is_binary(key) do
    {:ok, %{api | registered_shortcuts: api.registered_shortcuts ++ [{key, spec}]}}
  end

  @spec register_provider(t(), ProviderConfig.t()) :: {:ok, t()} | {:error, String.t()}
  def register_provider(%__MODULE__{bound?: false} = api, %ProviderConfig{} = config) do
    {:ok, %{api | pending_providers: api.pending_providers ++ [{:register, config}]}}
  end

  def register_provider(%__MODULE__{bound?: true} = _api, %ProviderConfig{} = _config) do
    {:error, "register_provider after bind_core not yet implemented — use pending queue"}
  end

  @spec unregister_provider(t(), String.t()) :: {:ok, t()}
  def unregister_provider(%__MODULE__{bound?: false} = api, provider_id) when is_binary(provider_id) do
    {:ok, %{api | pending_providers: api.pending_providers ++ [{:unregister, provider_id}]}}
  end

  @spec pending_providers(t()) :: [{:register, ProviderConfig.t()} | {:unregister, String.t()}]
  def pending_providers(%__MODULE__{} = api), do: api.pending_providers

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

    ext =
      Enum.reduce(api.registered_commands, ext, fn {name, cmd}, ext ->
        Extension.add_command(ext, name, cmd)
      end)

    ext =
      Enum.reduce(api.registered_renderers, ext, fn {type, renderer}, ext ->
        Extension.add_message_renderer(ext, type, renderer)
      end)

    ext =
      Enum.reduce(api.registered_flags, ext, fn {name, spec}, ext ->
        Extension.add_flag(ext, name, spec)
      end)

    Enum.reduce(api.registered_shortcuts, ext, fn {key, spec}, ext ->
      Extension.add_shortcut(ext, key, spec)
    end)
  end

  @spec bind_core(t(), map()) :: t()
  def bind_core(%__MODULE__{} = api, actions) do
    api =
      Enum.reduce(@action_fields, api, fn field, api ->
        case Map.get(actions, field) do
          nil -> api
          fun -> Map.put(api, field, fun)
        end
      end)

    api =
      case Map.get(actions, :events) do
        nil -> api
        events -> %{api | events: events}
      end

    %{api | bound?: true}
  end

  defp stub(field, 0), do: fn -> raise RuntimeError, "#{field} not bound — call bind_core first" end

  defp stub(field, 1), do: fn _ -> raise RuntimeError, "#{field} not bound — call bind_core first" end

  defp stub(field, 2), do: fn _, _ -> raise RuntimeError, "#{field} not bound — call bind_core first" end

  defp events_stub do
    %{
      emit: fn _, _ -> raise RuntimeError, "events not bound — call bind_core first" end,
      on: fn _, _ -> raise RuntimeError, "events not bound — call bind_core first" end
    }
  end
end
