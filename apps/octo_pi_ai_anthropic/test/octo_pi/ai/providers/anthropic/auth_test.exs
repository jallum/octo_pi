defmodule OctoPi.AI.Providers.Anthropic.AuthTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Providers.Anthropic.Auth
  alias OctoPi.AI.Providers.Anthropic.Auth.Credentials
  alias OctoPi.AI.Providers.Anthropic.Auth.NoopKeychain
  alias OctoPi.AI.StreamOptions

  # Remote-capture telemetry handler (avoids local-function perf warning).
  def __telemetry_forward__(name, meas, meta, %{pid: pid, ref: ref}) do
    send(pid, {ref, name, meas, meta})
  end

  # Test doubles for the keychain reader.
  defmodule FakeKeychain do
    @moduledoc false
    @behaviour OctoPi.AI.Providers.Anthropic.Auth.KeychainReader

    @impl true
    def read, do: Process.get(:fake_keychain_token)
  end

  setup do
    # All env vars cleared at the start of each test.
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_OAUTH_TOKEN")
    Application.put_env(:octo_pi_ai_anthropic, :keychain_reader, NoopKeychain)

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_OAUTH_TOKEN")
      Application.delete_env(:octo_pi_ai_anthropic, :keychain_reader)
      Process.delete(:fake_keychain_token)
    end)

    :ok
  end

  describe "resolve/1 — explicit opts" do
    test "opts.api_key wins over everything" do
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "sk-ant-oat-env")
      System.put_env("ANTHROPIC_API_KEY", "ak-env")

      assert %Credentials{type: :api_key, token: "ak-explicit"} =
               Auth.resolve(%StreamOptions{api_key: "ak-explicit"})
    end

    test "opts.api_key holding an OAuth token is classified as :oauth" do
      assert %Credentials{type: :oauth, token: "sk-ant-oat-xyz"} =
               Auth.resolve(%StreamOptions{api_key: "sk-ant-oat-xyz"})
    end

    test "empty opts.api_key falls through to env" do
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert %Credentials{token: "env-key"} = Auth.resolve(%StreamOptions{api_key: ""})
    end
  end

  describe "resolve/1 — env precedence" do
    test "ANTHROPIC_OAUTH_TOKEN wins over ANTHROPIC_API_KEY" do
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "sk-ant-oat-a")
      System.put_env("ANTHROPIC_API_KEY", "ak-b")

      assert %Credentials{type: :oauth, token: "sk-ant-oat-a"} = Auth.resolve()
    end

    test "ANTHROPIC_API_KEY used when OAuth env is unset" do
      System.put_env("ANTHROPIC_API_KEY", "ak-from-env")

      assert %Credentials{type: :api_key, token: "ak-from-env"} = Auth.resolve()
    end

    test "empty env values are treated as unset" do
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "")
      System.put_env("ANTHROPIC_API_KEY", "ak-real")

      assert %Credentials{token: "ak-real"} = Auth.resolve()
    end
  end

  describe "resolve/1 — keychain fallback" do
    test "keychain returns a token when env is empty" do
      Application.put_env(:octo_pi_ai_anthropic, :keychain_reader, FakeKeychain)
      Process.put(:fake_keychain_token, "sk-ant-oat-keychain")

      assert %Credentials{type: :oauth, token: "sk-ant-oat-keychain"} = Auth.resolve()
    end

    test "keychain used only after env vars" do
      Application.put_env(:octo_pi_ai_anthropic, :keychain_reader, FakeKeychain)
      Process.put(:fake_keychain_token, "sk-ant-oat-keychain")
      System.put_env("ANTHROPIC_API_KEY", "ak-env")

      # Env wins.
      assert %Credentials{token: "ak-env"} = Auth.resolve()
    end
  end

  describe "resolve/1 — no credentials" do
    test "raises with a helpful message" do
      assert_raise RuntimeError,
                   ~r/credentials not available.*ANTHROPIC_OAUTH_TOKEN.*Claude Code/s,
                   fn -> Auth.resolve() end
    end
  end

  describe "oauth?/1" do
    test "detects sk-ant-oat substring anywhere in the token" do
      assert Auth.oauth?("sk-ant-oat01-abc")
      assert Auth.oauth?("some-prefix-sk-ant-oat-xyz")
    end

    test "false for API keys" do
      refute Auth.oauth?("sk-ant-api03-xxx")
      refute Auth.oauth?("anything-else")
      refute Auth.oauth?("")
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler = "auth-telemetry-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:octo_pi_ai_anthropic, :auth, :resolved],
        &__MODULE__.__telemetry_forward__/4,
        %{pid: test_pid, ref: ref}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, ref: ref}
    end

    test "emits :resolved with source :opts on explicit api_key", %{ref: ref} do
      Auth.resolve(%StreamOptions{api_key: "ak-x"})
      assert_receive {^ref, [:octo_pi_ai_anthropic, :auth, :resolved], %{}, meta}
      assert meta == %{type: :api_key, source: :opts}
    end

    test "emits :resolved with source :env_oauth", %{ref: ref} do
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "sk-ant-oat-abc")
      Auth.resolve()
      assert_receive {^ref, _, %{}, %{type: :oauth, source: :env_oauth}}
    end

    test "emits :resolved with source :env_api_key", %{ref: ref} do
      System.put_env("ANTHROPIC_API_KEY", "ak-abc")
      Auth.resolve()
      assert_receive {^ref, _, %{}, %{type: :api_key, source: :env_api_key}}
    end

    test "emits :resolved with source :keychain", %{ref: ref} do
      Application.put_env(:octo_pi_ai_anthropic, :keychain_reader, FakeKeychain)
      Process.put(:fake_keychain_token, "sk-ant-oat-kc")

      Auth.resolve()
      assert_receive {^ref, _, %{}, %{type: :oauth, source: :keychain}}
    end
  end
end
