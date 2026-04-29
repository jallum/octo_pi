defmodule OctoPi.Coder.Extension.LoaderTest do
  use ExUnit.Case, async: true

  # Tests that exercise bad-syntax/crashing-init paths log warnings
  # by design; capture them so test output stays clean.
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Loop
  alias OctoPi.Coder.Session.Messages, as: SessionMessages
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore

  @moduletag capture_log: true

  @fixtures_dir Path.join(__DIR__, "fixtures")

  setup do
    dir = Path.join(@fixtures_dir, "ext_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "discover/1" do
    test "finds .ex files in directory", %{dir: dir} do
      File.write!(Path.join(dir, "my_ext.ex"), sample_extension("MyExt"))

      paths = Loader.discover(dir)
      assert length(paths) == 1
      assert hd(paths) =~ "my_ext.ex"
    end

    test "finds subdirectories with index.ex", %{dir: dir} do
      sub = Path.join(dir, "sub_ext")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "index.ex"), sample_extension("SubExt"))

      paths = Loader.discover(dir)
      assert length(paths) == 1
      assert hd(paths) =~ "sub_ext/index.ex"
    end

    test "ignores non-.ex files", %{dir: dir} do
      File.write!(Path.join(dir, "readme.md"), "# hi")
      File.write!(Path.join(dir, "my_ext.ex"), sample_extension("MyExt2"))

      paths = Loader.discover(dir)
      assert length(paths) == 1
    end

    test "returns empty list for missing directory" do
      assert [] = Loader.discover("/nonexistent/path/nowhere")
    end

    test "returns empty list for empty directory", %{dir: dir} do
      assert [] = Loader.discover(dir)
    end
  end

  describe "discover_all/1" do
    test "discovers from multiple directories in order", %{dir: dir} do
      d1 = Path.join(dir, "local")
      d2 = Path.join(dir, "global")
      File.mkdir_p!(d1)
      File.mkdir_p!(d2)
      File.write!(Path.join(d1, "ext_a.ex"), sample_extension("ExtA"))
      File.write!(Path.join(d2, "ext_b.ex"), sample_extension("ExtB"))

      paths = Loader.discover_all([d1, d2])
      assert length(paths) == 2
      assert Enum.at(paths, 0) =~ "ext_a.ex"
      assert Enum.at(paths, 1) =~ "ext_b.ex"
    end

    test "deduplicates by basename across directories", %{dir: dir} do
      d1 = Path.join(dir, "local")
      d2 = Path.join(dir, "global")
      File.mkdir_p!(d1)
      File.mkdir_p!(d2)
      File.write!(Path.join(d1, "same_ext.ex"), sample_extension("SameExt1"))
      File.write!(Path.join(d2, "same_ext.ex"), sample_extension("SameExt2"))

      paths = Loader.discover_all([d1, d2])
      assert length(paths) == 1
      assert hd(paths) =~ "local"
    end
  end

  describe "load/1" do
    test "loads extension module and calls init", %{dir: dir} do
      path = Path.join(dir, "test_ext.ex")
      File.write!(path, sample_extension("TestLoadExt"))

      assert {:ok, ext} = Loader.load(path)
      assert ext.id == "test_ext"
      assert ext.path == path
      assert length(ext.handlers[:session_start] || []) == 1
    end

    test "returns error for invalid module", %{dir: dir} do
      path = Path.join(dir, "bad_ext.ex")
      File.write!(path, "this is not valid elixir at all !!!")

      assert {:error, _reason} = Loader.load(path)
    end

    test "returns error for module without init/1", %{dir: dir} do
      path = Path.join(dir, "no_init.ex")

      File.write!(path, """
      defmodule OctoPi.Extensions.NoInit do
      end
      """)

      assert {:error, _reason} = Loader.load(path)
    end

    test "returns error when init/1 raises", %{dir: dir} do
      path = Path.join(dir, "crash_ext.ex")

      File.write!(path, """
      defmodule OctoPi.Extensions.CrashExt do
        def init(_api), do: raise "init boom"
      end
      """)

      assert {:error, _reason} = Loader.load(path)
    end
  end

  describe "load_all/1" do
    test "loads multiple extensions, skipping failures", %{dir: dir} do
      File.write!(Path.join(dir, "good.ex"), sample_extension("GoodExt"))
      File.write!(Path.join(dir, "bad.ex"), "not elixir !!!")

      paths = Loader.discover(dir)
      extensions = Loader.load_all(paths)
      assert length(extensions) == 1
      assert hd(extensions).id == "good"
    end

    test "emits load_start telemetry before attempting each extension", %{dir: dir} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:octo_pi_coder, :extension, :load_start]
        ])

      File.write!(Path.join(dir, "start.ex"), sample_extension("LoadStartExt"))
      [path] = Loader.discover(dir)
      Loader.load_all([path])

      assert_received {[:octo_pi_coder, :extension, :load_start], ^ref, %{}, meta}
      assert meta.path == path
    end

    test "emits telemetry for loaded extensions", %{dir: dir} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:octo_pi_coder, :extension, :loaded]
        ])

      File.write!(Path.join(dir, "telem.ex"), sample_extension("TelemExt"))
      [path] = Loader.discover(dir)
      Loader.load_all([path])

      assert_received {[:octo_pi_coder, :extension, :loaded], ^ref, %{count: 1}, meta}
      assert meta.id == "telem"
    end

    test "emits telemetry for load errors", %{dir: dir} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:octo_pi_coder, :extension, :load_error]
        ])

      File.write!(Path.join(dir, "broken.ex"), "not valid !!!")
      [path] = Loader.discover(dir)
      Loader.load_all([path])

      assert_received {[:octo_pi_coder, :extension, :load_error], ^ref, %{}, meta}
      assert meta.path =~ "broken.ex"
    end
  end

  describe "load_from_factory/2" do
    test "loads extension from inline factory function" do
      factory = fn api ->
        {:ok, api} = API.on(api, :session_start, fn _e, _c -> nil end)
        {:ok, api}
      end

      assert {:ok, ext} = Loader.load_from_factory("inline-ext", factory)
      assert ext.id == "inline-ext"
      assert ext.path == "factory:inline-ext"
      assert length(ext.handlers[:session_start] || []) == 1
    end

    test "returns error when factory raises" do
      factory = fn _api -> raise "factory boom" end
      assert {:error, reason} = Loader.load_from_factory("bad", factory)
      assert reason =~ "factory boom"
    end

    test "handles :ok return (no state)" do
      factory = fn _api -> :ok end
      assert {:ok, ext} = Loader.load_from_factory("simple", factory)
      assert ext.id == "simple"
    end
  end

  describe "discover_mix_deps/1" do
    test "finds subdirectories with mix.exs", %{dir: dir} do
      dep = Path.join(dir, "my_dep")
      File.mkdir_p!(dep)
      File.write!(Path.join(dep, "mix.exs"), "defmodule MyDep.MixProject do end")

      deps = Loader.discover_mix_deps(dir)
      assert length(deps) == 1
      assert hd(deps) =~ "my_dep"
    end

    test "ignores directories without mix.exs", %{dir: dir} do
      sub = Path.join(dir, "no_mix")
      File.mkdir_p!(sub)

      assert [] = Loader.discover_mix_deps(dir)
    end

    test "returns empty for missing directory" do
      assert [] = Loader.discover_mix_deps("/nonexistent/nowhere")
    end
  end

  describe "standard_dirs/1" do
    test "returns local and global extension dirs" do
      dirs = Loader.standard_dirs("/my/project")
      assert Enum.at(dirs, 0) == "/my/project/.octo_pi/extensions"
      assert Enum.at(dirs, 1) =~ ".octo_pi/extensions"
    end
  end

  describe "discover/1 - additional coverage" do
    test "ignores subdirectory without index.ex", %{dir: dir} do
      sub = Path.join(dir, "no-index")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "helper.ex"), sample_extension("DiscovNoIndex"))

      assert [] == Loader.discover(dir)
    end

    test "does not recurse beyond one level", %{dir: dir} do
      container = Path.join(dir, "container")
      nested = Path.join(container, "nested")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "index.ex"), sample_extension("DiscovNested"))

      assert [] == Loader.discover(dir)
    end

    test "handles mixed direct files and subdirectories", %{dir: dir} do
      File.write!(Path.join(dir, "direct.ex"), sample_extension("DiscovMixedDirect"))
      sub = Path.join(dir, "sub-mixed")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "index.ex"), sample_extension("DiscovMixedSub"))

      assert length(Loader.discover(dir)) == 2
    end
  end

  describe "discover_and_load/2" do
    test "discovers and loads from {cwd}/extensions/", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "auto.ex"), factory_ext(uid()))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      assert length(result.extensions) == 1
    end

    test "combines explicit paths with auto-discovered extensions", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "auto.ex"), factory_ext(uid()))
      explicit = Path.join(dir, "explicit.ex")
      File.write!(explicit, factory_ext(uid()))

      result = Loader.discover_and_load([explicit], dir)
      assert result.errors == []
      assert length(result.extensions) == 2
    end

    test "collects errors without crashing other extensions", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "good.ex"), factory_ext(uid()))
      bad_path = Path.join(ext_dir, "bad.ex")
      File.write!(bad_path, factory_ext_raises(uid()))

      result = Loader.discover_and_load([], dir)
      assert length(result.errors) == 1
      assert hd(result.errors).path == bad_path
      assert hd(result.errors).error =~ "boom"
      assert length(result.extensions) == 1
    end

    test "returns empty result when no extensions exist", %{dir: dir} do
      result = Loader.discover_and_load([], dir)
      assert result == %{extensions: [], errors: []}
    end
  end

  describe "load_extensions/2" do
    test "loads only explicit paths, skips discovery dir", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "discoverable.ex"), factory_ext(uid()))
      explicit = Path.join(dir, "explicit.ex")
      File.write!(explicit, factory_ext(uid()))

      result = Loader.load_extensions([explicit], dir)
      assert result.errors == []
      assert length(result.extensions) == 1
      assert hd(result.extensions).id == "explicit"
    end

    test "with no paths loads nothing regardless of discovery dir", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "discoverable.ex"), factory_ext(uid()))

      result = Loader.load_extensions([], dir)
      assert result == %{extensions: [], errors: []}
    end
  end

  describe "registration from discovered extensions" do
    test "registers commands", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "cmd-ext.ex"), factory_ext_with_command(uid(), "my-cmd"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.commands, "my-cmd")
    end

    test "registers tools", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "tool-ext.ex"), factory_ext_with_tool(uid(), "my-tool"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.tools, "my-tool")
    end

    test "registers event handlers", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "handler-ext.ex"), factory_ext_with_handler(uid(), :agent_start))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.handlers, :agent_start)
    end

    test "registers message renderers", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "renderer-ext.ex"), factory_ext_with_renderer(uid(), "my-type"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.message_renderers, "my-type")
    end

    test "registers shortcuts", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "shortcut-ext.ex"), factory_ext_with_shortcut(uid(), "ctrl+t"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.shortcuts, "ctrl+t")
    end

    test "registers flags", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "flag-ext.ex"), factory_ext_with_flag(uid(), "my-flag"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      [ext] = result.extensions
      assert Map.has_key?(ext.flags, "my-flag")
    end

    test "multiple extensions register different tools", %{dir: dir} do
      ext_dir = Path.join(dir, "extensions")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "tool-a.ex"), factory_ext_with_tool(uid(), "tool-a"))
      File.write!(Path.join(ext_dir, "tool-b.ex"), factory_ext_with_tool(uid(), "tool-b"))

      result = Loader.discover_and_load([], dir)
      assert result.errors == []
      assert length(result.extensions) == 2
      tool_names = Enum.flat_map(result.extensions, fn ext -> Map.keys(ext.tools) end)
      assert "tool-a" in tool_names
      assert "tool-b" in tool_names
    end
  end

  describe "load_for_session/2" do
    setup do
      session_opts = [
        id: "loader-#{:erlang.unique_integer([:positive])}",
        cwd: System.tmp_dir!(),
        root: Path.join(System.tmp_dir!(), "opi-loader-test-#{:erlang.unique_integer([:positive])}")
      ]

      {:ok, store} = SessionStore.start_link(session_opts)

      sm = %SessionManager{cwd: "/tmp", session_id: "sm-loader-test"}

      {:ok, agent} =
        OctoPi.Agent.start_loop(
          model: %OctoPi.AI.Model{
            id: "faux-1",
            name: "Faux Model",
            api: :faux,
            provider: :faux,
            base_url: "https://example.com",
            context_window: 128_000,
            max_tokens: 16_384
          },
          convert_to_llm: &SessionMessages.to_llm/1
        )

      {:ok, session} =
        Loop.start_link(
          extensions: [],
          session_manager: sm,
          store_pid: store,
          agent_pid: agent
        )

      on_exit(fn ->
        if Process.alive?(session), do: GenServer.stop(session)
        if Process.alive?(store), do: SessionStore.close(store)
        if Process.alive?(agent), do: GenServer.stop(agent)
      end)

      {:ok, session: session}
    end

    test "routes api.compact.() through the bound Session pid", %{dir: dir, session: session} do
      uniq = uid()
      reporter = :"loader_compact_reporter_#{uniq}"
      Process.register(self(), reporter)
      on_exit(fn -> if Process.whereis(reporter), do: Process.unregister(reporter) end)

      File.write!(
        Path.join(dir, "compact_caller.ex"),
        """
        defmodule OctoPiTestLoaderCompact#{uniq} do
          def init(api) do
            OctoPi.Coder.Extension.API.on(api, :turn_end, fn _e, _c ->
              send(:#{reporter}, {:result, api.compact.([])})
            end)
          end
        end
        """
      )

      assert {:ok, ext} =
               Loader.load_for_session(Path.join(dir, "compact_caller.ex"), session)

      [handler] = Extension.get_handlers(ext, :turn_end)
      handler.(%{type: :turn_end}, %Context{cwd: "/tmp"})

      # Empty session → :nothing_to_compact, but the call reached Loop.
      assert_received {:result, {:error, :nothing_to_compact}}
    end

    test "without load_for_session, api.compact.() raises on call (raise-stub path)", %{dir: dir} do
      uniq = uid()
      reporter = :"loader_compact_raw_reporter_#{uniq}"
      Process.register(self(), reporter)
      on_exit(fn -> if Process.whereis(reporter), do: Process.unregister(reporter) end)

      File.write!(
        Path.join(dir, "compact_caller_raw.ex"),
        """
        defmodule OctoPiTestLoaderCompactRaw#{uniq} do
          def init(api) do
            OctoPi.Coder.Extension.API.on(api, :turn_end, fn _e, _c ->
              msg =
                try do
                  api.compact.([])
                rescue
                  e -> Exception.message(e)
                end

              send(:#{reporter}, {:caught, msg})
            end)
          end
        end
        """
      )

      assert {:ok, ext} = Loader.load(Path.join(dir, "compact_caller_raw.ex"))

      [handler] = Extension.get_handlers(ext, :turn_end)
      handler.(%{type: :turn_end}, %Context{cwd: "/tmp"})

      assert_received {:caught, msg}
      assert msg =~ "compact not bound"
    end
  end

  defp sample_extension(module_suffix) do
    """
    defmodule OctoPi.Extensions.#{module_suffix} do
      def init(api) do
        {:ok, api} = OctoPi.Coder.Extension.API.on(api, :session_start, fn _e, _c -> nil end)
        {:ok, api}
      end
    end
    """
  end

  defp uid, do: :erlang.unique_integer([:positive])

  defp factory_ext(id) do
    """
    defmodule OctoPiTestLoaderDyn#{id} do
      def init(api), do: {:ok, api}
    end
    """
  end

  defp factory_ext_raises(id) do
    """
    defmodule OctoPiTestLoaderRaise#{id} do
      def init(_api), do: raise "boom"
    end
    """
  end

  defp factory_ext_with_command(id, cmd_name) do
    """
    defmodule OctoPiTestLoaderCmd#{id} do
      def init(api) do
        cmd = %{description: "test", handler: fn _ctx -> :ok end}
        {:ok, api2} = OctoPi.Coder.Extension.API.register_command(api, "#{cmd_name}", cmd)
        {:ok, api2}
      end
    end
    """
  end

  defp factory_ext_with_tool(id, tool_name) do
    """
    defmodule OctoPiTestLoaderTool#{id} do
      def init(api) do
        {:ok, api2} = OctoPi.Coder.Extension.API.register_tool(api, %{name: "#{tool_name}", description: "test"})
        {:ok, api2}
      end
    end
    """
  end

  defp factory_ext_with_handler(id, event_type) do
    """
    defmodule OctoPiTestLoaderHandler#{id} do
      def init(api) do
        OctoPi.Coder.Extension.API.on(api, :#{event_type}, fn _ev, _ctx -> nil end)
      end
    end
    """
  end

  defp factory_ext_with_renderer(id, type_name) do
    """
    defmodule OctoPiTestLoaderRenderer#{id} do
      def init(api) do
        renderer = fn _msg, _opts -> "" end
        {:ok, api2} = OctoPi.Coder.Extension.API.register_message_renderer(api, "#{type_name}", renderer)
        {:ok, api2}
      end
    end
    """
  end

  defp factory_ext_with_shortcut(id, key) do
    """
    defmodule OctoPiTestLoaderShortcut#{id} do
      def init(api) do
        spec = %{description: "test", handler: fn _ctx -> :ok end}
        {:ok, api2} = OctoPi.Coder.Extension.API.register_shortcut(api, "#{key}", spec)
        {:ok, api2}
      end
    end
    """
  end

  defp factory_ext_with_flag(id, flag_name) do
    """
    defmodule OctoPiTestLoaderFlag#{id} do
      def init(api) do
        spec = %{description: "test", default: false}
        {:ok, api2} = OctoPi.Coder.Extension.API.register_flag(api, "#{flag_name}", spec)
        {:ok, api2}
      end
    end
    """
  end
end
