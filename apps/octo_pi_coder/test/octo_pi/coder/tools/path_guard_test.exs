defmodule OctoPi.Coder.Tools.PathGuardTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Tool.Result
  alias OctoPi.Coder.Tools.PathGuard

  describe "resolve/2" do
    test "absolute path within cwd passes through" do
      assert {:ok, "/workspace/app/foo.ex"} =
               PathGuard.resolve("/workspace/app/foo.ex", "/workspace/app")
    end

    test "cwd itself resolves to cwd" do
      assert {:ok, "/workspace/app"} = PathGuard.resolve("/workspace/app", "/workspace/app")
    end

    test "relative path is joined to cwd" do
      assert {:ok, "/workspace/app/foo.ex"} = PathGuard.resolve("foo.ex", "/workspace/app")
    end

    test "dot-segment is normalized" do
      assert {:ok, "/workspace/app/foo.ex"} =
               PathGuard.resolve("./sub/../foo.ex", "/workspace/app")
    end

    test "parent-escape via ..  is rejected" do
      assert {:error, {:escapes_cwd, "/workspace/secret"}} =
               PathGuard.resolve("../secret", "/workspace/app")
    end

    test "absolute escape outside cwd is rejected" do
      assert {:error, {:escapes_cwd, "/etc/passwd"}} =
               PathGuard.resolve("/etc/passwd", "/workspace/app")
    end

    test "sibling path with shared prefix is rejected" do
      # `/workspace/app-backup` must NOT be treated as "inside
      # /workspace/app" just because the string starts the same.
      assert {:error, {:escapes_cwd, "/workspace/app-backup/x"}} =
               PathGuard.resolve("/workspace/app-backup/x", "/workspace/app")
    end
  end

  describe "resolve_or_error/2" do
    test "success returns {:ok, abs}" do
      assert {:ok, "/root/foo"} = PathGuard.resolve_or_error("foo", "/root")
    end

    test "escape returns {:error, %Tool.Result{}} ready to return" do
      assert {:error, %Result{is_error?: true, content: [_]}} =
               PathGuard.resolve_or_error("/etc/passwd", "/root")
    end
  end
end
