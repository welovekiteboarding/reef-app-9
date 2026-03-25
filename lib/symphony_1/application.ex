defmodule Symphony1.Application do
  use Application
  alias Symphony1.Core.{MergePoller, Policy, QueueLauncher, QueuePoller, QueueScheduler}

  @impl true
  def start(_type, _args) do
    children =
      [queue_poller_child(), merge_poller_child()]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Symphony1.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def queue_poller_child do
    runtime = Application.get_env(:symphony_1, :queue_runtime, %{})

    if Map.get(runtime, :enabled, false) do
      run_attrs = Map.fetch!(runtime, :run_attrs)
      workflow_path = Map.fetch!(run_attrs, :workflow_path)
      interval_ms = Map.get(runtime, :interval_ms, 1_000)

      {:ok, workflow} = Policy.load_workflow_config(workflow_path)

      queue_scheduler =
        QueueScheduler.new(
          max_concurrent_agents: get_in(workflow, ["agent", "max_concurrent_agents"]) || 1,
          launcher: &QueueLauncher.launch/1
        )

      {QueuePoller,
       interval_ms: interval_ms, queue_scheduler: queue_scheduler, run_attrs: run_attrs}
    end
  end

  def merge_poller_child do
    runtime = Application.get_env(:symphony_1, :merge_runtime, %{})

    if Map.get(runtime, :enabled, false) do
      merge_attrs = Map.fetch!(runtime, :merge_attrs)
      interval_ms = Map.get(runtime, :interval_ms, 1_000)

      {MergePoller,
       interval_ms: interval_ms, merge_attrs: merge_attrs}
    end
  end
end
