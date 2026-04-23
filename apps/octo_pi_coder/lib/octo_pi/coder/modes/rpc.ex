defmodule OctoPi.Coder.Modes.Rpc do
  @moduledoc """
  JSON-lines RPC mode. Reads requests from stdin, dispatches them
  to the agent facade, writes responses + streamed events to
  stdout — each as a single JSON line.

  ## Request / response shape

      -> {"id": "r1", "method": "prompt", "params": {"text": "hi"}}
      <- {"id": "r1", "result": "ok"}

      -> {"id": "r2", "method": "bogus", "params": {}}
      <- {"id": "r2", "error": {"message": "unknown method: bogus"}}

  ## Events (no id)

      <- {"type": "event", "event": "agent_start", "data": {}}
      <- {"type": "event", "event": "turn_start", "data": {"turn": 1}}
      <- {"type": "event", "event": "tool_execution_start",
           "data": {"tool_call_id": "c", "tool_name": "read"}}

  ## Methods

    * `prompt` — params: `{"text": string}`
    * `continue` — no params
    * `steer` — params: `{"text": string}`
    * `follow_up` — params: `{"text": string}`
    * `abort` — no params
    * `wait_for_idle` — params: `{"timeout": ms (optional)}`

  The actual stdin-reading loop is provided separately; most
  callers will be tests that drive `handle_request/2` directly.
  """

  alias OctoPi.Agent.Event

  @doc """
  Parse a single JSON line into a request map, or return
  `{:error, reason}` if the line isn't valid JSON.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = req} -> {:ok, req}
      {:ok, other} -> {:error, {:not_an_object, other}}
      {:error, err} -> {:error, err}
    end
  end

  @doc """
  Dispatch a request map against the given session, returning a
  response map. Never raises — every error shape becomes an
  `"error"` response.
  """
  @spec handle_request(pid(), map()) :: map()
  def handle_request(session, %{"method" => method} = req) do
    id = Map.get(req, "id")
    params = Map.get(req, "params", %{})
    dispatch(session, id, method, params)
  end

  def handle_request(_session, req) do
    %{"id" => Map.get(req, "id"), "error" => %{"message" => "missing 'method' field"}}
  end

  defp dispatch(session, id, "prompt", %{"text" => text}) do
    ok_or_error(id, OctoPi.Agent.prompt(session, text))
  end

  defp dispatch(session, id, "continue", _) do
    ok_or_error(id, OctoPi.Agent.continue(session))
  end

  defp dispatch(session, id, "steer", %{"text" => text}) do
    ok_or_error(id, OctoPi.Agent.steer(session, text))
  end

  defp dispatch(session, id, "follow_up", %{"text" => text}) do
    ok_or_error(id, OctoPi.Agent.follow_up(session, text))
  end

  defp dispatch(session, id, "abort", _) do
    ok_or_error(id, OctoPi.Agent.abort(session))
  end

  defp dispatch(session, id, "wait_for_idle", params) do
    timeout = Map.get(params, "timeout", 30_000)
    ok_or_error(id, OctoPi.Agent.wait_for_idle(session, timeout))
  end

  defp dispatch(_session, id, method, _params) do
    %{"id" => id, "error" => %{"message" => "unknown method: #{method}"}}
  end

  defp ok_or_error(id, :ok), do: %{"id" => id, "result" => "ok"}

  defp ok_or_error(id, {:error, reason}),
    do: %{"id" => id, "error" => %{"message" => to_string(reason)}}

  @doc """
  Convert an `OctoPi.Agent.Event.*` struct into a JSON-friendly
  map of the shape `{"type": "event", "event": name, "data": ...}`.
  Complex fields (messages, results) are rendered in a
  human-readable way but not fully round-trip-safe yet.
  """
  @spec event_to_json(struct()) :: map()
  def event_to_json(%Event.AgentStart{}), do: event("agent_start", %{})

  def event_to_json(%Event.AgentEnd{reason: reason, messages: msgs}) do
    event("agent_end", %{"reason" => to_string(reason), "message_count" => length(msgs)})
  end

  def event_to_json(%Event.TurnStart{turn: turn}), do: event("turn_start", %{"turn" => turn})
  def event_to_json(%Event.TurnEnd{turn: turn}), do: event("turn_end", %{"turn" => turn})

  def event_to_json(%Event.MessageStart{}), do: event("message_start", %{})
  def event_to_json(%Event.MessageUpdate{}), do: event("message_update", %{})
  def event_to_json(%Event.MessageEnd{}), do: event("message_end", %{})

  def event_to_json(%Event.ToolExecutionStart{tool_call_id: id, tool_name: name}) do
    event("tool_execution_start", %{"tool_call_id" => id, "tool_name" => name})
  end

  def event_to_json(%Event.ToolExecutionUpdate{tool_call_id: id}) do
    event("tool_execution_update", %{"tool_call_id" => id})
  end

  def event_to_json(%Event.ToolExecutionEnd{tool_call_id: id, tool_name: name, result: result}) do
    event("tool_execution_end", %{
      "tool_call_id" => id,
      "tool_name" => name,
      "is_error" => result.is_error?
    })
  end

  defp event(name, data), do: %{"type" => "event", "event" => name, "data" => data}
end
