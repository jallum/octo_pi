defmodule OctoPi.Coder.Extensions.AutoCommitOnExitTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.AutoCommitOnExit

  defp ext_with_exec(exec_fn) do
    factory = fn api ->
      api = API.bind_core(api, %{exec: exec_fn})
      AutoCommitOnExit.init(api)
    end

    {:ok, ext} = Loader.load_from_factory("auto-commit-on-exit", factory)
    ext
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  defp ctx_with_entries(entries), do: Context.new(%{cwd: "/tmp", get_messages: fn -> entries end})

  defp assistant_msg(text),
    do: %Assistant{
      api: :anthropic,
      provider: :anthropic,
      model: "claude-test",
      timestamp: 0,
      content: [%Text{text: text}]
    }

  defp shutdown_event, do: Event.new(:session_shutdown, %{reason: :exit})

  describe "init/1" do
    test "registers a session_shutdown handler" do
      ext = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert Map.has_key?(ext.handlers, :session_shutdown)
      assert length(ext.handlers[:session_shutdown]) == 1
    end

    test "registers no tools" do
      ext = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert ext.tools == %{}
    end

    test "registers no commands" do
      ext = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert ext.commands == %{}
    end
  end

  describe "session_shutdown handler" do
    test "does not commit when git status returns no changes" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})
        %{stdout: "", code: 0}
      end

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx())

      assert_receive {:exec, "git", ["status", "--porcelain"]}
      refute_receive {:exec, "git", ["add" | _]}
      refute_receive {:exec, "git", ["commit" | _]}
    end

    test "does not commit when git status returns non-zero (not a git repo)" do
      test_pid = self()

      exec_fn = fn _cmd, _args ->
        send(test_pid, :exec_called)
        %{stdout: "error", code: 128}
      end

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx())

      assert_receive :exec_called
      refute_receive :exec_called
    end

    test "stages and commits when there are changes" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})

        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx())

      assert_receive {:exec, "git", ["status", "--porcelain"]}
      assert_receive {:exec, "git", ["add", "-A"]}
      assert_receive {:exec, "git", ["commit", "-m", _]}
    end

    test "commit message starts with [pi] prefix" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} ->
            %{stdout: "M lib/foo.ex\n", code: 0}

          {"git", ["commit", "-m", msg]} ->
            send(test_pid, {:commit, msg})
            %{stdout: "", code: 0}

          _ ->
            %{stdout: "", code: 0}
        end
      end

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx())

      assert_receive {:commit, msg}
      assert String.starts_with?(msg, "[pi]")
    end

    test "commit message uses last assistant message text" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      entries = [assistant_msg("Fixed the authentication bug")]
      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries(entries))

      assert_receive {:commit, msg}
      assert msg == "[pi] Fixed the authentication bug"
    end

    test "commit message uses the last assistant message when multiple exist" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      entries = [
        assistant_msg("First response"),
        assistant_msg("Second response — the final one")
      ]

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries(entries))

      assert_receive {:commit, msg}
      assert msg == "[pi] Second response — the final one"
    end

    test "commit message truncates long text with ellipsis" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      long_text = String.duplicate("a", 60)
      entries = [assistant_msg(long_text)]
      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries(entries))

      assert_receive {:commit, msg}
      assert msg == "[pi] #{String.duplicate("a", 50)}..."
    end

    test "commit message uses first line of multi-line text" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      entries = [assistant_msg("Summary line\n\nMore details here")]
      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries(entries))

      assert_receive {:commit, msg}
      assert msg == "[pi] Summary line"
    end

    test "commit message falls back to Work in progress when entries is empty" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries([]))

      assert_receive {:commit, msg}
      assert msg == "[pi] Work in progress"
    end

    test "commit message falls back when no assistant messages in entries" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        case {cmd, args} do
          {"git", ["status", "--porcelain"]} -> %{stdout: "M lib/foo.ex\n", code: 0}
          {"git", ["commit", "-m", msg]} -> send(test_pid, {:commit, msg}) && %{stdout: "", code: 0}
          _ -> %{stdout: "", code: 0}
        end
      end

      user_msg = %OctoPi.AI.Message.User{
        content: [%Text{text: "do the thing"}],
        timestamp: 0
      }

      ext = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_shutdown])
      handler.(shutdown_event(), ctx_with_entries([user_msg]))

      assert_receive {:commit, msg}
      assert msg == "[pi] Work in progress"
    end
  end
end
