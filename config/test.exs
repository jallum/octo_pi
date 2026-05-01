import Config

config :octo_pi_ai,
  models_file: Path.expand("../apps/octo_pi_coder/priv/models.example.json", __DIR__),
  auth_file: :none
