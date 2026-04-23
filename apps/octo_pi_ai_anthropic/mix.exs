defmodule OctoPi.AI.Providers.Anthropic.MixProject do
  use Mix.Project

  def project do
    [
      app: :octo_pi_ai_anthropic,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OctoPi.AI.Providers.Anthropic.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:octo_pi_ai, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.19", only: [:test]}
    ]
  end
end
