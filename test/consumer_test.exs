defmodule RepoJobs.ConsumerTest do
  # async: false to appease the ExUnit.CaptureLog
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExRabbitPool.FakeRabbitMQ
  alias ExRabbitPool.Worker.RabbitConnection
  alias RepoJobs.Consumer

  @queue "test.queue"

  setup do
    n = :rand.uniform(100)
    pool_id = String.to_atom("test_pool#{n}")
    caller = self()

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("POLLER_RMQ_PORT") || "5672"),
      queues: [
        [
          queue_name: @queue,
          exchange: "",
          queue_options: [auto_delete: true],
          exchange_options: [auto_delete: true]
        ]
      ],
      adapter: FakeRabbitMQ,
      caller: caller,
      reconnect: 10
    ]

    rabbitmq_conn_pool = [
      :rabbitmq_conn_pool,
      pool_id: pool_id,
      name: {:local, pool_id},
      worker_module: RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    Application.put_env(:buildex_jobs, :rabbitmq_config, rabbitmq_config)
    Application.put_env(:buildex_jobs, :queue, @queue)
    Application.put_env(:buildex_jobs, :exchange, "")

    start_supervised!(%{
      id: ExRabbitPool.PoolSupervisorTest,
      start:
        {ExRabbitPool.PoolSupervisor, :start_link,
         [
           [rabbitmq_config: rabbitmq_config, rabbitmq_conn_pool: rabbitmq_conn_pool],
           ExRabbitPool.PoolSupervisorTest
         ]},
      type: :supervisor
    })

    {:ok, pool_id: pool_id}
  end

  test "handles :basic_consume_ok message from the broker", %{pool_id: pool_id} do
    pid = start_supervised!({Consumer, {self(), pool_id}})
    send(pid, {:basic_consume_ok, %{consumer_tag: "tag"}})
    assert_receive :basic_consume_ok
  end

  test "handles :basic_cancel message from the broker", %{pool_id: pool_id} do
    log =
      capture_log(fn ->
        pid = start_supervised!({Consumer, pool_id}, restart: :temporary)
        ref = Process.monitor(pid)
        send(pid, {:basic_cancel, %{consumer_tag: "tag"}})
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end)

    assert log =~ "[consumer] consumer was cancelled by the broker (basic_cancel)"
  end

  test "handles :basic_cancel_ok message from the broker", %{pool_id: pool_id} do
    log =
      capture_log(fn ->
        pid = start_supervised!({Consumer, pool_id}, restart: :temporary)
        ref = Process.monitor(pid)
        send(pid, {:basic_cancel_ok, %{consumer_tag: "tag"}})
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end)

    assert log =~ "[consumer] consumer was cancelled by the broker (basic_cancel_ok)"
  end

  test "checks out a channel from the pool and doesn't return it back", %{pool_id: pool_id} do
    pid = start_supervised!({Consumer, pool_id})
    assert %{channel: channel, consumer_tag: "tag"} = Consumer.state(pid)
    conn_worker = :poolboy.checkout(pool_id)
    :ok = :poolboy.checkin(pool_id, conn_worker)
    assert %{channels: [], monitors: [monitor]} = RabbitConnection.state(conn_worker)
    assert {_ref, ^channel} = monitor
  end

  test "handles errors when trying to get a channel", %{pool_id: pool_id} do
    conn_worker = ExRabbitPool.get_connection_worker(pool_id)
    {:ok, channel} = ExRabbitPool.checkout_channel(conn_worker)

    log =
      capture_log(fn ->
        pid = start_supervised!({Consumer, pool_id})
        :timer.sleep(20)
        ExRabbitPool.checkin_channel(conn_worker, channel)
        :timer.sleep(20)
        assert %{channel: ^channel} = Consumer.state(pid)
      end)

    assert log =~ "[consumer] error getting channel reason: :out_of_channels"
  end
end
