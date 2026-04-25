defmodule OctoPi.Coder.Extensions.DynamicTools do
  @moduledoc """
  Demonstrates registering tools after session initialization.

  Uses `api.register_tool` (bound via `bind_core`) to add tools to the live
  session at runtime from command handlers, matching the upstream behaviour
  where `pi.registerTool()` can be called at any time.

  An internal registry tracks registered names for dedup. `echo_session` is
  registered both statically at init (via `API.register_tool/2`) and into the
  internal registry, so `/add-echo-tool echo_session` returns a duplicate warning.
  Ported from examples/extensions/dynamic-tools.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    {:ok, registry} = Agent.start_link(fn -> MapSet.new(["echo_session"]) end)

    register_tool_fn = api.register_tool

    {:ok, api} = API.register_tool(api, echo_spec("echo_session", "[session] "))
    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> on_session_start(ctx) end)

    API.register_command(api, "add-echo-tool", %{
      description: "Register a new echo tool dynamically: /add-echo-tool <tool_name>",
      handler: fn args, _ctx -> add_echo_tool(args, registry, register_tool_fn) end
    })
  end

  defp echo_spec(name, prefix) do
    %{
      name: name,
      label: "Echo #{String.capitalize(name)}",
      description: "Echo a message with prefix: #{prefix}",
      prompt_snippet: "Echo back user-provided text with #{String.trim(prefix)} prefix",
      prompt_guidelines: ["Use #{name} when the user asks for exact echo output."],
      parameters: %{
        type: :object,
        properties: %{message: %{type: :string, description: "Message to echo"}},
        required: ["message"]
      },
      execute: fn args ->
        %{
          content: [%{type: "text", text: "#{prefix}#{args["message"]}"}],
          details: %{tool: name, prefix: prefix}
        }
      end
    }
  end

  defp on_session_start(%{has_ui?: true, ui: ui}) do
    ui.notify.("Registered dynamic tool: echo_session")
    :ok
  end

  defp on_session_start(_ctx), do: :ok

  defp add_echo_tool(args, registry, register_tool_fn) do
    case normalize_name(args) do
      nil ->
        "Usage: /add-echo-tool <tool_name> (lowercase, numbers, underscores only)"

      name ->
        register_dynamic_tool(name, registry, register_tool_fn)
    end
  end

  defp normalize_name(input) do
    trimmed = input |> String.trim() |> String.downcase()

    if trimmed != "" and String.match?(trimmed, ~r/^[a-z0-9_]+$/),
      do: trimmed
  end

  defp register_dynamic_tool(name, registry, register_tool_fn) do
    if MapSet.member?(Agent.get(registry, & &1), name) do
      "Tool already registered: #{name}"
    else
      Agent.update(registry, &MapSet.put(&1, name))
      register_tool_fn.(echo_spec(name, "[#{name}] "))
      "Registered dynamic tool: #{name}"
    end
  end
end
