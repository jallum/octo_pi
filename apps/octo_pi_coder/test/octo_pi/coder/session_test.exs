defmodule OctoPi.Coder.SessionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Session
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore

  defp tmp_session_opts(ctx) do
    id = "test-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "opi-session-test-#{ctx.test}-#{id}")
    [id: id, cwd: System.tmp_dir!(), root: root]
  end

  defp open_store!(ctx) do
    {:ok, pid} = SessionStore.start_link(tmp_session_opts(ctx))
    on_exit(fn -> if Process.alive?(pid), do: SessionStore.close(pid) end)
    pid
  end

  defp empty_sm do
    %SessionManager{cwd: "/tmp", session_id: "sm-test"}
  end

  defp message_entry(text) do
    %Entry.Message{
      id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => text}
    }
  end

  describe "start_link/1" do
    test "starts with required opts and exposes state via state/1", ctx do
      store = open_store!(ctx)
      sm = empty_sm()

      {:ok, pid} = Session.start_link(extensions: [], session_manager: sm, store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = Session.state(pid)
      assert state.extensions == []
      assert state.session_manager == sm
      assert state.store_pid == store
      assert state.agent_pid == nil
    end

    test "raises if :extensions, :session_manager, or :store_pid is missing", ctx do
      store = open_store!(ctx)
      sm = empty_sm()

      assert_raise KeyError, fn ->
        Session.start_link(session_manager: sm, store_pid: store)
      end

      assert_raise KeyError, fn ->
        Session.start_link(extensions: [], store_pid: store)
      end

      assert_raise KeyError, fn ->
        Session.start_link(extensions: [], session_manager: sm)
      end
    end

    test "default settings_provider returns Settings.default()", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Session.state(pid).settings_provider.() == Settings.default()
    end

    test "default model_provider returns nil", ctx do
      store = open_store!(ctx)
      {:ok, pid} = Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Session.state(pid).model_provider.() == nil
    end

    test "honors caller-supplied model_provider and settings_provider", ctx do
      store = open_store!(ctx)
      model_fn = fn -> :my_model end
      settings = %Settings{enabled: false, reserve_tokens: 99, keep_recent_tokens: 99}
      settings_fn = fn -> settings end

      {:ok, pid} =
        Session.start_link(
          extensions: [],
          session_manager: empty_sm(),
          store_pid: store,
          model_provider: model_fn,
          settings_provider: settings_fn
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = Session.state(pid)
      assert state.model_provider.() == :my_model
      assert state.settings_provider.() == settings
    end
  end

  describe "getters" do
    setup ctx do
      store = open_store!(ctx)
      ext = %Extension{id: "e1", path: "/dev/null"}
      sm = empty_sm()

      {:ok, pid} =
        Session.start_link(extensions: [ext], session_manager: sm, store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store, sm: sm, ext: ext}
    end

    test "get_session_manager/1 returns the seeded SessionManager", %{pid: pid, sm: sm} do
      assert Session.get_session_manager(pid) == sm
    end

    test "get_extensions/1 returns the seeded extension list", %{pid: pid, ext: ext} do
      assert Session.get_extensions(pid) == [ext]
    end
  end

  describe "add_entry/3" do
    setup ctx do
      store = open_store!(ctx)
      sm = empty_sm()

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: sm, store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{pid: pid, store: store}
    end

    test "appends to in-process SessionManager AND persists to store", %{pid: pid, store: store} do
      assert {:ok, entry_id} = Session.add_entry(pid, message_entry("hello"))

      sm = Session.get_session_manager(pid)
      assert sm.leaf_id == entry_id
      assert Map.has_key?(sm.by_id, entry_id)

      # Persistence: read JSONL back and confirm the entry landed.
      path = SessionStore.path(store)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      # header line + one entry line
      assert length(lines) == 2
    end

    test "two appends produce a parent_id chain in the SessionManager", %{pid: pid} do
      assert {:ok, id1} = Session.add_entry(pid, message_entry("a"))
      assert {:ok, id2} = Session.add_entry(pid, message_entry("b"))
      refute id1 == id2

      sm = Session.get_session_manager(pid)
      assert sm.leaf_id == id2
      e2 = Map.fetch!(sm.by_id, id2)
      assert e2.parent_id == id1
    end

    test "honors caller-supplied :id option", %{pid: pid} do
      assert {:ok, "fixed-id"} = Session.add_entry(pid, message_entry("x"), id: "fixed-id")
      assert Session.get_session_manager(pid).leaf_id == "fixed-id"
    end
  end

  describe "actions/1" do
    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "append_entry routes to the GenServer and updates state", %{pid: pid} do
      actions = Session.actions(pid)
      assert {:ok, id} = actions.append_entry.(message_entry("from-action"))
      assert Session.get_session_manager(pid).leaf_id == id
    end

    test "unimplemented one-arity actions return {:error, :not_implemented}", %{pid: pid} do
      actions = Session.actions(pid)
      assert {:error, :not_implemented} = actions.compact.([])
      assert {:error, :not_implemented} = actions.send_message.("hi")
      assert {:error, :not_implemented} = actions.set_model.(:m)
    end

    test "unimplemented zero-arity actions return {:error, :not_implemented}", %{pid: pid} do
      actions = Session.actions(pid)
      assert {:error, :not_implemented} = actions.get_model.()
      assert {:error, :not_implemented} = actions.abort.()
      assert {:error, :not_implemented} = actions.get_context_usage.()
    end

    test "unimplemented two-arity action returns {:error, :not_implemented}", %{pid: pid} do
      actions = Session.actions(pid)
      assert {:error, :not_implemented} = actions.exec.("ls", [])
    end
  end

  describe "bind_context/2" do
    setup ctx do
      store = open_store!(ctx)

      {:ok, pid} =
        Session.start_link(extensions: [], session_manager: empty_sm(), store_pid: store)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "wires get_entries / get_branch / get_leaf_entry_id to live SessionManager", %{pid: pid} do
      ctx = OctoPi.Coder.Extension.Context.new(%{cwd: "/tmp"})
      bound = Session.bind_context(pid, ctx)

      assert bound.get_entries.() == []
      assert bound.get_leaf_entry_id.() == nil

      assert {:ok, id} = Session.add_entry(pid, message_entry("x"))
      assert bound.get_leaf_entry_id.() == id
    end
  end
end
