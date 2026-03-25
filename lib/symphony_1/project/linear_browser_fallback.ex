defmodule Symphony1.Project.LinearBrowserFallback do
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(config) do
    runner = Application.get_env(:symphony_1, :linear_browser_fallback_runner, &run_command/1)
    runner.(config)
  end

  defp run_command(config) do
    case configured_command() do
      nil ->
        {:error, :linear_browser_fallback_unavailable}

      command ->
        payload =
          config
          |> Enum.into(%{})
          |> Jason.encode!()

        case System.cmd("/bin/sh", ["-lc", command], input: payload, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:linear_browser_fallback_command_failed, String.trim(output)}}
        end
    end
  end

  defp configured_command do
    Application.get_env(:symphony_1, :linear_browser_fallback_command) ||
      System.get_env("SYMPHONY_LINEAR_BROWSER_FALLBACK_COMMAND")
  end
end
