defmodule OctoPi.Coder.Extensions.EventBusDemo do
  @moduledoc """
  Inter-extension event bus example. Demonstrates `api.events` for pub/sub
  messaging between extensions. Ported from
  examples/extensions/event-bus.ts.

  The session wires a session-scoped `EventBus` into the API before calling
  `init/1` via `bind_core`:

      {:ok, bus} = EventBus.start_link([])
      events = %{
        emit: fn ch, data -> EventBus.emit(bus, ch, data) end,
        on: fn ch, handler -> EventBus.on(bus, ch, handler) end
      }
      {:ok, ext} = Loader.load_from_factory("event-bus", fn api ->
        api |> API.bind_core(%{events: events}) |> EventBusDemo.init()
      end)
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    events = api.events

    {:ok, api} =
      API.on(api, :session_start, fn _event, _ctx -> on_session_start(events) end)

    API.register_command(api, "emit", %{
      description: "Emit my:notification event (usage: /emit message)",
      handler: fn args, _ctx -> emit_notification(events, args) end
    })
  end

  defp on_session_start(events) do
    events.emit.("my:notification", %{message: "Session started", from: "event-bus-demo"})
  end

  defp emit_notification(events, args) do
    message = if String.trim(args) == "", do: "hello", else: String.trim(args)
    events.emit.("my:notification", %{message: message, from: "/emit command"})
  end
end
