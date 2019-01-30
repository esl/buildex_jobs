defmodule RepoJobs.ConsumerSupervisor do
  use Supervisor

  alias RepoJobs.{Config, Consumer}

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    children =
      Config.get_consumers()
      |> case do
        # don't start any child and don't ask for pool configs (for testing only)
        nil ->
          []

        consumers ->
          pool_id = Config.get_connection_pool_id()

          for n <- 1..consumers do
            Supervisor.child_spec({Consumer, pool_id}, id: "consumer_#{n}")
          end
      end

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
