defmodule OctoPi.AI.TestSupport.FakeOpenAIPlug do
  @moduledoc false

  @spec serve([binary() | {:sleep, pos_integer()}], pos_integer()) ::
          (Plug.Conn.t() -> Plug.Conn.t())
  def serve(chunks, status \\ 200) do
    fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(status)

      Enum.reduce(chunks, conn, fn
        {:sleep, ms}, conn ->
          Process.sleep(ms)
          conn

        binary, conn when is_binary(binary) ->
          {:ok, conn} = Plug.Conn.chunk(conn, binary)
          conn
      end)
    end
  end

  @spec sse(map()) :: binary()
  def sse(data) when is_map(data) do
    "data: #{Jason.encode!(data)}\n\n"
  end

  @spec done() :: binary()
  def done, do: "data: [DONE]\n\n"
end
