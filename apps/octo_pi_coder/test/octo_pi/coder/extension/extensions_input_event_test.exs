defmodule OctoPi.Coder.Extension.ExtensionsInputEventTest do
  @moduledoc """
  Elixir port of upstream extensions-input-event.test.ts.

  The TypeScript ExtensionRunner.emitInput/3 maps to
  Dispatcher.emit_input/5. Semantics: handlers chain through
  :transform (updating text/images), :handled short-circuits,
  and :continue (or nil/raise) passes through unchanged.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Loader

  defp ext(id, factory) do
    {:ok, extension} = Loader.load_from_factory(id, factory)
    extension
  end

  defp ctx, do: %Context{cwd: "/tmp"}

  defp emit(extensions, text, images \\ nil, source \\ :interactive) do
    Dispatcher.emit_input(extensions, text, images, source, ctx())
  end

  # ── no handlers / nil / continue ────────────────────────────────

  describe "default :continue result" do
    test "no handlers → :continue" do
      assert %{action: :continue} = emit([], "x")
    end

    test "nil return → :continue" do
      e = ext("ext", fn api -> API.on(api, :input, fn _ev, _ctx -> nil end) end)
      assert %{action: :continue} = emit([e], "x")
    end

    test "explicit :continue return → :continue" do
      e =
        ext("ext", fn api ->
          API.on(api, :input, fn _ev, _ctx -> %{action: :continue} end)
        end)

      assert %{action: :continue} = emit([e], "x")
    end
  end

  # ── transform ───────────────────────────────────────────────────

  describe "text transform" do
    test "transforms text and preserves original images when images omitted" do
      images = [%{type: "image", data: "orig", mime_type: "image/png"}]

      e =
        ext("ext", fn api ->
          API.on(api, :input, fn ev, _ctx ->
            %{action: :transform, text: "T:" <> ev.text}
          end)
        end)

      result = emit([e], "hi", images)
      assert result.action == :transform
      assert result.text == "T:hi"
      assert result.images == images
    end

    test "transforms and replaces images when provided" do
      new_images = [%{type: "image", data: "new", mime_type: "image/jpeg"}]

      e =
        ext("ext", fn api ->
          API.on(api, :input, fn _ev, _ctx ->
            %{action: :transform, text: "X", images: new_images}
          end)
        end)

      result = emit([e], "hi", [%{type: "image", data: "orig", mime_type: "image/png"}])
      assert result.action == :transform
      assert result.text == "X"
      assert result.images == new_images
    end
  end

  # ── chaining ────────────────────────────────────────────────────

  describe "handler chaining" do
    test "transforms accumulate across multiple handlers" do
      e1 =
        ext("ext-1", fn api ->
          API.on(api, :input, fn ev, _ctx ->
            %{action: :transform, text: ev.text <> "[1]"}
          end)
        end)

      e2 =
        ext("ext-2", fn api ->
          API.on(api, :input, fn ev, _ctx ->
            %{action: :transform, text: ev.text <> "[2]"}
          end)
        end)

      result = emit([e1, e2], "X")
      assert result.action == :transform
      assert result.text == "X[1][2]"
    end

    test ":handled short-circuits and skips subsequent handlers" do
      test_pid = self()

      e1 =
        ext("ext-1", fn api ->
          API.on(api, :input, fn _ev, _ctx -> %{action: :handled} end)
        end)

      e2 =
        ext("ext-2", fn api ->
          API.on(api, :input, fn _ev, _ctx ->
            send(test_pid, :second_ran)
            %{action: :continue}
          end)
        end)

      result = emit([e1, e2], "X")
      assert result.action == :handled
      refute_received :second_ran
    end
  end

  # ── source field ────────────────────────────────────────────────

  describe "source field" do
    test "passes source to handlers for all source types" do
      test_pid = self()

      e =
        ext("ext", fn api ->
          API.on(api, :input, fn ev, _ctx ->
            send(test_pid, {:source, ev.source})
            %{action: :continue}
          end)
        end)

      for source <- [:interactive, :rpc, :extension] do
        Dispatcher.emit_input([e], "x", nil, source, ctx())
        assert_receive {:source, ^source}
      end
    end
  end

  # ── error handling ───────────────────────────────────────────────

  describe "error handling" do
    test "handler error is swallowed and dispatch continues with :continue" do
      e =
        ext("throws", fn api ->
          API.on(api, :input, fn _ev, _ctx -> raise "boom" end)
        end)

      log =
        capture_log(fn ->
          assert %{action: :continue} = emit([e], "x")
        end)

      assert log =~ "boom"
    end

    test "handler error does not affect subsequent handlers" do
      e1 =
        ext("throws", fn api ->
          API.on(api, :input, fn _ev, _ctx -> raise "boom" end)
        end)

      e2 =
        ext("ok", fn api ->
          API.on(api, :input, fn ev, _ctx ->
            %{action: :transform, text: "ok:" <> ev.text}
          end)
        end)

      log =
        capture_log(fn ->
          result = emit([e1, e2], "x")
          assert result.action == :transform
          assert result.text == "ok:x"
        end)

      assert log =~ "boom"
    end
  end

  # ── has_handlers? ────────────────────────────────────────────────

  describe "has_handlers? for :input" do
    test "returns false when no extension has an :input handler" do
      refute Dispatcher.has_handlers?([], :input)
    end

    test "returns true when an extension has an :input handler" do
      e =
        ext("ext", fn api ->
          API.on(api, :input, fn _ev, _ctx -> nil end)
        end)

      assert Dispatcher.has_handlers?([e], :input)
    end
  end
end
