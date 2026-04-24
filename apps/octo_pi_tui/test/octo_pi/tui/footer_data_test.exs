defmodule OctoPi.TUI.FooterDataTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.FooterData

  setup do
    dir = Path.join(System.tmp_dir!(), "footer_data_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "git branch detection" do
    test "reads branch from .git/HEAD", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")

      {:ok, pid} = FooterData.start_link(cwd: dir)
      assert "main" == FooterData.get_git_branch(pid)
    end

    test "detached HEAD shows short SHA", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, ".git/HEAD"), "abc1234deadbeef\n")

      {:ok, pid} = FooterData.start_link(cwd: dir)
      assert "abc1234" == FooterData.get_git_branch(pid)
    end

    test "no .git directory returns nil", %{dir: dir} do
      {:ok, pid} = FooterData.start_link(cwd: dir)
      assert nil == FooterData.get_git_branch(pid)
    end

    test "feature branch with slashes", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/feature/cool-thing\n")

      {:ok, pid} = FooterData.start_link(cwd: dir)
      assert "feature/cool-thing" == FooterData.get_git_branch(pid)
    end
  end

  describe "extension statuses" do
    test "starts empty", %{dir: dir} do
      {:ok, pid} = FooterData.start_link(cwd: dir)
      assert %{} == FooterData.get_extension_statuses(pid)
    end

    test "set and get extension status", %{dir: dir} do
      {:ok, pid} = FooterData.start_link(cwd: dir)
      FooterData.set_extension_status(pid, "mcp", "connected")
      assert %{"mcp" => "connected"} == FooterData.get_extension_statuses(pid)
    end

    test "clear removes extension status", %{dir: dir} do
      {:ok, pid} = FooterData.start_link(cwd: dir)
      FooterData.set_extension_status(pid, "mcp", "connected")
      FooterData.clear_extension_status(pid, "mcp")
      assert %{} == FooterData.get_extension_statuses(pid)
    end

    test "multiple extensions", %{dir: dir} do
      {:ok, pid} = FooterData.start_link(cwd: dir)
      FooterData.set_extension_status(pid, "a", "ready")
      FooterData.set_extension_status(pid, "b", "loading")
      statuses = FooterData.get_extension_statuses(pid)
      assert %{"a" => "ready", "b" => "loading"} == statuses
    end
  end
end
