defmodule OctoPi.Agent.Tool.Handler do
  @moduledoc """
  Behaviour a tool handler module must implement.

  `execute/4` receives:
    - `tool_call_id` — the id from the assistant's `tool_use` block,
      useful for log correlation.
    - `params` — the arguments map after `prepare_arguments` (if any).
    - `abort_ref` — a reference to check via
      `OctoPi.Agent.AbortRef.aborted?/1` at safe points. Tools that
      don't cooperate with abort will only stop when the supervising
      task gets a brutal-kill.
    - `on_update` — a zero-or-one-arg function the tool can call
      with a `Tool.Result` to stream partial progress; the agent
      forwards each call as a `tool_execution_update` event.

  Return `{:ok, %Tool.Result{}}` on success or `{:error, reason}`
  for unexpected failures. Expected failures (e.g. "file not found")
  should go through `{:ok, %Tool.Result{is_error?: true, ...}}` —
  they still return a content block the model can react to.

  Handlers MUST NOT raise for expected failures. Uncaught exceptions
  are caught by the dispatcher and converted into an error-flagged
  `Tool.Result`.
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result

  @type on_update :: (Result.t() -> any())

  @callback execute(
              tool_call_id :: String.t(),
              params :: map(),
              abort_ref :: AbortRef.t(),
              on_update :: on_update()
            ) :: {:ok, Result.t()} | {:error, term()}
end
