defmodule RepoJobs.MixProject do
  use Mix.Project

  def project do
    [
      app: :buildex_jobs,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      organization: "esl",
      description: "listens on rabbitmq - runs buildex jobs",
      package: package(),
      source_url: "https://github.com/esl/buildex_jobs"
    ]
  end

  defp package() do
    [
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["Apache 2"],
      links: %{"GitHub" => "https://github.com/esl/buildex_jobs"}
    ]
  end


  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {RepoJobs.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_rabbit_pool, git: "https://github.com/esl/ex_rabbitmq_pool.git", branch: "master"},
      {:buildex_common, git: "https://github.com/esl/buildex_common.git", branch: "master"},
      {:poison, "~> 4.0"},
      {:httpoison, "~> 1.3.0"},
      {:mox, "~> 0.4", only: :test},
      {:credo, "~> 1.0.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10.4", only: [:dev, :test], runtime: false}
    ]
  end
end
