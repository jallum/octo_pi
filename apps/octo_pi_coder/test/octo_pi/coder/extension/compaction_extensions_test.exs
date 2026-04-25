defmodule OctoPi.Coder.Extension.CompactionExtensionsTest do
  @moduledoc """
  Elixir port of upstream compaction-extensions.test.ts.

  Upstream tests are fully live-integration: they call session.compact()
  against a real LLM (guarded by API_KEY) and verify the full
  before_compact → compact lifecycle including session storage.

  The Elixir equivalent tests the dispatcher semantics for the two
  compaction event types in isolation:

  * `:session_before_compact` — pattern: cancel_on_result
      {:cancel, reason} halts; anything else continues.
  * `:session_compact` — pattern: fire_and_forget
      All handlers called; results are ignored; returns :ok.

  Divergence: upstream supports a {compaction: %{}} return value from
  session_before_compact handlers, letting extensions supply custom
  compaction data. The Elixir cancel_on_result pattern does not carry
  this data back to callers (it returns :ok for non-cancel results).
  That semantic would require a dedicated pattern change.
  """

  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event

  @moduletag capture_log: true

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  defp ext(id, handlers) do
    Enum.reduce(handlers, Extension.new(id, "/ext/#{id}"), fn {event_type, handler}, ext ->
      Extension.add_handler(ext, event_type, handler)
    end)
  end

  defp before_compact_event, do: Event.new(:session_before_compact)
  defp compact_event, do: Event.new(:session_compact)

  # ── session_before_compact (cancel_on_result) ────────────────────

  describe "session_before_compact — cancel" do
    test "returns :ok when no handler cancels" do
      e = ext("a", session_before_compact: fn _ev, _ctx -> nil end)
      assert :ok = Dispatcher.emit([e], before_compact_event(), ctx())
    end

    test "handler returning {:cancel, reason} cancels compaction" do
      e = ext("a", session_before_compact: fn _ev, _ctx -> {:cancel, "Compaction cancelled"} end)
      assert {:cancel, "Compaction cancelled"} = Dispatcher.emit([e], before_compact_event(), ctx())
    end

    test "cancel short-circuits: second handler is not called" do
      test_pid = self()

      e1 = ext("a", session_before_compact: fn _ev, _ctx -> {:cancel, "stop"} end)
      e2 = ext("b", session_before_compact: fn _ev, _ctx -> send(test_pid, :second_ran) end)

      assert {:cancel, "stop"} = Dispatcher.emit([e1, e2], before_compact_event(), ctx())
      refute_received :second_ran
    end

    test "multiple extensions called in order until first cancels" do
      test_pid = self()

      e1 =
        ext("a",
          session_before_compact: fn _ev, _ctx ->
            send(test_pid, :first)
            nil
          end
        )

      e2 =
        ext("b",
          session_before_compact: fn _ev, _ctx ->
            send(test_pid, :second)
            {:cancel, "x"}
          end
        )

      e3 = ext("c", session_before_compact: fn _ev, _ctx -> send(test_pid, :third) end)

      Dispatcher.emit([e1, e2, e3], before_compact_event(), ctx())

      assert_received :first
      assert_received :second
      refute_received :third
    end

    test "handler error is swallowed and dispatch continues" do
      e1 = ext("throws", session_before_compact: fn _ev, _ctx -> raise "Extension error!" end)
      e2 = ext("ok", session_before_compact: fn _ev, _ctx -> {:cancel, "after error"} end)

      assert {:cancel, "after error"} = Dispatcher.emit([e1, e2], before_compact_event(), ctx())
    end

    test "handler error alone returns :ok (default compaction proceeds)" do
      e = ext("throws", session_before_compact: fn _ev, _ctx -> raise "boom" end)
      assert :ok = Dispatcher.emit([e], before_compact_event(), ctx())
    end

    test "non-cancel return (custom compaction map) is treated as :ok" do
      custom = %{summary: "custom summary", tokens_before: 999}
      e = ext("custom", session_before_compact: fn _ev, _ctx -> {:compact, custom} end)
      assert :ok = Dispatcher.emit([e], before_compact_event(), ctx())
    end

    test "no extensions returns :ok" do
      assert :ok = Dispatcher.emit([], before_compact_event(), ctx())
    end
  end

  # ── session_compact (fire_and_forget) ────────────────────────────

  describe "session_compact — fire_and_forget" do
    test "calls handler after compaction completes" do
      test_pid = self()
      e = ext("a", session_compact: fn _ev, _ctx -> send(test_pid, :compact_ran) end)

      assert :ok = Dispatcher.emit([e], compact_event(), ctx())
      assert_received :compact_ran
    end

    test "multiple extensions are all notified in order" do
      test_pid = self()

      e1 = ext("a", session_compact: fn _ev, _ctx -> send(test_pid, :first) end)
      e2 = ext("b", session_compact: fn _ev, _ctx -> send(test_pid, :second) end)

      Dispatcher.emit([e1, e2], compact_event(), ctx())

      assert_received :first
      assert_received :second
    end

    test "handler error does not crash dispatch" do
      test_pid = self()

      e1 = ext("throws", session_compact: fn _ev, _ctx -> raise "oops" end)
      e2 = ext("ok", session_compact: fn _ev, _ctx -> send(test_pid, :second_ran) end)

      assert :ok = Dispatcher.emit([e1, e2], compact_event(), ctx())
      assert_received :second_ran
    end

    test "handler return value is ignored (fire_and_forget)" do
      e = ext("a", session_compact: fn _ev, _ctx -> %{from_extension: true} end)
      assert :ok = Dispatcher.emit([e], compact_event(), ctx())
    end

    test "no extensions returns :ok" do
      assert :ok = Dispatcher.emit([], compact_event(), ctx())
    end
  end

  # ── has_handlers? ────────────────────────────────────────────────

  describe "has_handlers? for compaction events" do
    test "returns true when extension has session_before_compact handler" do
      e = ext("a", session_before_compact: fn _ev, _ctx -> nil end)
      assert Dispatcher.has_handlers?([e], :session_before_compact)
    end

    test "returns true when extension has session_compact handler" do
      e = ext("a", session_compact: fn _ev, _ctx -> nil end)
      assert Dispatcher.has_handlers?([e], :session_compact)
    end

    test "returns false when no extension handles compaction events" do
      e = ext("a", agent_start: fn _ev, _ctx -> nil end)
      refute Dispatcher.has_handlers?([e], :session_before_compact)
      refute Dispatcher.has_handlers?([e], :session_compact)
    end
  end
end
