defmodule OctoPi.Coder.Extensions.ProviderPayload do
  @moduledoc """
  Logs provider request payloads and response metadata via a configurable log function.

  Diverges from provider-payload.ts: file I/O (appendFileSync) is replaced by a
  log_fn/1 callback, making the extension testable without filesystem side effects.
  The before_provider_request handler receives the accumulated payload in event.messages
  (Elixir reduce_chain convention).
  Ported from examples/extensions/provider-payload.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), (String.t() -> term())) :: {:ok, API.t()}
  def init(api, log_fn) do
    {:ok, api} =
      API.on(api, :before_provider_request, fn event, _ctx ->
        log_request(event.messages, log_fn)
      end)

    API.on(api, :after_provider_response, fn event, _ctx ->
      log_response(event, log_fn)
    end)
  end

  defp log_request(payload, log_fn) do
    log_fn.("request: #{inspect(payload)}\n\n")
    nil
  end

  defp log_response(event, log_fn) do
    status = Map.get(event, :status, "unknown")
    headers = Map.get(event, :headers, %{})
    log_fn.("response: [#{status}] #{inspect(headers)}\n\n")
    :ok
  end
end
