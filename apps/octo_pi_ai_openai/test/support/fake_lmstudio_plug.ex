defmodule OctoPi.AI.TestSupport.FakeLMStudioPlug do
  @moduledoc false

  @doc """
  Returns a Plug-compatible function that responds to LM Studio
  `/api/v0/models` and `/api/v0/models/:id` requests with the supplied
  model list.
  """
  @spec serve([map()], pos_integer()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def serve(models, status \\ 200) when is_list(models) do
    fn conn ->
      respond(conn.path_info, models, status, conn)
    end
  end

  defp respond(["api", "v0", "models"], models, status, conn) do
    body = %{"object" => "list", "data" => models}
    json_resp(conn, status, body)
  end

  defp respond(["api", "v0", "models", id], models, status, conn) do
    case Enum.find(models, fn m -> m["id"] == id end) do
      nil -> json_resp(conn, 404, %{"error" => "model not found", "id" => id})
      model -> json_resp(conn, status, model)
    end
  end

  defp respond(_other, _models, _status, conn) do
    json_resp(conn, 404, %{"error" => "not found"})
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
