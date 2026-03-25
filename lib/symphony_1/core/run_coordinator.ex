defmodule Symphony1.Core.RunCoordinator do
  alias Symphony1.Core.{GitHub, Linear, Tracker, Worker, Workspace}
  alias Symphony1.Project.RepoAdapter

  @spec run_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_issue(%{
        issues: issues,
        workspace_root: workspace_root,
        workflow_path: workflow_path
      } = attrs) do
    with {:ok, issue} <- Tracker.poll_eligible_issue(issues),
         {:ok, in_progress_issue} <- Tracker.transition_issue(issue, "In Progress"),
         {:ok, workspace} <-
           Workspace.create(%{
             branch: Map.get(attrs, :branch, default_branch(issue.identifier)),
             issue_id: issue.identifier,
             root: workspace_root,
             source_repo: Map.get(attrs, :source_repo)
           }) do
      worker =
        Worker.local_run_spec(%{
          workspace: workspace,
          workflow_path: workflow_path
        })

      {:ok, %{issue: in_progress_issue, workspace: workspace, worker: worker}}
    end
  end

  def run_issue(%{
        linear_config: linear_config,
        workspace_root: workspace_root,
        workflow_path: workflow_path
      } = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)

    with {:ok, issue} <- Linear.poll_eligible_issue(linear_config, requester),
         {:ok, in_progress_issue} <-
           Linear.transition_issue(issue, "In Progress", linear_config, requester),
         {:ok, workspace} <-
           Workspace.create(%{
             branch: Map.get(attrs, :branch, default_branch(issue.identifier)),
             issue_id: issue.identifier,
             root: workspace_root,
             source_repo: Map.get(attrs, :source_repo)
           }) do
      worker =
        Worker.local_run_spec(%{
          workspace: workspace,
          workflow_path: workflow_path
        })

      {:ok, %{issue: in_progress_issue, workspace: workspace, worker: worker}}
    end
  end

  @spec run_full_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_full_issue(attrs) do
    with {:ok, run} <- run_issue(attrs) do
      finish_claimed_issue(run, attrs)
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_claimed_issue(map(), map()) :: {:ok, map()} | {:error, term()}
  def finish_claimed_issue(run, attrs) do
    github_runner = Map.get(attrs, :github_runner, &System.cmd/3)
    repo_finalizer = Map.get(attrs, :repo_finalizer, &RepoAdapter.finalize_workspace/2)
    progress_reporter = Map.get(attrs, :progress_reporter, fn _message -> :ok end)
    worker_adapter = Map.get(attrs, :worker, Worker)

    progress_reporter.("Running Codex for #{run.issue.identifier}")

    case execute_worker(run, attrs, worker_adapter) do
      {:ok, worker_result} ->
        case finalize_run(
               %{
                 base_branch: attrs.base_branch,
                 body: attrs.body,
                 issue: run.issue,
                 repo: attrs.repo,
                 title: attrs.title,
                 workspace: run.workspace
               },
               repo_finalizer,
               github_runner
             ) do
          {:ok, review} ->
            progress_reporter.("Opened PR for #{review.issue.identifier} (#{review.pull_request.url})")

            case transition_to_review(review.issue, attrs) do
              {:ok, issue} ->
                {:ok,
                 %{
                   finalization: review.finalization,
                   issue: issue,
                   pull_request: review.pull_request,
                   worker_result: worker_result,
                   workspace: review.workspace
                 }}

              {:error, reason} ->
                recover_failed_run(review.issue, attrs, :review_transition, reason)
            end

          {:error, reason} ->
            recover_failed_run(run.issue, attrs, :review_preparation, reason)
        end

      {:error, reason} ->
        recover_failed_run(run.issue, attrs, :worker_execution, reason)
    end
  end

  @spec open_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def open_review(%{workspace: workspace} = attrs, github_runner \\ &System.cmd/3) do
    title = Map.get(attrs, :title, default_pr_title(attrs.issue))
    body = Map.get(attrs, :body, default_pr_body(attrs.issue))

    with {:ok, branch} <- current_branch(workspace),
         {:ok, pull_request} <-
           GitHub.open_pull_request(
             %{
               base_branch: attrs.base_branch,
               body: body,
               branch: branch,
               cwd: workspace,
               repo: attrs.repo,
               title: title
             },
             github_runner
           ) do
      {:ok,
       %{
         issue: attrs.issue,
         finalization: Map.get(attrs, :finalization),
         pull_request: pull_request,
         workspace: workspace
       }}
    end
  end

  @spec finalize_run(map(), function(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def finalize_run(attrs, repo_boundary \\ &RepoAdapter.finalize_workspace/2, github_runner \\ &System.cmd/3)

  def finalize_run(attrs, validation_runner, github_runner) when is_function(validation_runner, 3) do
    repo_boundary = fn repo_attrs, _default_runner ->
      RepoAdapter.finalize_workspace(repo_attrs, validation_runner)
    end

    finalize_run(attrs, repo_boundary, github_runner)
  end

  def finalize_run(attrs, repo_boundary, github_runner) when is_function(repo_boundary, 2) do
    with {:ok, finalization} <- repo_boundary.(attrs, &System.cmd/3),
         {:ok, review} <- open_review(Map.put(attrs, :finalization, finalization), github_runner) do
      {:ok, review}
    end
  end

  @spec merge_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def merge_review(attrs, github_runner \\ &System.cmd/3) do
    cleanup = Map.get(attrs, :cleanup, &Workspace.cleanup/1)

    with {:ok, merging_issue, pull_request} <- merge_pull_request(attrs, github_runner),
         {:ok, done_issue} <- transition_to_done(merging_issue, attrs),
         :ok <- cleanup_workspace(attrs, cleanup) do
      {:ok,
       %{
         issue: done_issue,
         pull_request: pull_request,
         workspace: attrs.workspace
       }}
    end
  end

  defp merge_pull_request(%{issue: issue, pull_request: %{status: :merged} = pull_request}, _github_runner) do
    {:ok, issue, pull_request}
  end

  defp merge_pull_request(%{issue: issue, pull_request: pull_request} = attrs, github_runner) do
    with {:ok, merging_issue} <- transition_to_merging(issue, attrs),
         {:ok, merged_pull_request} <- GitHub.merge_pull_request(pull_request, github_runner) do
      {:ok, merging_issue, merged_pull_request}
    end
  end

  defp execute_worker(run, attrs, worker_adapter) do
    prompt = issue_prompt(run.issue, attrs)
    worker_opts = [timeout_ms: Map.get(attrs, :worker_timeout_ms, 60_000)]

    with {:ok, session} <- worker_start(worker_adapter, %{workspace: run.workspace, workflow_path: attrs.workflow_path}) do
      result = worker_run_prompt(worker_adapter, session, prompt, worker_opts)
      stop_result = worker_stop(worker_adapter, session)

      case {result, stop_result} do
        {{:ok, worker_result}, :ok} -> {:ok, worker_result}
        {{:error, _reason} = error, :ok} -> error
        {{:ok, _worker_result}, {:error, reason}} -> {:error, {:worker_stop_failed, reason}}
        {{:error, _reason} = error, {:error, _stop_reason}} -> error
      end
    end
  end

  defp transition_to_review(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Human Review", linear_config, requester)
  end

  defp transition_to_review(issue, _attrs) do
    Tracker.transition_issue(issue, "Human Review")
  end

  defp transition_to_merging(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Merging", linear_config, requester)
  end

  defp transition_to_merging(issue, _attrs) do
    Tracker.transition_issue(issue, "Merging")
  end

  defp transition_to_done(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Done", linear_config, requester)
  end

  defp transition_to_done(issue, _attrs) do
    Tracker.transition_issue(issue, "Done")
  end

  defp cleanup_workspace(%{workspace: workspace}, cleanup) do
    case cleanup.(workspace) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_cleanup_failed, workspace, reason}}
    end
  end

  defp cleanup_workspace(_attrs, _cleanup), do: :ok

  defp recover_failed_run(issue, attrs, stage, reason) do
    case transition_to_rework(issue, attrs) do
      {:ok, recovered_issue} -> {:error, {:run_failed, stage, recovered_issue, reason}}
      {:error, recovery_reason} -> {:error, {:run_failed, stage, issue, reason, {:recovery_failed, recovery_reason}}}
    end
  end

  defp transition_to_rework(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Rework", linear_config, requester)
  end

  defp transition_to_rework(issue, _attrs) do
    Tracker.transition_issue(issue, "Rework")
  end

  defp issue_prompt(issue, attrs) do
    [
      "Linear issue #{issue.identifier}: #{Map.get(issue, :title, "")}",
      issue_description(Map.get(issue, :description)),
      Map.get(attrs, :issue_prompt, "Implement the issue and leave the workspace ready for review.")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp issue_description(nil), do: nil
  defp issue_description(""), do: nil
  defp issue_description(description), do: "Description: #{description}"

  defp default_branch(issue_identifier) do
    "issue-" <> String.downcase(issue_identifier)
  end

  defp default_pr_title(%{identifier: issue_identifier}), do: "Implement #{issue_identifier}"
  defp default_pr_body(%{identifier: issue_identifier}), do: "Implements #{issue_identifier}"

  defp worker_start(worker_adapter, attrs) when is_map(worker_adapter), do: worker_adapter.start_session.(attrs)
  defp worker_start(worker_adapter, attrs), do: apply(worker_adapter, :start_session, [attrs])

  defp worker_run_prompt(worker_adapter, session, prompt, opts) when is_map(worker_adapter) do
    case :erlang.fun_info(worker_adapter.run_prompt, :arity) do
      {:arity, 3} -> worker_adapter.run_prompt.(session, prompt, opts)
      {:arity, 2} -> worker_adapter.run_prompt.(session, prompt)
    end
  end

  defp worker_run_prompt(worker_adapter, session, prompt, opts) do
    if function_exported?(worker_adapter, :run_prompt, 3) do
      apply(worker_adapter, :run_prompt, [session, prompt, opts])
    else
      apply(worker_adapter, :run_prompt, [session, prompt])
    end
  end

  defp worker_stop(worker_adapter, session) when is_map(worker_adapter), do: worker_adapter.stop_session.(session)
  defp worker_stop(worker_adapter, session), do: apply(worker_adapter, :stop_session, [session])

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end
end
