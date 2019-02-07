use Mix.Config

config :buildex_jobs, :database, Buildex.Common.Services.FakeDatabase
config :logger, level: :warn
config :lager, handlers: [level: :critical]
