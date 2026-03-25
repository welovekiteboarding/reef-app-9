defmodule Symphony1.Runtime do
  alias Symphony1.Core.{Policy, QueueLauncher, QueueScheduler}
  alias Symphony1.Project.SetupIntent

  @setup_intent_path "config/symphony_setup.json"
  @workflow_path "priv/workflows/WORKFLOW.md"

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, run_attrs} <- build_run_attrs(Keyword.get(opts, :cwd, File.cwd!())),
         {:ok, workflow} <- Policy.load_workflow_config(run_attrs.workflow_path) do
      if Keyword.get(opts, :once, false) do
        launcher = Keyword.get(opts, :launcher, &QueueLauncher.launch/1)
        progress_reporter = Keyword.get(opts, :progress_reporter, fn _message -> :ok end)
        run_attrs = Map.put(run_attrs, :progress_reporter, progress_reporter)

        queue_scheduler =
          QueueScheduler.new(
            max_concurrent_agents: get_in(workflow, ["agent", "max_concurrent_agents"]) || 1,
            launcher: launcher
          )

        queue_scheduler = QueueScheduler.drain_once(queue_scheduler, run_attrs)
        case wait_for_active_runs(queue_scheduler) do
          {:ok, results} ->
            {:ok, %{queue_scheduler: queue_scheduler, results: results, run_attrs: run_attrs}}

          {:error, failures, results} ->
            {:error, {:issue_runs_failed, failures, results}}
        end
      else
        interval_ms = Keyword.get(opts, :interval_ms, 1_000)
        app_starter = Keyword.get(opts, :app_starter, &Application.ensure_all_started/1)

        Application.put_env(:symphony_1, :queue_runtime, %{
          enabled: true,
          interval_ms: interval_ms,
          run_attrs: run_attrs
        })

        {:ok, _apps} = app_starter.(:symphony_1)
        {:ok, %{run_attrs: run_attrs}}
      end
    end
  end

  @spec build_run_attrs(String.t()) :: {:ok, map()} | {:error, term()}
  def build_run_attrs(cwd \\ File.cwd!()) do
    workflow_path = workflow_path(cwd)

    with {:ok, intent} <- SetupIntent.load(Path.join(cwd, @setup_intent_path)),
         :ok <- ensure_workflow_exists(workflow_path),
         {:ok, workflow} <- Policy.load_workflow_config(workflow_path) do
      {:ok,
       %{
         base_branch: current_branch(cwd),
         body: "Implements the claimed issue.",
         linear_config: %{
           api_key: System.fetch_env!("LINEAR_API_KEY"),
           team_key: get_in(intent, ["linear", "team_key"])
         },
         repo: get_in(intent, ["github", "repo"]),
         source_repo: cwd,
         title: "Implement claimed issue",
         worker_timeout_ms: get_in(workflow, ["codex", "turn_timeout_ms"]) || 300_000,
         workflow_path: workflow_path,
         workspace_root: Path.expand(get_in(workflow, ["workspace", "root"]) || "./tmp/workspaces", cwd)
       }}
    end
  end

  defp workflow_path(cwd) do
    Path.join(cwd, @workflow_path)
  end

  defp ensure_workflow_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, {:workflow_not_found, path}}
  end

  defp current_branch(cwd) do
    case System.cmd("git", ["branch", "--show-current"], cd: cwd, stderr_to_stdout: true) do
      {branch, 0} ->
        String.trim(branch)

      {_output, _status} ->
        "main"
    end
  end

  defp wait_for_active_runs(queue_scheduler) do
    {results, failures} =
      queue_scheduler.active_runs
      |> Enum.map(fn {_ref, task} -> Task.await(task, :infinity) end)
      |> Enum.reduce({[], []}, fn
        {:ok, result}, {results, failures} ->
          {[result | results], failures}

        {:error, _reason} = error, {results, failures} ->
          {results, [error | failures]}

        result, {results, failures} ->
          {[result | results], failures}
      end)

    case failures do
      [] -> {:ok, Enum.reverse(results)}
      _ -> {:error, Enum.reverse(failures), Enum.reverse(results)}
    end
  end
end
