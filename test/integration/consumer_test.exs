defmodule RepoJobs.Integration.ConsumerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ExRabbitPool.RabbitMQ
  alias ExRabbitPool.Worker.RabbitConnection
  alias RepoJobs.Consumer
  alias AMQP.{Connection, Channel, Queue}
  alias Buildex.Common.Jobs.NewReleaseJob
  alias Buildex.Common.Serializers.NewReleaseJobSerializer
  alias Buildex.Common.Repos.Repo
  alias Buildex.Common.Tags.Tag
  alias Buildex.Common.Tasks.Task

  @moduletag :integration
  @queue "test.consumer.queue"

  setup do
    n = :rand.uniform(100)
    pool_id = String.to_atom("test_pool#{n}")

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("POLLER_RMQ_PORT") || "5672"),
      queue: @queue,
      exchange: "",
      adapter: RabbitMQ
    ]

    rabbitmq_conn_pool = [
      :rabbitmq_conn_pool,
      pool_id: pool_id,
      name: {:local, pool_id},
      worker_module: RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    {:ok, conn} = Connection.open(rabbitmq_config)
    {:ok, channel} = Channel.open(conn)

    on_exit(fn ->
      {:ok, _} = Queue.delete(channel, @queue)
      :ok = Channel.close(channel)
      :ok = Connection.close(conn)
    end)

    Application.put_env(:buildex_jobs, :rabbitmq_config, rabbitmq_config)
    Application.put_env(:buildex_jobs, :database, Buildex.Common.Service.MockDatabase)

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

    {:ok, pool_id: pool_id, channel: channel}
  end

  test "handles channel crashes", %{pool_id: pool_id} do
    log =
      capture_log(fn ->
        pid = start_supervised!({Consumer, pool_id})
        assert %{channel: channel} = Consumer.state(pid)
        :erlang.trace(pid, true, [:receive])
        %{pid: channel_pid} = channel
        :ok = Channel.close(channel)
        # channel is down
        assert_receive {:trace, ^pid, :receive, {:DOWN, _ref, :process, ^channel_pid, :normal}}
        # attempt to reconnect
        assert_receive {:trace, ^pid, :receive, :connect}
        # consuming messages again
        assert_receive {:trace, ^pid, :receive,
                        {:basic_consume_ok, %{consumer_tag: _consumer_tag}}}

        assert %{channel: channel2} = Consumer.state(pid)
        refute channel == channel2
      end)

    assert log =~ "[error] [consumer] channel down reason: :normal"
    assert log =~ "[error] [Rabbit] channel lost, attempting to reconnect reason: :normal"
  end

  test "consumes messaged published to the queue", %{channel: channel, pool_id: pool_id} do
    start_supervised!({Consumer, {self(), pool_id}})

    payload =
      "{\"repo\":{\"url\":\"https://github.com/elixir-lang/elixir\",\"tasks\":[],\"polling_interval\":3600000,\"owner\":\"elixir-lang\",\"name\":\"elixir\"},\"new_tag\":{\"zipball_url\":\"https://api.github.com/repos/elixir-lang/elixir/zipball/v1.7.2\",\"tarball_url\":\"https://api.github.com/repos/elixir-lang/elixir/tarball/v1.7.2\",\"node_id\":\"MDM6UmVmMTIzNDcxNDp2MS43LjI=\",\"name\":\"v1.7.2\",\"commit\":{\"url\":\"https://api.github.com/repos/elixir-lang/elixir/commits/2b338092b6da5cd5101072dfdd627cfbb49e4736\",\"sha\":\"2b338092b6da5cd5101072dfdd627cfbb49e4736\"}}}"

    :ok = RabbitMQ.publish(channel, "", @queue, payload)
    assert_receive {:new_release_job, job}, 1000

    assert job == %NewReleaseJob{
             new_tag: %Tag{
               commit: %{
                 sha: "2b338092b6da5cd5101072dfdd627cfbb49e4736",
                 url:
                   "https://api.github.com/repos/elixir-lang/elixir/commits/2b338092b6da5cd5101072dfdd627cfbb49e4736"
               },
               name: "v1.7.2",
               node_id: "MDM6UmVmMTIzNDcxNDp2MS43LjI=",
               tarball_url: "https://api.github.com/repos/elixir-lang/elixir/tarball/v1.7.2",
               zipball_url: "https://api.github.com/repos/elixir-lang/elixir/zipball/v1.7.2"
             },
             repo: %Repo{
               url: "https://github.com/elixir-lang/elixir",
               name: "elixir",
               owner: "elixir-lang",
               tags: [],
               polling_interval: 3_600_000
             }
           }
  end

  describe "process jobs" do
    # Make sure mocks are verified when the test exits
    setup :verify_on_exit!
    # Allow any process to consume mocks and stubs defined in tests.
    setup :set_mox_global

    setup do
      tag = %Tag{
        commit: %{
          sha: "",
          url: ""
        },
        name: "v1.7.2",
        node_id: "",
        tarball_url: "tarball/v1.7.2",
        zipball_url: "zipball/v1.7.2"
      }

      repo =
        Repo.new("https://github.com/elixir-lang/elixir")
        |> Repo.add_tags([tag])

      {:ok, repo: repo}
    end

    test "successfully process one job's task", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, [task1, task2]}
      end)

      Buildex.Common.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Buildex.Common.TaskMockRunner
      |> expect(:exec, 2, fn _task, _env -> :ok end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      :ok = RabbitMQ.publish(channel, "", @queue, payload)
      assert_receive {:new_release_job, _}, 1000
      assert_receive {:ack, task_results}, 1000
      assert [{:ok, ^task1}, {:ok, ^task2}] = task_results
    end

    test "successfully process job without tasks", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, []}
      end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      :ok = RabbitMQ.publish(channel, "", @queue, payload)
      assert_receive {:new_release_job, _}, 1000
      assert_receive {:ack, []}, 1000
    end

    test "failed to process job's tasks", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, [task1, task2]}
      end)

      Buildex.Common.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Buildex.Common.TaskMockRunner
      |> expect(:exec, 2, fn
        ^task1, _env -> {:error, :eaccess}
        ^task2, _env -> :ok
      end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      log =
        capture_log(fn ->
          :ok = RabbitMQ.publish(channel, "", @queue, payload)
          assert_receive {:new_release_job, _}, 1000
          assert_receive {:ack, task_results}, 1000
          assert [{:error, ^task1}, {:ok, ^task2}] = task_results
        end)

      assert log =~
               "[error] error running task https://github.com/f@k31/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
    end

    test "failed to process all job's tasks", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Buildex.Common.TaskMockRunner,
        source: Buildex.Common.TaskMockSource
      }

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, [task1, task2]}
      end)

      Buildex.Common.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Buildex.Common.TaskMockRunner
      |> expect(:exec, 2, fn _task, _env -> {:error, :eaccess} end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      log =
        capture_log(fn ->
          :ok = RabbitMQ.publish(channel, "", @queue, payload)
          assert_receive {:new_release_job, _}, 1000
          assert_receive {:reject, task_results}, 1000
          assert [{:error, ^task1}, {:error, ^task2}] = task_results
        end)

      assert log =~
               "[error] error running task https://github.com/f@k31/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"

      assert log =~
               "[error] error running task https://github.com/f@k32/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
    end

    # Silence crash logs
    @tag capture_log: true
    test "exception running job's tasks rejects job", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task = %Task{id: 1, runner: Buildex.Common.TaskMockRunner, build_file_content: "This is a test"}

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, [task]}
      end)

      Buildex.Common.TaskMockRunner
      |> expect(:exec, fn
        _task, _env -> raise "kaboom"
      end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      :ok = RabbitMQ.publish(channel, "", @queue, payload)
      assert_receive {:new_release_job, _}, 1000
      assert_receive {:reject, %RuntimeError{message: "kaboom"}}, 1000
    end

    test "successfully process a dockerbuild task", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task = %Task{id: 1, runner: Buildex.Common.TaskMockRunner, build_file_content: "This is a test"}

      Buildex.Common.Service.MockDatabase
      |> expect(:get_repo_tasks, fn _url ->
        {:ok, [task]}
      end)

      Buildex.Common.TaskMockRunner
      |> expect(:exec, fn _task, _env -> :ok end)

      payload =
        repo
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      :ok = RabbitMQ.publish(channel, "", @queue, payload)
      assert_receive {:new_release_job, _}, 1000
      assert_receive {:ack, task_results}, 1000
      assert [{:ok, ^task}] = task_results
    end
  end
end
