defmodule OctoPi.AI.Providers.Anthropic.Auth.MacKeychainTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Providers.Anthropic.Auth.MacKeychain

  describe "parse_token/1" do
    test "extracts accessToken from the Claude Code keychain blob" do
      json = """
      {
        "claudeAiOauth": {
          "accessToken": "sk-ant-oat01-redacted",
          "refreshToken": "sk-ant-ort01-redacted",
          "expiresAt": 1776971255609,
          "scopes": ["user:inference"],
          "subscriptionType": "max"
        },
        "organizationUuid": "6e0e284b-7db9-4ca9-a2e8-98baf9664932"
      }
      """

      assert {:ok, "sk-ant-oat01-redacted"} = MacKeychain.parse_token(json)
    end

    test "returns :error when accessToken is missing" do
      assert :error =
               MacKeychain.parse_token(~s({"claudeAiOauth": {"refreshToken": "x"}}))
    end

    test "returns :error when the top-level object isn't shaped like we expect" do
      assert :error = MacKeychain.parse_token(~s({"other": "thing"}))
    end

    test "returns :error when accessToken isn't a string" do
      assert :error =
               MacKeychain.parse_token(~s({"claudeAiOauth": {"accessToken": 123}}))
    end

    test "returns :error on malformed JSON" do
      assert :error = MacKeychain.parse_token("not json")
      assert :error = MacKeychain.parse_token("{bad")
      assert :error = MacKeychain.parse_token("")
    end
  end

  describe "read/0 — non-macOS path" do
    @tag :skip_on_macos
    test "returns nil on non-Darwin systems" do
      if :os.type() == {:unix, :darwin} do
        :skipped
      else
        assert MacKeychain.read() == nil
      end
    end
  end

  describe "read/0 — missing USER env var" do
    test "returns nil when USER is not set" do
      original = System.get_env("USER")

      try do
        System.delete_env("USER")
        assert MacKeychain.read() == nil
      after
        if original, do: System.put_env("USER", original)
      end
    end
  end

  describe "read/0 — integration (macOS, Claude Code logged in)" do
    # Gated on env var + macOS + real entry. Skipped by default.
    @tag :integration
    test "returns an sk-ant-oat token when Claude Code is logged in" do
      case MacKeychain.read() do
        nil ->
          flunk("Expected Claude Code keychain entry to be present. Log in to Claude Code and rerun.")

        token ->
          assert String.starts_with?(token, "sk-ant-oat")
      end
    end
  end
end
