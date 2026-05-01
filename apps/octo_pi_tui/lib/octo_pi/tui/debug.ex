defmodule OctoPi.TUI.Debug do
  @moduledoc """
  Debug module to allow external triggering of TUI events via erpc.
  """

  @doc """
  Triggers a dummy render event for testing purposes.
  """
  def trigger_render(type) do
    case type do
      "large" ->
        _content = String.duplicate("lorem ipsum ", 1000)
        # We need to find where the transcript/markdown is managed and send it there.
        # For now, let's just simulate the telemetry event directly to verify connectivity.
        :telemetry.execute(
          [:octo_pi_tui, :transcript, :render],
          %{msg_count: 10, streaming?: true},
          %{type: "large"}
        )
      "small" ->
         :telemetry.execute(
          [:octo_pi_tui, :transcript, :render],
          %{msg_count: 1, streaming?: false},
          %{type: "small"}
        )
      _ ->
        :ok
    end
    :ok
  end
end
