defmodule OctoPi.Coder.Extension.LoaderTest do
  use ExUnit.Case, async: true

  # Tests that exercise bad-syntax/crashing-init paths log warnings
  # by design; capture them so test output stays clean.
  alias OctoPi.Coder.Extension.Loader

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
        {:ok, api} = OctoPi.Coder.Extension.API.on(api, :session_start, fn _e, _c -> nil end)
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
end
