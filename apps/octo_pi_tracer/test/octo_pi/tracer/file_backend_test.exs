defmodule OctoPi.Tracer.FileBackendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias OctoPi.Tracer.FileBackend

  setup do
    path = Path.join(System.tmp_dir!(), "tracer_test_#{:erlang.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "install/1 and uninstall/0" do
    test "writes Logger messages with domain [:octo_pi_tracer] to file", %{path: path} do
      log =
        capture_log(fn ->
          assert :ok = FileBackend.install(path)

          Logger.info("test line from tracer", domain: [:octo_pi_tracer])

          # Flush logger to ensure the message is written
          Logger.flush()

          FileBackend.uninstall()
        end)

      assert log =~ "test line from tracer"

      contents = File.read!(path)
      assert contents =~ "test line from tracer"
    end

    test "does not write messages without the tracer domain", %{path: path} do
      log =
        capture_log(fn ->
          assert :ok = FileBackend.install(path)

          Logger.info("should not appear")

          Logger.flush()

          FileBackend.uninstall()
        end)

      assert log =~ "should not appear"

      contents = File.read!(path)
      refute contents =~ "should not appear"
    end

    test "uninstall/0 closes the file and removes the handler", %{path: path} do
      FileBackend.install(path)
      assert :ok = FileBackend.uninstall()

      # Installing again should succeed (handler was removed)
      assert :ok = FileBackend.install(path)
      FileBackend.uninstall()
    end
  end
end
