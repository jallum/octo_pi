defmodule OctoPi.Coder.Extensions.PermissionGate do
  @moduledoc """
  Prompts for confirmation before running potentially dangerous bash commands.
  Patterns checked: rm -rf, sudo, chmod/chown 777.

  Diverges from permission-gate.ts: uses UIContext.select/2 (options list + keyword prompt)
  instead of the TypeScript (prompt string, choices array) signature.
  Ported from examples/extensions/permission-gate.ts.
  """

  alias OctoPi.Coder.Extension.API

  @dangerous_patterns [
    ~r/\brm\s+(-rf?|--recursive)/i,
    ~r/\bsudo\b/i,
    ~r/\b(chmod|chown)\b.*777/i
  ]

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :tool_call, fn event, ctx -> check(event, ctx) end)
  end

  defp check(%{name: "bash", arguments: args}, ctx) do
    command = Map.get(args, "command", "")
    if dangerous?(command), do: gate(command, ctx)
  end

  defp check(_, _), do: nil

  defp dangerous?(command), do: Enum.any?(@dangerous_patterns, &Regex.match?(&1, command))

  defp gate(_command, %{has_ui?: false}) do
    {:block, "Dangerous command blocked (no UI for confirmation)"}
  end

  defp gate(command, %{has_ui?: true, ui: ui}) do
    prompt = "⚠️ Dangerous command:\n\n  #{command}\n\nAllow?"
    options = [%{label: "Yes", value: :yes}, %{label: "No", value: :no}]

    case ui.select.(options, prompt: prompt) do
      {:ok, :yes} -> nil
      _ -> {:block, "Blocked by user"}
    end
  end
end
