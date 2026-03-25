defmodule Symphony1.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_1,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:inets, :logger, :ssl],
      mod: {Symphony1.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
