defmodule OctoPi.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "_build/#{Mix.env()}/plt"
      ],
      releases: releases()
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      octo_pi: [
        applications: [
          octo_pi_ai: :permanent,
          octo_pi_ai_anthropic: :permanent,
          octo_pi_agent: :permanent,
          octo_pi_coder: :permanent,
          octo_pi_tui: :permanent
        ]
      ]
    ]
  end
end
