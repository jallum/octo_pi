defmodule OctoPi.Coder.Extensions.CommandsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.Commands

  defp ext_with_commands(available_commands, compact_fn \\ fn _opts -> :ok end, navigate_tree_fn \\ fn _opts -> {:ok, :navigated} end) do
    factory = fn api ->
      api =
        API.bind_core(api, %{
          get_commands: fn -> available_commands end,
          compact: compact_fn,
          navigate_tree: navigate_tree_fn
        })

      Commands.init(api)
    end

    {:ok, ext} = Loader.load_from_factory("commands", factory)
    ext
  end

  describe "init/1" do
    test "registers a command named 'commands'" do
      ext = ext_with_commands([])

      assert Map.has_key?(ext.commands, "commands")
    end

    test "registers a command named 'compact'" do
      ext = ext_with_commands([])

      assert Map.has_key?(ext.commands, "compact")
    end

    test "'commands' has the expected description" do
      ext = ext_with_commands([])

      assert ext.commands["commands"].description == "List available slash commands"
    end

    test "'compact' has the expected description" do
      ext = ext_with_commands([])

      assert ext.commands["compact"].description == "Compact the session context"
    end

    test "registers no tools" do
      ext = ext_with_commands([])

      assert ext.tools == %{}
    end

    test "registers no event handlers" do
      ext = ext_with_commands([])

      assert ext.handlers == %{}
    end
  end

  describe "commands handler" do
    test "empty filter returns all commands" do
      all = [
        %{name: "foo", source: "extension"},
        %{name: "bar", source: "prompt"}
      ]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("", nil)

      assert result == all
    end

    test "whitespace-only filter returns all commands" do
      all = [%{name: "foo", source: "extension"}]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("   ", nil)

      assert result == all
    end

    test "source filter returns only matching commands" do
      all = [
        %{name: "foo", source: "extension"},
        %{name: "bar", source: "prompt"},
        %{name: "baz", source: "extension"}
      ]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("extension", nil)

      assert length(result) == 2
      assert Enum.all?(result, &(&1.source == "extension"))
    end

    test "filter matching no commands returns empty list" do
      all = [%{name: "foo", source: "extension"}]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("skill", nil)

      assert result == []
    end

    test "no available commands returns empty list" do
      ext = ext_with_commands([])
      result = ext.commands["commands"].handler.("", nil)

      assert result == []
    end
  end

  describe "compact handler — argument parsing" do
    test "empty args calls compact with no opts" do
      test_pid = self()
      compact_fn = fn opts -> send(test_pid, {:compact_called, opts}) end
      ext = ext_with_commands([], compact_fn)

      ext.commands["compact"].handler.("", nil)

      assert_receive {:compact_called, []}
    end

    test "whitespace-only args calls compact with no opts" do
      test_pid = self()
      compact_fn = fn opts -> send(test_pid, {:compact_called, opts}) end
      ext = ext_with_commands([], compact_fn)

      ext.commands["compact"].handler.("   ", nil)

      assert_receive {:compact_called, []}
    end

    test "non-empty args passes custom_instructions" do
      test_pid = self()
      compact_fn = fn opts -> send(test_pid, {:compact_called, opts}) end
      ext = ext_with_commands([], compact_fn)

      ext.commands["compact"].handler.("focus on auth module", nil)

      assert_receive {:compact_called, opts}
      assert opts[:custom_instructions] == "focus on auth module"
    end

    test "leading/trailing whitespace is stripped from instructions" do
      test_pid = self()
      compact_fn = fn opts -> send(test_pid, {:compact_called, opts}) end
      ext = ext_with_commands([], compact_fn)

      ext.commands["compact"].handler.("  summarize tests  ", nil)

      assert_receive {:compact_called, opts}
      assert opts[:custom_instructions] == "summarize tests"
    end
  end

  # ── /tree command registration ────────────────────────────────────────────

  describe "init/1 — tree command" do
    test "registers a command named 'tree'" do
      ext = ext_with_commands([])
      assert Map.has_key?(ext.commands, "tree")
    end

    test "'tree' has a description mentioning navigate" do
      ext = ext_with_commands([])
      assert ext.commands["tree"].description =~ ~r/navigate/i
    end
  end

  # ── parse_tree_args/1 ─────────────────────────────────────────────────────

  describe "parse_tree_args/1" do
    test "bare entry_id → :no summary" do
      assert Commands.parse_tree_args("abc123") == {"abc123", :no}
    end

    test "entry_id --summarize → :yes summary" do
      assert Commands.parse_tree_args("abc123 --summarize") == {"abc123", :yes}
    end

    test "entry_id --summarize with trailing space → :yes" do
      assert Commands.parse_tree_args("abc123 --summarize ") == {"abc123", :yes}
    end

    test "entry_id --summarize with instructions → {:yes, instructions}" do
      assert Commands.parse_tree_args("abc123 --summarize focus on auth") ==
               {"abc123", {:yes, "focus on auth"}}
    end

    test "extra spaces around entry_id are trimmed" do
      assert Commands.parse_tree_args("  abc123  ") == {"abc123", :no}
    end
  end

  # ── /tree handler ─────────────────────────────────────────────────────────

  describe "tree handler" do
    test "empty args returns error tuple" do
      ext = ext_with_commands([])
      result = ext.commands["tree"].handler.("", nil)
      assert {:error, _msg} = result
    end

    test "whitespace-only args returns error" do
      ext = ext_with_commands([])
      result = ext.commands["tree"].handler.("   ", nil)
      assert {:error, _msg} = result
    end

    test "entry_id calls navigate_tree with :no summary" do
      test_pid = self()
      nav_fn = fn opts -> send(test_pid, {:navigate, opts}) end
      ext = ext_with_commands([], fn _ -> :ok end, nav_fn)
      ext.commands["tree"].handler.("entry-1", nil)
      assert_receive {:navigate, opts}
      assert opts[:entry_id] == "entry-1"
      assert opts[:user_wants_summary] == :no
    end

    test "entry_id --summarize calls navigate_tree with :yes" do
      test_pid = self()
      nav_fn = fn opts -> send(test_pid, {:navigate, opts}) end
      ext = ext_with_commands([], fn _ -> :ok end, nav_fn)
      ext.commands["tree"].handler.("entry-1 --summarize", nil)
      assert_receive {:navigate, opts}
      assert opts[:user_wants_summary] == :yes
    end

    test "entry_id --summarize with instructions passes {:yes, instructions}" do
      test_pid = self()
      nav_fn = fn opts -> send(test_pid, {:navigate, opts}) end
      ext = ext_with_commands([], fn _ -> :ok end, nav_fn)
      ext.commands["tree"].handler.("entry-1 --summarize focus on tests", nil)
      assert_receive {:navigate, opts}
      assert opts[:user_wants_summary] == {:yes, "focus on tests"}
    end

    test "navigate_tree result is returned" do
      nav_fn = fn _opts -> {:ok, :navigated} end
      ext = ext_with_commands([], fn _ -> :ok end, nav_fn)
      result = ext.commands["tree"].handler.("entry-1", nil)
      assert result == {:ok, :navigated}
    end
  end

  describe "compact handler — integration" do
    test "compact with no args triggers Session.compact with empty opts" do
      test_pid = self()
      compact_fn = fn opts -> send(test_pid, {:compact_called, opts}) && :ok end
      ext = ext_with_commands([], compact_fn)

      result = ext.commands["compact"].handler.("", nil)

      assert_receive {:compact_called, []}
      assert result == :ok
    end

    test "compact with instructions triggers Session.compact with custom_instructions" do
      test_pid = self()

      compact_fn = fn opts ->
        send(test_pid, {:compact_called, opts})
        {:ok, %{summary: "done"}}
      end

      ext = ext_with_commands([], compact_fn)
      result = ext.commands["compact"].handler.("be concise", nil)

      assert_receive {:compact_called, [custom_instructions: "be concise"]}
      assert {:ok, _} = result
    end
  end
end
