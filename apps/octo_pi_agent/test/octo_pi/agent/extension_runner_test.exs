defmodule OctoPi.Agent.ExtensionRunnerTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Extension
  alias OctoPi.Agent.ExtensionRunner

  # ── Test extension modules ───────────────────────────────────────────────────

  defmodule CancelExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:session_before_compact, _payload, _ctx), do: {:cancel, :no_compact}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule MergeExtensionA do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:context, _payload, _ctx), do: {:ok, %{key_a: "from_a"}}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule MergeExtensionB do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:context, _payload, _ctx), do: {:ok, %{key_b: "from_b"}}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule OverrideExtensionA do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:context, _payload, _ctx), do: {:ok, %{key: "from_a"}}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule OverrideExtensionB do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:context, _payload, _ctx), do: {:ok, %{key: "from_b"}}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule NotificationExtension do
    @moduledoc false
    @behaviour Extension

    def call_count_key, do: {__MODULE__, :call_count}

    @impl true
    def on_event(_type, _payload, _ctx) do
      count = :persistent_term.get(call_count_key(), 0)
      :persistent_term.put(call_count_key(), count + 1)
      :ok
    end
  end

  defmodule NoCallbackExtension do
    @moduledoc false
    @behaviour Extension
    # Deliberately does NOT implement on_event/3.
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_runner(modules \\ []) do
    {:ok, pid} = ExtensionRunner.start_link(session_pid: self())
    Enum.each(modules, &ExtensionRunner.register(pid, &1))
    pid
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "cancellable events" do
    test "returns {:cancelled, reason} when an extension cancels" do
      runner = start_runner([CancelExtension])
      assert {:cancelled, :no_compact} = ExtensionRunner.emit(runner, :session_before_compact, %{})
    end

    test "stops after the first cancel and does not call subsequent extensions" do
      :persistent_term.put(NotificationExtension.call_count_key(), 0)
      runner = start_runner([CancelExtension, NotificationExtension])
      {:cancelled, _} = ExtensionRunner.emit(runner, :session_before_compact, %{})
      # NotificationExtension is registered AFTER CancelExtension; it should NOT be called.
      assert :persistent_term.get(NotificationExtension.call_count_key(), 0) == 0
    end

    test "returns :ok when no extension cancels a cancellable event" do
      runner = start_runner([MergeExtensionA])
      assert :ok = ExtensionRunner.emit(runner, :session_before_compact, %{})
    end
  end

  describe "result-modifiable events" do
    test "merges modifications from multiple handlers in order" do
      runner = start_runner([MergeExtensionA, MergeExtensionB])
      assert {:modified, %{key_a: "from_a", key_b: "from_b"}} = ExtensionRunner.emit(runner, :context, %{})
    end

    test "last-writer-wins when two handlers set the same key" do
      runner = start_runner([OverrideExtensionA, OverrideExtensionB])
      assert {:modified, %{key: "from_b"}} = ExtensionRunner.emit(runner, :context, %{})
    end

    test "returns :ok when no handler returns modifications" do
      runner = start_runner([CancelExtension])
      assert :ok = ExtensionRunner.emit(runner, :context, %{})
    end
  end

  describe "notification-only events" do
    test "calls all handlers and returns :ok" do
      :persistent_term.put(NotificationExtension.call_count_key(), 0)
      runner = start_runner([NotificationExtension, NotificationExtension])
      assert :ok = ExtensionRunner.emit(runner, :some_notification_event, %{})
      assert :persistent_term.get(NotificationExtension.call_count_key()) == 2
    end
  end

  describe "missing callback" do
    test "extension without on_event/3 is skipped gracefully" do
      runner = start_runner([NoCallbackExtension])
      assert :ok = ExtensionRunner.emit(runner, :any_event, %{})
    end

    test "does not crash the runner" do
      runner = start_runner([NoCallbackExtension, MergeExtensionA])
      assert {:modified, %{key_a: "from_a"}} = ExtensionRunner.emit(runner, :context, %{})
    end
  end

  describe "empty runner" do
    test "returns :ok for any event when no extensions registered" do
      runner = start_runner()
      assert :ok = ExtensionRunner.emit(runner, :context, %{})
      assert :ok = ExtensionRunner.emit(runner, :session_before_compact, %{})
    end
  end

  describe "session emit_hook with no extension_runner" do
    test "returns :ok without crashing when extension_runner is nil" do
      model = %OctoPi.AI.Model{
        id: "fake",
        name: "fake",
        api: :fake,
        provider: :fake,
        base_url: "http://fake",
        context_window: nil,
        max_tokens: 100
      }

      {:ok, session} = OctoPi.Agent.start_session(model: model, transport: OctoPi.Agent.Transport.Direct)
      assert :ok = OctoPi.Agent.emit_hook(session, :any_event, %{})
    end
  end
end
