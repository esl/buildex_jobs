defmodule RepoJobs.JobRunnerTest do
  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias RepoJobs.JobRunner
  alias Buildex.Common.Repos.Repo
  alias Buildex.Common.Tags.Tag
  alias Buildex.Common.Tasks.Task
  alias Buildex.Common.Jobs.NewReleaseJob

  @moduletag :integration

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  setup do
    n = :rand.uniform(100)
    # create random directory so it can run concurrently
    base_dir = Path.join([File.cwd!(), "test", "fixtures", "temp", to_string(n)])

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

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

    Application.put_env(:buildex_jobs, :tmp_dir, base_dir)
    Application.put_env(:buildex_jobs, :database, Buildex.Common.Service.MockDatabase)
    {:ok, repo: repo}
  end

  test "runs a task on job", %{repo: repo} do
    %{tags: [tag]} = repo

    task = %Task{
      url: "https://github.com/f@k3/fake",
      runner: Buildex.Common.TaskMockRunner,
      source: Buildex.Common.TaskMockSource
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task]}
    end)

    Buildex.Common.TaskMockSource
    |> expect(:fetch, fn task, _tmp_dir ->
      {:ok, task}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, fn _task, env ->
      assert env == [
               {"ELIXIR_TAG", tag.name},
               {"ELIXIR_ZIP", tag.zipball_url},
               {"ELIXIR_TAR", tag.tarball_url},
               {"ELIXIR_COMMIT", ""}
             ]

      :ok
    end)

    assert {:ok, [{:ok, ^task}]} =
             repo
             |> NewReleaseJob.new(tag)
             |> JobRunner.run()
  end

  test "fails to run a task on job", %{repo: repo} do
    %{tags: [tag]} = repo

    task = %Task{
      url: "https://github.com/f@k3/fake",
      runner: Buildex.Common.TaskMockRunner,
      source: Buildex.Common.TaskMockSource
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task]}
    end)

    Buildex.Common.TaskMockSource
    |> expect(:fetch, fn task, _tmp_dir ->
      {:ok, task}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, fn _task, _env ->
      {:error, :eaccess}
    end)

    log =
      capture_log(fn ->
        assert {:ok, [{:error, ^task}]} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()
      end)

    assert log =~
             "[error] error running task https://github.com/f@k3/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
  end

  test "fails to get a task on job", %{repo: repo} do
    %{tags: [tag]} = repo

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:error, :nodedown}
    end)

    log =
      capture_log(fn ->
        assert {:error, :nodedown} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()
      end)

    assert log =~ "[error] error getting tasks for elixir-lang/elixir#v1.7.2 reason :nodedown"
  end

  test "fails to fetch a task", %{repo: repo} do
    %{tags: [tag]} = repo

    task = %Task{
      url: "https://github.com/f@k3/fake",
      runner: Buildex.Common.TaskMockRunner,
      source: Buildex.Common.TaskMockSource
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task]}
    end)

    Buildex.Common.TaskMockSource
    |> expect(:fetch, fn _task, _tmp_dir ->
      {:error, :eaccess}
    end)

    log =
      capture_log(fn ->
        assert {:ok, [{:error, ^task}]} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()
      end)

    assert log =~
             "[error] error running task https://github.com/f@k3/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
  end

  test "runs multiple tasks on a job", %{repo: repo} do
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
    |> expect(:fetch, 2, fn task, _tmp_dir ->
      {:ok, task}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, 2, fn _task, env ->
      assert env == [
               {"ELIXIR_TAG", tag.name},
               {"ELIXIR_ZIP", tag.zipball_url},
               {"ELIXIR_TAR", tag.tarball_url},
               {"ELIXIR_COMMIT", ""}
             ]

      :ok
    end)

    assert {:ok, [result1, result2]} =
             repo
             |> Repo.set_tasks([task1, task2])
             |> NewReleaseJob.new(tag)
             |> JobRunner.run()

    assert {:ok, ^task1} = result1
    assert {:ok, ^task2} = result2
  end

  test "fails to run one of multiple tasks", %{repo: repo} do
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
    |> expect(:fetch, 2, fn task, _tmp_dir ->
      {:ok, task}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, 2, fn
      ^task1, _env -> {:error, :eaccess}
      ^task2, _env -> :ok
    end)

    log =
      capture_log(fn ->
        assert {:ok, [result1, result2]} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()

        assert {:error, ^task1} = result1
        assert {:ok, ^task2} = result2
      end)

    assert log =~
             "[error] error running task https://github.com/f@k31/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
  end

  test "fails to fetch one of multiple tasks", %{repo: repo} do
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
    |> expect(:fetch, 2, fn
      ^task1, _tmp_dir -> {:ok, task1}
      ^task2, _tmp_dir -> {:error, :eaccess}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, 1, fn _task, _env -> :ok end)

    log =
      capture_log(fn ->
        assert {:ok, [result1, result2]} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()

        assert {:ok, ^task1} = result1
        assert {:error, ^task2} = result2
      end)

    assert log =~
             "[error] error running task https://github.com/f@k32/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
  end

  test "run a task with build_file", %{repo: repo} do
    %{tags: [tag]} = repo

    task = %Task{
      id: 1,
      runner: Buildex.Common.TaskMockRunner,
      build_file_content: "This is a test"
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task]}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, fn ^task, env ->
      assert env == [
               {"ELIXIR_TAG", tag.name},
               {"ELIXIR_ZIP", tag.zipball_url},
               {"ELIXIR_TAR", tag.tarball_url},
               {"ELIXIR_COMMIT", ""}
             ]

      :ok
    end)

    assert {:ok, [{:ok, ^task}]} =
             repo
             |> NewReleaseJob.new(tag)
             |> JobRunner.run()
  end

  test "fails to run a task with build_file", %{repo: repo} do
    %{tags: [tag]} = repo

    task = %Task{
      id: 1,
      runner: Buildex.Common.TaskMockRunner,
      build_file_content: "This is a test"
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task]}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, 1, fn _task, _env -> {:error, :no_container} end)

    log =
      capture_log(fn ->
        assert {:ok, [{:error, ^task}]} =
                 repo
                 |> NewReleaseJob.new(tag)
                 |> JobRunner.run()
      end)

    assert log =~
             "[error] error running task 1 for elixir-lang/elixir#v1.7.2 reason: :no_container"
  end

  test "runs multiple types of tasks", %{repo: repo} do
    %{tags: [tag]} = repo

    task1 = %Task{
      id: 1,
      runner: Buildex.Common.TaskMockRunner,
      build_file_content: "This is a test"
    }

    task2 = %Task{
      url: "https://github.com/f@k3/fake",
      runner: Buildex.Common.TaskMockRunner,
      source: Buildex.Common.TaskMockSource
    }

    Buildex.Common.Service.MockDatabase
    |> expect(:get_repo_tasks, fn _url ->
      {:ok, [task1, task2]}
    end)

    Buildex.Common.TaskMockSource
    |> expect(:fetch, fn task, _tmp_dir ->
      {:ok, task}
    end)

    Buildex.Common.TaskMockRunner
    |> expect(:exec, 2, fn _task, _env -> :ok end)

    assert {:ok, [{:ok, ^task1}, {:ok, ^task2}]} =
             repo
             |> NewReleaseJob.new(tag)
             |> JobRunner.run()
  end
end
