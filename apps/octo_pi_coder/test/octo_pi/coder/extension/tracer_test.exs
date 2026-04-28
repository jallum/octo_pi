defmodule OctoPi.Coder.Extension.TracerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher

  setup do
    OctoPi.Tracer.register(%{
      id: :coder_extension,
      description: "",
      events: %{
        info: [
          [:octo_pi_coder, :extension, :loaded],
          [:octo_pi_coder, :extension, :handler_cancel]
        ],
        warning: [
          [:octo_pi_coder, :extension, :load_error],
          [:octo_pi_coder, :extension, :handler_error]
        ],
        debug: [
          [:octo_pi_coder, :extension, :emit]
        ]
      }
    })

    OctoPi.Tracer.attach_all()
    on_exit(fn -> OctoPi.Tracer.detach(:coder_extension) end)
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

      assert log =~ "octo_pi_coder.extension.emit"
      assert log =~ "event_type=session_start"
      assert log =~ "handler_count=1"
    end
  end

  describe "handler_error logging" do
    test "logs handler errors at warning level" do
      e = ext("a", session_start: fn _e, _c -> raise "test boom" end)

      log =
        capture_log([level: :warning], fn ->
          Dispatcher.emit([e], %{type: :session_start}, ctx())
        end)

      assert log =~ "octo_pi_coder.extension.handler_error"
      assert log =~ "extension_id=a"
      assert log =~ "event_type=session_start"
    end
  end

  describe "handler_cancel logging" do
    test "logs cancel at info level" do
      e = ext("a", session_before_switch: fn _e, _c -> {:cancel, "dirty"} end)

      log =
        capture_log([level: :info], fn ->
          Dispatcher.emit([e], %{type: :session_before_switch}, ctx())
        end)

      assert log =~ "octo_pi_coder.extension.handler_cancel"
      assert log =~ "extension_id=a"
      assert log =~ "event_type=session_before_switch"
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

      assert log =~ "octo_pi_coder.extension.loaded"
      assert log =~ "id=test-ext"
      assert log =~ "handler_count=3"
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

      assert log =~ "octo_pi_coder.extension.load_error"
      assert log =~ "path=/ext/broken"
    end
  end

  describe "detach" do
    test "detach stops logging" do
      OctoPi.Tracer.detach(:coder_extension)

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
