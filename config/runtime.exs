import Config

# On macOS in dev/prod, read Claude Code's OAuth token from the login
# keychain when no ANTHROPIC_* env var is set. Tests stay on the noop
# reader so they don't touch the real keychain.
if config_env() != :test and :os.type() == {:unix, :darwin} do
  config :octo_pi_ai_anthropic,
    keychain_reader: OctoPi.AI.Providers.Anthropic.Auth.MacKeychain
end
