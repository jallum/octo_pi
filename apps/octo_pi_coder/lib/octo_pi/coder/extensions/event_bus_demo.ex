defmodule OctoPi.Coder.Extensions.EventBusDemo do
  @moduledoc """
  Inter-extension event bus example. Demonstrates OctoPi.Coder.Extension.EventBus
  for pub/sub messaging between extensions. Ported from
  examples/extensions/event-bus.ts.

  Divergence: upstream uses `pi.events` (an EventEmitter built into the API).
  Elixir uses a separate `EventBus` GenServer. The factory must capture a bus
  pid and pass it to `init/2`:

      {:ok, bus} = EventBus.start_link([])
      {:ok, ext} = Loader.load_from_factory("event-bus", fn api ->
        EventBusDemo.init(api, bus)
      end)
  """

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.EventBus

  @spec init(API.t(), EventBus.server()) :: {:ok, API.t()}
  def init(api, bus) do
    {:ok, api} = API.on(api, :session_start, fn _event, _ctx -> on_session_start(bus) end)

    API.register_command(api, "emit", %{
      description: "Emit my:notification event (usage: /emit message)",
      handler: fn args, _ctx -> emit_notification(bus, args) end
    })
  end

  defp on_session_start(bus) do
    EventBus.emit(bus, "my:notification", %{message: "Session started", from: "event-bus-demo"})
  end

  defp emit_notification(bus, args) do
    message = if String.trim(args) == "", do: "hello", else: String.trim(args)
    EventBus.emit(bus, "my:notification", %{message: message, from: "/emit command"})
  end
end
