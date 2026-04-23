defmodule OctoPi.Coder.CLITest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.CLI

  describe "parse_args/1" do
    test "defaults to print mode with prompt from positional args" do
      assert {:ok, %{mode: :print, prompt: "hi there", model: _}} =
               CLI.parse_args(["hi", "there"])
    end

    test "recognizes --print flag with prompt" do
      assert {:ok, %{mode: :print, prompt: "hello"}} = CLI.parse_args(["--print", "hello"])
    end

    test "recognizes -p shorthand" do
      assert {:ok, %{mode: :print, prompt: "x"}} = CLI.parse_args(["-p", "x"])
    end

    test "--mode rpc selects rpc mode; no prompt required" do
      assert {:ok, %{mode: :rpc}} = CLI.parse_args(["--mode", "rpc"])
    end

    test "--model overrides the default" do
      assert {:ok, %{model: %{id: "claude-sonnet-4-5"}}} =
               CLI.parse_args(["--model", "claude-sonnet-4-5", "hi"])
    end

    test "--help returns a help sentinel" do
      assert {:help, _usage} = CLI.parse_args(["--help"])
    end

    test "print mode without a prompt yields :error" do
      assert {:error, _} = CLI.parse_args([])
    end
  end
end
