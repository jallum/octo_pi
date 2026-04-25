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
  alias OctoPi.AI.Content

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

  defp ok_or_error(id, {:error, reason}), do: %{"id" => id, "error" => %{"message" => to_string(reason)}}

  @doc """
  Convert an `OctoPi.Agent.Event.*` struct into a JSON-friendly
  map of the shape `{"type": "event", "event": name, "data": ...}`.

  The `data` payload carries the fields a progress UI actually
  needs — text content for message updates, result text for tool
  completions, reason + turn count for agent end. Full struct
  round-trip is intentionally *not* preserved; callers who need
  the raw transcript should read the session JSONL file directly.
  """
  @spec event_to_json(struct()) :: map()
  def event_to_json(%Event.AgentStart{}), do: event("agent_start", %{})

  def event_to_json(%Event.AgentEnd{reason: reason, messages: msgs}) do
    event("agent_end", %{
      "reason" => to_string(reason),
      "message_count" => length(msgs),
      "final_text" => final_assistant_text(msgs)
    })
  end

  def event_to_json(%Event.TurnStart{turn: turn}), do: event("turn_start", %{"turn" => turn})
  def event_to_json(%Event.TurnEnd{turn: turn}), do: event("turn_end", %{"turn" => turn})

  def event_to_json(%Event.MessageStart{}), do: event("message_start", %{})

  def event_to_json(%Event.MessageUpdate{partial: partial}) do
    event("message_update", %{"text" => extract_text(partial)})
  end

  def event_to_json(%Event.MessageEnd{message: msg}) do
    event("message_end", %{
      "text" => extract_text(msg),
      "stop_reason" => stop_reason_string(msg)
    })
  end

  def event_to_json(%Event.ToolExecutionStart{tool_call_id: id, tool_name: name}) do
    event("tool_execution_start", %{"tool_call_id" => id, "tool_name" => name})
  end

  def event_to_json(%Event.ToolExecutionUpdate{tool_call_id: id, partial: partial}) do
    event("tool_execution_update", %{
      "tool_call_id" => id,
      "text" => extract_result_text(partial)
    })
  end

  def event_to_json(%Event.ToolExecutionEnd{tool_call_id: id, tool_name: name, result: result}) do
    event("tool_execution_end", %{
      "tool_call_id" => id,
      "tool_name" => name,
      "is_error" => result.is_error?,
      "text" => extract_result_text(result)
    })
  end

  defp event(name, data), do: %{"type" => "event", "event" => name, "data" => data}

  defp final_assistant_text(msgs) do
    msgs
    |> Enum.reverse()
    |> Enum.find(&match?(%OctoPi.AI.Message.Assistant{}, &1))
    |> case do
      nil -> ""
      %{content: content} -> extract_text(%{content: content})
    end
  end

  defp stop_reason_string(%{stop_reason: nil}), do: nil
  defp stop_reason_string(%{stop_reason: reason}), do: to_string(reason)
  defp stop_reason_string(_), do: nil

  defp extract_text(nil), do: ""

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%Content.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(_), do: ""

  defp extract_result_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%Content.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_result_text(_), do: ""
end
