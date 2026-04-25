defmodule OctoPi.Coder.Extensions.DynamicTools do
  @moduledoc """
  Demonstrates registering tools after session initialization.

  Registers echo_session at init time and provides /add-echo-tool to track
  additional echo tool names at runtime. Full dynamic addition to the extension
  struct is not supported in the Elixir architecture (extensions are immutable
  after build); the registry agent tracks names for dedup and state inspection.

  Diverges from dynamic-tools.ts: echo_session is registered at init rather than
  in session_start; runtime tools are tracked via a registry agent rather than
  mutating pi at runtime.
  Ported from examples/extensions/dynamic-tools.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, registry) do
    Agent.update(registry, &MapSet.put(&1, "echo_session"))

    {:ok, api} = register_echo_tool(api, "echo_session", "[session] ")

    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> on_session_start(ctx) end)

    API.register_command(api, "add-echo-tool", %{
      description: "Register a new echo tool dynamically: /add-echo-tool <tool_name>",
      handler: fn args, _ctx -> add_echo_tool(args, registry) end
    })
  end

  defp register_echo_tool(api, name, prefix) do
    API.register_tool(api, %{
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
    })
  end

  defp on_session_start(%{has_ui?: true, ui: ui}) do
    ui.notify.("Registered dynamic tool: echo_session")
    :ok
  end

  defp on_session_start(_ctx), do: :ok

  defp add_echo_tool(args, registry) do
    case normalize_name(args) do
      nil ->
        "Usage: /add-echo-tool <tool_name> (lowercase, numbers, underscores only)"

      name ->
        register_in_registry(name, registry)
    end
  end

  defp normalize_name(input) do
    trimmed = input |> String.trim() |> String.downcase()

    if trimmed != "" and String.match?(trimmed, ~r/^[a-z0-9_]+$/),
      do: trimmed
  end

  defp register_in_registry(name, registry) do
    if MapSet.member?(Agent.get(registry, & &1), name) do
      "Tool already registered: #{name}"
    else
      Agent.update(registry, &MapSet.put(&1, name))
      "Registered dynamic tool: #{name}"
    end
  end
end
