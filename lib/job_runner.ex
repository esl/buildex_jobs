defmodule RepoJobs.JobRunner do
  require Logger

  alias Buildex.Common.Tasks.Helpers.TempStore
  alias Buildex.Common.Jobs.NewReleaseJob
  alias Buildex.Common.Tasks.Task
  alias RepoJobs.Config

  @type env_tuple :: {String.t(), String.t()}
  @type env :: [env_tuple()]

  @doc """
  Fetch and Executes all tasks assigned to a new tag/release of a dependency,
  returning all tasks that succeeded as `{:ok, task}` and all that failed as
  `{:error, task}`
  """
  @spec run(NewReleaseJob.t()) :: {:ok, list(result)} | {:error, any()}
        when result: {:ok, Task.t()} | {:error, Task.t()}
  def run(job) do
    %{repo: %{owner: owner, name: repo_name, url: url}, new_tag: %{name: tag_name}} = job

    job_name = "#{owner}/#{repo_name}##{tag_name}"

    case Config.get_database().get_repo_tasks(url) do
      {:ok, tasks} ->
        env = generate_env(job)
        {:ok, Enum.map(tasks, &run_task(&1, job, env))}

      {:error, reason} = error ->
        Logger.error("error getting tasks for #{job_name} reason #{inspect(reason)}")
        error
    end
  end

  defp run_task(%Task{id: id, runner: runner, build_file_content: content} = task, job, env)
       when not is_nil(content) do
    %{
      repo: %{owner: owner, name: repo_name},
      new_tag: %{name: tag_name}
    } = job

    job_name = "#{owner}/#{repo_name}##{tag_name}"
    Logger.info("running task #{id} for #{job_name}")

    with :ok <- runner.exec(task, env) do
      Logger.info("successfully ran task #{id} for #{job_name}")
      {:ok, task}
    else
      {:error, error} ->
        Logger.error("error running task #{id} for #{job_name} reason: #{inspect(error)}")
        {:error, task}
    end
  end

  defp run_task(%Task{runner: runner, url: url, source: source} = task, job, env) do
    %{
      repo: %{owner: owner, name: repo_name},
      new_tag: %{name: tag_name}
    } = job

    job_name = "#{owner}/#{repo_name}##{tag_name}"
    # tmp_dir: /tmp/erlang/otp/21.0.2
    {:ok, tmp_dir} = TempStore.create_tmp_dir([owner, repo_name, tag_name], Config.temp_dir())
    Logger.info("running task #{url} for #{job_name}")

    with {:ok, task} <- source.fetch(task, tmp_dir),
         :ok <- runner.exec(task, env) do
      Logger.info("successfully ran task #{url} for #{job_name}")
      {:ok, task}
    else
      {:error, error} ->
        Logger.error("error running task #{url} for #{job_name} reason: #{inspect(error)}")

        {:error, task}
    end
  end

  # Returns a list of tuples to be passed as environment variables to each task
  @spec generate_env(NewReleaseJob.t()) :: env()
  defp generate_env(%{repo: %{name: repo_name}, new_tag: tag}) do
    # remove punctuation symbols
    repo_name =
      repo_name
      |> String.upcase()
      |> String.replace(~r/[!#$%()*+,\-.\/:;?@_`~]/, "_")

    %{
      name: tag_name,
      zipball_url: zipball_url,
      tarball_url: tarball_url,
      commit: %{sha: commit_tag}
    } = tag

    [
      {repo_name <> "_TAG", tag_name},
      {repo_name <> "_ZIP", zipball_url},
      {repo_name <> "_TAR", tarball_url},
      {repo_name <> "_COMMIT", commit_tag}
    ]
  end
end
