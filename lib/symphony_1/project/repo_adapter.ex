defmodule Symphony1.Project.RepoAdapter do
  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec bootstrap_commands() :: [String.t()]
  def bootstrap_commands do
    [
      "git status --short",
      "mix deps.get"
    ]
  end

  @spec validation_commands() :: [String.t()]
  def validation_commands do
    [
      "mix test"
    ]
  end

  @spec finalize_workspace(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def finalize_workspace(attrs, runner \\ &System.cmd/3) do
    workspace = attrs.workspace
    issue_identifier = issue_identifier(attrs)
    commit_message = "Implement #{issue_identifier}"

    with {:ok, branch} <- current_branch(workspace),
         :ok <- run_bootstrap_commands(workspace, runner),
         :ok <- run_validation_commands(workspace, runner),
         :ok <- run_command("git", ["add", "-A"], workspace),
         :ok <- ensure_staged_changes(workspace),
         :ok <- run_command("git", ["commit", "-m", commit_message], workspace),
         :ok <- run_command("git", ["push", "-u", "origin", branch], workspace) do
      {:ok,
       %{
         branch: branch,
         commit_message: commit_message,
         issue_identifier: issue_identifier,
         workspace: workspace
       }}
    end
  end

  defp issue_identifier(%{issue_identifier: issue_identifier}), do: issue_identifier
  defp issue_identifier(%{issue: %{identifier: issue_identifier}}), do: issue_identifier

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp run_validation_commands(workspace, runner) do
    run_shell_commands(validation_commands(), workspace, runner)
  end

  defp run_bootstrap_commands(workspace, runner) do
    run_shell_commands(bootstrap_commands(), workspace, runner)
  end

  defp run_shell_commands(commands, workspace, runner) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case runner.("zsh", ["-lc", command], cd: workspace, stderr_to_stdout: true) do
        {_output, 0} -> {:cont, :ok}
        {output, exit_status} -> {:halt, {:error, {:command_failed, "zsh", exit_status, String.trim(output)}}}
      end
    end)
  end

  defp ensure_staged_changes(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> {:error, :no_changes}
      {_output, 1} -> :ok
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp run_command(command, args, workspace) do
    case System.cmd(command, args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_status} -> {:error, {:command_failed, command, exit_status, String.trim(output)}}
    end
  end
end
