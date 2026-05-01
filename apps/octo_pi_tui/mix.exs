defmodule OctoPi.TUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :octo_pi_tui,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:leex] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OctoPi.TUI.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:octo_pi_tracer, in_umbrella: true},
      {:octo_pi_coder, in_umbrella: true},
      {:octo_pi_tui_terminal, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
