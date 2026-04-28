defmodule OctoPi.AI.MixProject do
  use Mix.Project

  def project do
    [
      app: :octo_pi_ai,
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

  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {OctoPi.AI.Application, []}
    ]
  end

  defp deps do
    [
      {:octo_pi_tracer, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"}
    ]
  end
end
