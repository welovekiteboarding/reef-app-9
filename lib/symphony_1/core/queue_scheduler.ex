defmodule Symphony1.Core.QueueScheduler do
  defstruct active_runs: %{}, launcher: nil, max_concurrent_agents: 1

  @type t :: %__MODULE__{
          active_runs: %{reference() => Task.t()},
          launcher: (map() -> {:ok, Task.t()} | :none | {:error, term()}),
          max_concurrent_agents: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      active_runs: %{},
      launcher: Keyword.fetch!(opts, :launcher),
      max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 1)
    }
  end

  @spec drain_once(t(), map()) :: t()
  def drain_once(%__MODULE__{} = state, attrs) do
    state = prune_completed_runs(state)
    open_slots = max(state.max_concurrent_agents - map_size(state.active_runs), 0)

    if open_slots == 0 do
      state
    else
      Enum.reduce_while(1..open_slots, state, fn _, acc ->
        case acc.launcher.(attrs) do
          {:ok, %Task{} = task} ->
            {:cont, %{acc | active_runs: Map.put(acc.active_runs, task.ref, task)}}

          :none ->
            {:halt, acc}

          {:error, _reason} ->
            {:halt, acc}
        end
      end)
    end
  end

  defp prune_completed_runs(%__MODULE__{} = state) do
    active_runs =
      state.active_runs
      |> Enum.reject(fn {_ref, task} -> task.pid == nil or not Process.alive?(task.pid) end)
      |> Map.new()

    %{state | active_runs: active_runs}
  end
end
