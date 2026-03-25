defmodule Symphony1.Core.Worker do
  @type run_spec :: %{
          command: String.t(),
          args: [String.t()],
          cd: String.t(),
          env: %{optional(String.t()) => String.t()}
        }

  @type session :: %{
          port: port(),
          buffer: String.t(),
          next_id: pos_integer(),
          thread_id: String.t() | nil,
          turn_id: String.t() | nil
        }

  @initialize_timeout 10_000
  @turn_timeout 60_000

  @spec local_run_spec(map()) :: run_spec()
  def local_run_spec(%{workspace: workspace, workflow_path: workflow_path}) do
    %{
      command: "codex",
      args: ["app-server", "--listen", "stdio://"],
      cd: workspace,
      env: %{
        "SYMPHONY_WORKFLOW_PATH" => workflow_path
      }
    }
  end

  @spec start_run(map()) :: {:ok, port()} | {:error, term()}
  def start_run(attrs) do
    spec = local_run_spec(attrs)

    port =
      Port.open({:spawn_executable, System.find_executable(spec.command)}, [
        :binary,
        :exit_status,
        {:args, Enum.map(spec.args, &String.to_charlist/1)},
        {:cd, String.to_charlist(spec.cd)},
        {:env, Enum.map(spec.env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @spec start_session(map()) :: {:ok, session()} | {:error, term()}
  def start_session(attrs) do
    with {:ok, port} <- start_run(attrs),
         {:ok, session} <- initialize(%{port: port, buffer: "", next_id: 1, thread_id: nil, turn_id: nil}, attrs),
         {:ok, session} <- start_thread(session, attrs) do
      {:ok, session}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec run_prompt(session(), String.t(), keyword()) ::
          {:ok, %{output: String.t(), thread_id: String.t(), turn_id: String.t()}} | {:error, term()}
  def run_prompt(session, prompt, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @turn_timeout)

    request = %{
      "id" => session.next_id,
      "method" => "turn/start",
      "params" => %{
        "threadId" => session.thread_id,
        "input" => [
          %{"type" => "text", "text" => prompt}
        ]
      }
    }

    with :ok <- send_json(session.port, request),
         {:ok, session, _turn_response} <- await_response(session, session.next_id, @initialize_timeout),
         {:ok, _session, result} <- await_turn_completion(%{session | next_id: session.next_id + 1}, timeout_ms) do
      {:ok, Map.put(result, :thread_id, session.thread_id)}
    end
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(session) do
    stop_run(session.port)
  end

  @spec stop_run(port()) :: :ok | {:error, term()}
  def stop_run(port) do
    Port.close(port)
    :ok
  rescue
    error -> {:error, error}
  end

  defp initialize(session, _attrs) do
    request = %{
      "id" => session.next_id,
      "method" => "initialize",
      "params" => %{
        "clientInfo" => %{
          "name" => "symphony-1",
          "version" => "0.1.0"
        }
      }
    }

    with :ok <- send_json(session.port, request),
         {:ok, session, _response} <- await_response(session, session.next_id, @initialize_timeout),
         :ok <- send_json(session.port, %{"method" => "initialized"}) do
      {:ok, %{session | next_id: session.next_id + 1}}
    end
  end

  defp start_thread(session, attrs) do
    request = %{
      "id" => session.next_id,
      "method" => "thread/start",
      "params" => %{
        "approvalPolicy" => "never",
        "cwd" => attrs.workspace,
        "model" => "gpt-5.4",
        "personality" => "pragmatic",
        "sandbox" => "danger-full-access"
      }
    }

    with :ok <- send_json(session.port, request),
         {:ok, session, %{"thread" => %{"id" => thread_id}}} <-
           await_response(session, session.next_id, @initialize_timeout) do
      {:ok, %{session | next_id: session.next_id + 1, thread_id: thread_id}}
    end
  end

  defp await_turn_completion(session, timeout_ms) do
    await_turn_completion(session, %{output: "", turn_id: nil}, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_turn_completion(session, result, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :turn_timeout}
    else
      receive do
        {port, {:data, data}} when port == session.port ->
          {session, messages} = decode_messages(%{session | buffer: session.buffer <> data})

          case consume_turn_messages(messages, result) do
            {:completed, result} ->
              {:ok, session, result}

            {:continue, result} ->
              await_turn_completion(session, result, deadline_ms)
          end

        {port, {:exit_status, status}} when port == session.port ->
          {:error, {:worker_exit, status}}
      after
        remaining ->
          {:error, :turn_timeout}
      end
    end
  end

  defp consume_turn_messages(messages, result) do
    Enum.reduce_while(messages, {:continue, result}, fn
      %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text} = item}},
      {:continue, result} ->
        updated =
          result
          |> Map.put(:output, text)
          |> Map.put(:turn_id, Map.get(item, "turnId", result.turn_id))

        {:cont, {:continue, updated}}

      %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}},
      {:continue, result} ->
        {:cont, {:continue, %{result | output: result.output <> delta}}}

      %{"method" => "turn/started", "params" => %{"turn" => %{"id" => turn_id}}},
      {:continue, result} ->
        {:cont, {:continue, %{result | turn_id: turn_id}}}

      %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}},
      {:continue, result} ->
        {:halt, {:completed, result}}

      _message, acc ->
        {:cont, acc}
    end)
  end

  defp await_response(session, id, timeout_ms) do
    receive do
      {port, {:data, data}} when port == session.port ->
        {session, messages} = decode_messages(%{session | buffer: session.buffer <> data})

        case Enum.find(messages, &(Map.get(&1, "id") == id and Map.has_key?(&1, "result"))) do
          nil ->
            await_response(session, id, timeout_ms)

          %{"result" => result} ->
            {:ok, session, result}
        end

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:worker_exit, status}}
    after
      timeout_ms ->
        {:error, {:timeout, id}}
    end
  end

  defp decode_messages(session) do
    decode_messages(session, [])
  end

  defp decode_messages(%{buffer: buffer} = session, messages) do
    case :binary.split(buffer, "\n", [:global]) do
      [_partial] ->
        {session, messages}

      parts ->
        complete = Enum.drop(parts, -1)
        rest = List.last(parts)

        decode_messages(
          %{session | buffer: rest},
          messages ++ Enum.map(complete, &Jason.decode!/1)
        )
    end
  end

  defp send_json(port, payload) do
    encoded = Jason.encode!(payload)
    Port.command(port, encoded <> "\n")
    :ok
  rescue
    error -> {:error, error}
  end
end
