defmodule Symphony1.MergeRuntime do
  alias Symphony1.Core.{GitHub, Linear, RunCoordinator, Workspace}
  alias Symphony1.Project.SetupIntent

  @setup_intent_path "config/symphony_setup.json"
  @workspace_root_segments ["tmp", "workspaces"]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, merge_attrs} <- build_merge_attrs(Keyword.get(opts, :cwd, File.cwd!())) do
      if Keyword.get(opts, :once, false) do
        merge_once(merge_attrs, opts)
      else
        interval_ms = Keyword.get(opts, :interval_ms, 1_000)
        app_starter = Keyword.get(opts, :app_starter, &Application.ensure_all_started/1)

        Application.put_env(:symphony_1, :merge_runtime, %{
          enabled: true,
          interval_ms: interval_ms,
          merge_attrs: merge_attrs
        })

        {:ok, _apps} = app_starter.(:symphony_1)
        {:ok, %{merge_attrs: merge_attrs}}
      end
    end
  end

  @spec build_merge_attrs(String.t()) :: {:ok, map()} | {:error, term()}
  def build_merge_attrs(cwd \\ File.cwd!()) do
    with {:ok, intent} <- SetupIntent.load(Path.join(cwd, @setup_intent_path)) do
      {:ok,
       %{
         linear_config: %{
           api_key: System.fetch_env!("LINEAR_API_KEY"),
           team_key: get_in(intent, ["linear", "team_key"])
         },
         repo: get_in(intent, ["github", "repo"]),
         workspace: cwd
       }}
    end
  end

  defp merge_once(merge_attrs, opts) do
    linear_poller =
      Keyword.get(
        opts,
        :linear_poller,
        fn config -> Linear.poll_issue_in_state(config, "Human Review") end
      )

    github_resolver =
      Keyword.get(
        opts,
        :github_resolver,
        fn attrs -> GitHub.find_pull_request_by_branch(attrs) end
      )

    merge_runner = Keyword.get(opts, :merge_runner, &RunCoordinator.merge_review/2)
    github_runner = Keyword.get(opts, :github_runner, &System.cmd/3)

    case linear_poller.(merge_attrs.linear_config) do
      {:ok, issue} ->
        branch = "issue-" <> String.downcase(issue.identifier)
        issue_workspace = issue_workspace_path(merge_attrs.workspace, issue.identifier)

        with {:ok, pull_request} <-
               github_resolver.(%{
                 branch: branch,
                 repo: merge_attrs.repo,
                 workspace: merge_attrs.workspace,
                 cwd: merge_attrs.workspace
               }),
             {:ok, result} <-
               merge_runner.(
                 %{
                   issue: issue,
                   linear_config: merge_attrs.linear_config,
                   pull_request: pull_request,
                   workspace: issue_workspace
                 },
                 github_runner
               ) do
          {:ok, %{results: [result], merge_attrs: merge_attrs}}
        else
          :none -> {:error, {:pull_request_not_found, branch}}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        {:ok, %{results: [], merge_attrs: merge_attrs}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_workspace_path(repo_root, issue_identifier) do
    workspace_root = Path.join(repo_root, Path.join(@workspace_root_segments))
    Workspace.path_for_issue(workspace_root, issue_identifier)
  end
end
