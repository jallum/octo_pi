defmodule OctoPi.Coder.MixProject do
  use Mix.Project

  def project do
    [
      app: :octo_pi_coder,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.contains?(&1, "/fixtures/")],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :erlexec],
      mod: {OctoPi.Coder.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:octo_pi_tracer, in_umbrella: true},
      {:octo_pi_agent, in_umbrella: true},
      {:octo_pi_ai_openai, in_umbrella: true},
      {:erlexec, "~> 2.3"}
    ]
  end
end
