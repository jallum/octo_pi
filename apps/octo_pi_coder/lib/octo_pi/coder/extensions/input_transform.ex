defmodule OctoPi.Coder.Extensions.InputTransform do
  @moduledoc false

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :input, &handle_input/2)
  end

  defp handle_input(%{text: text} = _event, _ctx) do
    case expand(text) do
      ^text -> %{action: :continue}
      expanded -> %{action: :transform, text: expanded, images: nil}
    end
  end

  defp expand(text) do
    text
    |> String.replace(~r/\brm\s+-rf\s+\//, "[BLOCKED: rm -rf /]")
    |> String.replace(~r/\bsudo\s+rm\b/, "[BLOCKED: sudo rm]")
  end
end
