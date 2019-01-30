defmodule RepoJobs.Consumer do
  use GenServer

  require Logger

  alias Buildex.Common.Serializers.NewReleaseJobSerializer
  alias RepoJobs.{Config, JobRunner}

  defmodule State do
    @moduledoc """
    RabbitMQ Consumer Worker State.

    State attributes:

      * `:pool_id` - the name of the connection pool to RabbitMQ
      * `:channel` - the RabbitMQ channel for consuming new messages
      * `:monitor` - a monitor for handling channel crashes
      * `:consumer_tag` - the consumer tag assigned by RabbitMQ
    """
    @enforce_keys [:pool_id]

    @typedoc "Consumer State Type"
    @type t :: %__MODULE__{
            pool_id: atom(),
            caller: pid(),
            channel: AMQP.Channel.t(),
            monitor: reference(),
            consumer_tag: String.t()
          }
    defstruct pool_id: nil, caller: nil, channel: nil, monitor: nil, consumer_tag: nil
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def state(pid) do
    GenServer.call(pid, :state)
  end

  ####################
  # Server Callbacks #
  ####################

  @impl true
  # @private test only
  def init({caller, pool_id}) do
    send(self(), :connect)
    {:ok, %State{caller: caller, pool_id: pool_id}}
  end

  def init(pool_id) do
    send(self(), :connect)
    {:ok, %State{pool_id: pool_id}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # Gets a connection worker out of the connection pool, if there is one available
  # takes a channel out of it channel pool, if there is one available subscribe
  # itself as a consumer process.
  @impl true
  def handle_info(:connect, %{pool_id: pool_id} = state) do
    pool_id
    |> ExRabbitPool.get_connection_worker()
    |> ExRabbitPool.checkout_channel()
    |> handle_channel_checkout(state)
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, chan_pid, reason},
        %{monitor: monitor, channel: %{pid: chan_pid}} = state
      ) do
    Logger.error("[consumer] channel down reason: #{inspect(reason)}")
    schedule_connect()
    {:noreply, %State{state | monitor: nil, consumer_tag: nil, channel: nil}}
  end

  ################################
  # AMQP Basic.Consume Callbacks #
  ################################

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, %{caller: caller} = state) do
    Logger.info("[consumer] successfully registered as a consumer (basic_consume_ok)")
    if caller, do: send(caller, :basic_consume_ok)
    {:noreply, state}
  end

  # This is sent for each message consumed, where `payload` contains the message
  # content and `meta` contains all the metadata set when sending with
  # Basic.publish or additional info set by the broker;
  def handle_info(
        {:basic_deliver, payload, %{delivery_tag: delivery_tag}},
        %{caller: caller, channel: channel} = state
      ) do
    Logger.info("[consumer] consuming payload")

    job = NewReleaseJobSerializer.deserialize!(payload)

    if caller, do: send(caller, {:new_release_job, job})

    %{
      repo: %{owner: owner, name: repo_name},
      new_tag: %{name: tag_name}
    } = job

    job_name = "#{owner}/#{repo_name}##{tag_name}"
    client = Config.get_rabbitmq_client()

    try do
      # TODO: Maybe create a worker pool to execute jobs in parallel
      case JobRunner.run(job) do
        {:ok, []} ->
          :ok = client.ack(channel, delivery_tag, requeue: false)
          if caller, do: send(caller, {:ack, []})
          {:noreply, state}

        {:ok, task_results} ->
          # if all tasks failed re-schedule the job
          Enum.all?(task_results, fn
            {:error, _} -> true
            _ -> false
          end)
          |> if do
            # TODO: Make requeuing configurable
            :ok = client.reject(channel, delivery_tag, requeue: true)
            if caller, do: send(caller, {:reject, task_results})
          else
            # TODO: Make requeuing configurable
            :ok = client.ack(channel, delivery_tag, requeue: false)
            Logger.info("successfully ran job #{job_name}")
            if caller, do: send(caller, {:ack, task_results})
          end

          {:noreply, state}

        {:error, error} ->
          Logger.info("[consumer] error running job reason #{inspect(error)}")
          # TODO: Make requeuing configurable
          :ok = client.reject(channel, delivery_tag, requeue: true)
          if caller, do: send(caller, {:reject, error})
          {:noreply, state}
      end
    rescue
      exception ->
        :ok = client.reject(channel, delivery_tag, requeue: true)
        if caller, do: send(caller, {:reject, exception})
        {:noreply, state}
    end
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel)")
    {:stop, :normal, %State{state | channel: nil}}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel_ok)")
    {:stop, :normal, %State{state | channel: nil}}
  end

  # When successfully checks out a channel, subscribe itself as a consumer
  # process and monitors it handle crashes and reconnections
  defp handle_channel_checkout({:ok, %{pid: channel_pid} = channel}, %State{} = state) do
    case handle_consume(channel) do
      {:ok, consumer_tag} ->
        ref = Process.monitor(channel_pid)
        {:noreply, %State{state | channel: channel, monitor: ref, consumer_tag: consumer_tag}}

      {:error, reason} ->
        Logger.error("[consumer] error consuming channel reason: #{inspect(reason)}")
        schedule_connect()
        {:noreply, %State{state | channel: nil, consumer_tag: nil}}
    end
  end

  # When there was an error checking out a channel, retry in a configured interval
  defp handle_channel_checkout({:error, reason}, state) do
    # TODO: use exponential backoff to reconnect
    # TODO: use circuit breaker to fail fast
    Logger.error("[consumer] error getting channel reason: #{inspect(reason)}")

    Config.get_rabbitmq_reconnection_interval()
    |> :timer.sleep()

    schedule_connect()
    {:noreply, state}
  end

  defp handle_consume(channel) do
    queue = Config.get_rabbitmq_queue()
    config = Config.get_rabbitmq_config()
    Config.get_rabbitmq_client().consume(channel, queue, self(), config)
  end

  defp schedule_connect() do
    send(self(), :connect)
  end
end
