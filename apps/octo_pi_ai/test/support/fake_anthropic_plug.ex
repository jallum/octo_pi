defmodule OctoPi.AI.TestSupport.FakeAnthropicPlug do
  @moduledoc false

  @doc """
  Returns a plug function that responds with a chunked SSE stream
  composed of the given `chunks`. Each chunk may be a raw binary
  (emitted via `Plug.Conn.chunk/2`) or `{:sleep, ms}` to delay.
  """
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

  @doc """
  Build an SSE frame binary from an event name and a JSON-encodable
  map (or pre-encoded string).
  """
  @spec sse(binary(), map() | binary()) :: binary()
  def sse(event, data) when is_map(data) do
    sse(event, Jason.encode!(data))
  end

  def sse(event, data) when is_binary(data) do
    "event: #{event}\ndata: #{data}\n\n"
  end
end
