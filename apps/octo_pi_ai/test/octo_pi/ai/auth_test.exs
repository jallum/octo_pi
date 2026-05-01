defmodule OctoPi.AI.AuthTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Auth
  alias OctoPi.AI.Runner

  defmodule NoneRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :openai_completions
    @impl true
    def default_base_url, do: nil
    @impl true
    def auth, do: :none
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  defmodule EnvRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :anthropic_messages
    @impl true
    def default_base_url, do: "https://api.anthropic.com/v1"
    @impl true
    def auth, do: {:env, "OPI_AUTH_TEST_KEY"}
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  defmodule LiteralRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :openai_completions
    @impl true
    def default_base_url, do: "http://localhost:1234/v1"
    @impl true
    def auth, do: {:literal, "lm-studio"}
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  defmodule CmdRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :anthropic_messages
    @impl true
    def default_base_url, do: nil
    @impl true
    def auth, do: {:cmd, "echo from-cmd"}
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  defmodule BadCmdRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :openai_completions
    @impl true
    def default_base_url, do: nil
    @impl true
    def auth, do: {:cmd, "false"}
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  describe "resolve/3 with module default" do
    test ":none returns nil api key" do
      assert {:ok, nil} = Auth.resolve(NoneRunner, "x", auth_file: :none)
    end

    test "{:env, var} reads env var" do
      System.put_env("OPI_AUTH_TEST_KEY", "secret-123")
      on_exit(fn -> System.delete_env("OPI_AUTH_TEST_KEY") end)
      assert {:ok, "secret-123"} = Auth.resolve(EnvRunner, "x", auth_file: :none)
    end

    test "{:env, var} returns error when env unset" do
      System.delete_env("OPI_AUTH_TEST_KEY")
      assert {:error, {:env_unset, "OPI_AUTH_TEST_KEY"}} = Auth.resolve(EnvRunner, "x", auth_file: :none)
    end

    test "{:literal, val} returns val" do
      assert {:ok, "lm-studio"} = Auth.resolve(LiteralRunner, "x", auth_file: :none)
    end

    test "{:cmd, cmd} runs command and returns trimmed stdout" do
      assert {:ok, "from-cmd"} = Auth.resolve(CmdRunner, "x", auth_file: :none)
    end

    test "{:cmd, cmd} surfaces nonzero exit as error" do
      assert {:error, {:cmd_failed, "false", _exit, _out}} =
               Auth.resolve(BadCmdRunner, "x", auth_file: :none)
    end
  end

  describe "resolve/3 with auth.json override" do
    setup do
      path = Path.join(System.tmp_dir!(), "opi-auth-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      {:ok, auth_path: path}
    end

    test "auth.json {literal} overrides runner default", %{auth_path: path} do
      File.write!(path, ~s({"my-anthropic": {"literal": "from-json"}}))
      assert {:ok, "from-json"} = Auth.resolve(EnvRunner, "my-anthropic", auth_file: path)
    end

    test "auth.json {env} overrides runner default", %{auth_path: path} do
      System.put_env("OPI_AUTH_OVERRIDE_KEY", "from-override-env")
      on_exit(fn -> System.delete_env("OPI_AUTH_OVERRIDE_KEY") end)
      File.write!(path, ~s({"my-anthropic": {"env": "OPI_AUTH_OVERRIDE_KEY"}}))
      assert {:ok, "from-override-env"} = Auth.resolve(EnvRunner, "my-anthropic", auth_file: path)
    end

    test "auth.json without entry for runner falls back to module default", %{auth_path: path} do
      File.write!(path, ~s({"other-runner": {"literal": "irrelevant"}}))
      assert {:ok, "lm-studio"} = Auth.resolve(LiteralRunner, "lmstudio", auth_file: path)
    end

    test "missing auth.json file is not an error", %{auth_path: path} do
      refute File.exists?(path)
      assert {:ok, "lm-studio"} = Auth.resolve(LiteralRunner, "lmstudio", auth_file: path)
    end

    test "malformed auth.json returns clear error", %{auth_path: path} do
      File.write!(path, "{ not valid json")
      assert {:error, {:auth_json_parse, _}} = Auth.resolve(LiteralRunner, "x", auth_file: path)
    end

    test "auth.json entry with unknown strategy returns error", %{auth_path: path} do
      File.write!(path, ~s({"x": {"weird": "thing"}}))
      assert {:error, {:auth_json_invalid, "x", _}} = Auth.resolve(LiteralRunner, "x", auth_file: path)
    end
  end
end
