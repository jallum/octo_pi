defmodule OctoPi.Coder.Extension.TelemetryHandlerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.{Context, Dispatcher, TelemetryHandler}

  setup do
    TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  defp ext(id, handlers) do
    Enum.reduce(handlers, Extension.new(id, "/ext/#{id}"), fn {event_type, handler}, ext ->
      Extension.add_handler(ext, event_type, handler)
    end)
  end

  describe "emit event logging" do
    test "logs dispatch at debug level" do
      e = ext("a", session_start: fn _e, _c -> nil end)
      event = %{type: :session_start, reason: :new}

      log =
        capture_log([level: :debug], fn ->
          Dispatcher.emit([e], event, ctx())
        end)

      assert log =~ "Dispatched session_start"
      assert log =~ "fire_and_forget"
      assert log =~ "1 handlers"
      assert log =~ "µs"
    end
  end

  describe "handler_error logging" do
    test "logs handler errors at warning level" do
      e = ext("a", session_start: fn _e, _c -> raise "test boom" end)

      log =
        capture_log([level: :warning], fn ->
          Dispatcher.emit([e], %{type: :session_start}, ctx())
        end)

      assert log =~ "Extension a error on session_start"
      assert log =~ "test boom"
    end
  end

  describe "handler_cancel logging" do
    test "logs cancel at info level" do
      e = ext("a", session_before_switch: fn _e, _c -> {:cancel, "dirty"} end)

      log =
        capture_log([level: :info], fn ->
          Dispatcher.emit([e], %{type: :session_before_switch}, ctx())
        end)

      assert log =~ "Extension a cancelled session_before_switch"
      assert log =~ "dirty"
    end
  end

  describe "loaded/load_error logging" do
    test "logs loaded at info level" do
      log =
        capture_log([level: :info], fn ->
          :telemetry.execute(
            [:octo_pi_coder, :extension, :loaded],
            %{count: 1},
            %{id: "test-ext", path: "/ext/test", handler_count: 3, tool_count: 1}
          )
        end)

      assert log =~ "Extension test-ext loaded (3 handlers, 1 tools)"
    end

    test "logs load error at warning level" do
      log =
        capture_log([level: :warning], fn ->
          :telemetry.execute(
            [:octo_pi_coder, :extension, :load_error],
            %{},
            %{path: "/ext/broken", error: "syntax error"}
          )
        end)

      assert log =~ "Failed to load extension at /ext/broken"
    end
  end

  describe "attach/detach" do
    test "detach stops logging" do
      TelemetryHandler.detach()

      log =
        capture_log([level: :info], fn ->
          :telemetry.execute(
            [:octo_pi_coder, :extension, :loaded],
            %{count: 1},
            %{id: "x", path: "/x", handler_count: 0, tool_count: 0}
          )
        end)

      assert log == ""
    end
  end
end
