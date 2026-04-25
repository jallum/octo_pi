defmodule OctoPi.Coder.Extension.ReferenceExtensionsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event
  # --- DirtyRepoGuard ---
  alias OctoPi.Coder.Extensions.DirtyRepoGuard
  alias OctoPi.Coder.Extensions.InputTransform

  describe "DirtyRepoGuard" do
    setup do
      api = API.new("dirty-repo-guard")
      {:ok, api} = DirtyRepoGuard.init(api)
      ext = API.build_extension(api, "/builtin/dirty_repo_guard.ex")
      {:ok, ext: ext}
    end

    test "registers session_before_switch handler", %{ext: ext} do
      assert length(Extension.get_handlers(ext, :session_before_switch)) == 1
    end

    test "cancels when repo is dirty", %{ext: ext} do
      dir = Path.join(System.tmp_dir!(), "drg_dirty_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)
      File.write!(Path.join(dir, "file.txt"), "dirty")
      System.cmd("git", ["add", "."], cd: dir)

      ctx = Context.new(%{cwd: dir})
      event = Event.new(:session_before_switch, %{reason: :new})

      assert {:cancel, "uncommitted changes in repo"} =
               Dispatcher.cancel_on_result([ext], event, ctx)
    end

    test "allows when repo is clean", %{ext: ext} do
      dir = Path.join(System.tmp_dir!(), "drg_clean_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)

      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@test",
          "commit",
          "--allow-empty",
          "-m",
          "init"
        ],
        cd: dir
      )

      ctx = Context.new(%{cwd: dir})
      event = Event.new(:session_before_switch, %{reason: :new})

      assert :ok = Dispatcher.cancel_on_result([ext], event, ctx)
    end

    test "allows in non-git directory", %{ext: ext} do
      dir = Path.join(System.tmp_dir!(), "drg_nogit_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      ctx = Context.new(%{cwd: dir})
      event = Event.new(:session_before_switch, %{reason: :new})

      assert :ok = Dispatcher.cancel_on_result([ext], event, ctx)
    end
  end

  # --- InputTransform ---

  describe "InputTransform" do
    setup do
      api = API.new("input-transform")
      {:ok, api} = InputTransform.init(api)
      ext = API.build_extension(api, "/builtin/input_transform.ex")
      {:ok, ext: ext}
    end

    test "registers input handler", %{ext: ext} do
      assert length(Extension.get_handlers(ext, :input)) == 1
    end

    test "blocks dangerous rm -rf /", %{ext: ext} do
      ctx = Context.new(%{cwd: "/tmp"})
      event = Event.new(:input, %{text: "please rm -rf / now", images: nil, source: :interactive})

      # reduce_chain for input returns the last accumulator
      # But since we use emit which auto-dispatches, let's test via direct handler
      [handler] = Extension.get_handlers(ext, :input)
      result = handler.(event, ctx)
      assert result.action == :transform
      assert result.text =~ "[BLOCKED: rm -rf /]"
    end

    test "blocks sudo rm", %{ext: ext} do
      [handler] = Extension.get_handlers(ext, :input)
      ctx = Context.new(%{cwd: "/tmp"})

      event =
        Event.new(:input, %{text: "try sudo rm something", images: nil, source: :interactive})

      result = handler.(event, ctx)
      assert result.action == :transform
      assert result.text =~ "[BLOCKED: sudo rm]"
    end

    test "passes through safe input", %{ext: ext} do
      [handler] = Extension.get_handlers(ext, :input)
      ctx = Context.new(%{cwd: "/tmp"})

      event =
        Event.new(:input, %{text: "fix the failing test", images: nil, source: :interactive})

      result = handler.(event, ctx)
      assert result.action == :continue
    end
  end

  # --- End-to-end: multiple extensions ---

  describe "end-to-end with both extensions" do
    setup do
      api1 = API.new("dirty-repo-guard")
      {:ok, api1} = DirtyRepoGuard.init(api1)
      ext1 = API.build_extension(api1, "/builtin/dirty_repo_guard.ex")

      api2 = API.new("input-transform")
      {:ok, api2} = InputTransform.init(api2)
      ext2 = API.build_extension(api2, "/builtin/input_transform.ex")

      {:ok, extensions: [ext1, ext2]}
    end

    test "fire_and_forget runs across both without error", %{extensions: exts} do
      ctx = Context.new(%{cwd: "/tmp"})
      event = Event.new(:session_start, %{reason: :new})
      assert :ok = Dispatcher.fire_and_forget(exts, event, ctx)
    end

    test "each extension only handles its registered events", %{extensions: exts} do
      ctx = Context.new(%{cwd: "/tmp"})

      assert :ok = Dispatcher.cancel_on_result(exts, Event.new(:session_before_switch), ctx)

      [handler] = Extension.get_handlers(Enum.at(exts, 1), :input)

      result =
        handler.(Event.new(:input, %{text: "safe input", images: nil, source: :interactive}), ctx)

      assert result.action == :continue
    end

    test "telemetry fires for emit dispatch", %{extensions: exts} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:octo_pi_coder, :extension, :emit]
        ])

      ctx = Context.new(%{cwd: "/tmp"})
      Dispatcher.emit(exts, Event.new(:session_start, %{reason: :new}), ctx)

      assert_received {[:octo_pi_coder, :extension, :emit], ^ref, %{duration: _}, meta}
      assert meta.event_type == :session_start
      assert meta.pattern == :fire_and_forget
    end
  end
end
