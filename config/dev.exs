use Mix.Config

config :buildex_jobs,
  queue: "new_releases.queue",
  exchange: ""

config :buildex_jobs, :rabbitmq_config,
  channels: 1,
  queues: [
    [
      queue: "new_releases.queue",
      exchange: ""
    ]
  ]

config :buildex_jobs, :rabbitmq_conn_pool,
  pool_id: :connection_pool,
  name: {:local, :connection_pool},
  worker_module: ExRabbitPool.Worker.RabbitConnection,
  size: 1,
  max_overflow: 0

config :buildex_jobs, :consumers, 1
