defmodule Symphony1.Core.Linear do
  alias Symphony1.Core.Workflow

  @type config :: %{
          api_key: String.t(),
          team_key: String.t()
        }

  @type requester :: (String.t(), map(), String.t() -> {:ok, map()} | {:error, term()})

  @teams_query """
  query {
    teams {
      nodes {
        id
        key
        name
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @team_issues_query """
  query TeamIssues($teamId: String!) {
    team(id: $teamId) {
      id
      key
      name
      issues(first: 50) {
        nodes {
          id
          identifier
          title
          description
          state {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @transition_issue_mutation """
  mutation TransitionIssue($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: { stateId: $stateId }) {
      success
      issue {
        id
        identifier
        state {
          id
          name
          type
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation CreateIssue($teamId: String!, $title: String!, $description: String!, $stateId: String!) {
    issueCreate(
      input: {
        teamId: $teamId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        state {
          id
          name
          type
        }
      }
    }
  }
  """

  @create_team_mutation """
  mutation CreateTeam($input: TeamCreateInput!) {
    teamCreate(input: $input) {
      success
      team {
        id
        key
        name
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @create_workflow_state_mutation """
  mutation CreateWorkflowState($input: WorkflowStateCreateInput!) {
    workflowStateCreate(input: $input) {
      success
      workflowState {
        id
        name
        type
      }
    }
  }
  """

  @spec load_team(config(), requester()) :: {:ok, map()} | {:error, term()}
  def load_team(config, requester \\ &request/3) do
    with {:ok, response} <- requester.(@teams_query, %{}, config.api_key),
         {:ok, team} <- find_team(response, config.team_key) do
      {:ok,
       %{
         id: team["id"],
         key: team["key"],
         name: team["name"],
         states: Enum.map(team["states"]["nodes"], &normalize_state/1)
       }}
    end
  end

  @spec poll_eligible_issue(config(), requester()) :: {:ok, map()} | :none | {:error, term()}
  def poll_eligible_issue(config, requester \\ &request/3) do
    poll_issue_in_state(config, "Todo", requester)
  end

  @spec poll_issue_in_state(config(), String.t(), requester()) ::
          {:ok, map()} | :none | {:error, term()}
  def poll_issue_in_state(config, state_name, requester \\ &request/3) do
    with {:ok, team} <- load_team(config, requester),
         {:ok, response} <- requester.(@team_issues_query, %{"teamId" => team.id}, config.api_key),
         {:ok, issues} <- extract_issues(response) do
      issues
      |> Enum.map(&normalize_issue/1)
      |> Enum.map(&Map.put(&1, :team_id, team.id))
      |> find_issue_in_state(state_name)
    end
  end

  @spec transition_issue(map(), String.t(), config(), requester()) :: {:ok, map()} | {:error, term()}
  def transition_issue(issue, new_state, config, requester \\ &request/3) do
    with :ok <- Workflow.validate_transition(issue.state, new_state),
         {:ok, team} <- load_team(config, requester),
         {:ok, target_state} <- find_state(team.states, new_state),
         {:ok, response} <-
           requester.(
             @transition_issue_mutation,
             %{"id" => issue.id, "stateId" => target_state.id},
             config.api_key
           ),
         {:ok, updated_issue} <- extract_updated_issue(response) do
      {:ok, merge_issue_fields(issue, normalize_issue(updated_issue))}
    end
  end

  @spec create_issue(config(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_issue(config, attrs, requester \\ &request/3) do
    with {:ok, team} <- load_team(config, requester),
         {:ok, target_state} <- find_state(team.states, attrs["state"]),
         {:ok, response} <-
           requester.(
             @create_issue_mutation,
             %{
               "teamId" => team.id,
               "title" => attrs["title"],
               "description" => attrs["description"],
               "stateId" => target_state.id
             },
             config.api_key
           ),
         {:ok, issue} <- extract_created_issue(response) do
      {:ok, Map.put(normalize_issue(issue), :team_id, team.id)}
    end
  end

  @spec create_team(map(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_team(config, attrs, requester \\ &request/3) do
    with {:ok, response} <-
           requester.(
             @create_team_mutation,
             %{
               "input" => %{
                 "key" => attrs["key"],
                 "name" => attrs["name"]
               }
             },
             config.api_key
           ),
         {:ok, team} <- extract_created_team(response) do
      {:ok,
       %{
         id: team["id"],
         key: team["key"],
         name: team["name"],
         states: Enum.map(team["states"]["nodes"], &normalize_state/1)
       }}
    end
  end

  @spec create_workflow_state(map(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_workflow_state(config, attrs, requester \\ &request/3) do
    with {:ok, response} <-
           requester.(
             @create_workflow_state_mutation,
             %{
               "input" => %{
                 "color" => attrs["color"],
                 "name" => attrs["name"],
                 "position" => attrs["position"],
                 "teamId" => attrs["teamId"],
                 "type" => attrs["type"]
               }
             },
             config.api_key
           ),
         {:ok, state} <- extract_created_workflow_state(response) do
      {:ok, normalize_state(state)}
    end
  end

  @spec request(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def request(query, variables, api_key) do
    :inets.start()
    :ssl.start()

    payload = Jason.encode!(%{query: query, variables: variables})

    headers = [
      {~c"Content-Type", ~c"application/json"},
      {~c"Authorization", String.to_charlist(api_key)}
    ]

    request = {~c"https://api.linear.app/graphql", headers, ~c"application/json", payload}

    with {:ok, {{_http_version, 200, _reason_phrase}, _headers, body}} <-
           :httpc.request(:post, request, [], []),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_team(%{"data" => %{"teams" => %{"nodes" => teams}}}, team_key) do
    case Enum.find(teams, &(&1["key"] == team_key)) do
      nil -> {:error, {:team_not_found, team_key}}
      team -> {:ok, team}
    end
  end

  defp find_team(%{"errors" => errors}, _team_key), do: {:error, {:graphql_error, errors}}
  defp find_team(_response, team_key), do: {:error, {:team_not_found, team_key}}

  defp extract_issues(%{"data" => %{"team" => %{"issues" => %{"nodes" => issues}}}}), do: {:ok, issues}
  defp extract_issues(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_issues(_response), do: {:ok, []}

  defp extract_updated_issue(%{"data" => %{"issueUpdate" => %{"success" => true, "issue" => issue}}}),
    do: {:ok, issue}

  defp extract_updated_issue(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_updated_issue(_response), do: {:error, :issue_update_failed}

  defp extract_created_issue(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}),
    do: {:ok, issue}

  defp extract_created_issue(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_issue(_response), do: {:error, :issue_create_failed}

  defp extract_created_team(%{"data" => %{"teamCreate" => %{"success" => true, "team" => team}}}),
    do: {:ok, team}

  defp extract_created_team(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_team(_response), do: {:error, :team_create_failed}

  defp extract_created_workflow_state(%{
         "data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => state}}
       }),
       do: {:ok, state}

  defp extract_created_workflow_state(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_workflow_state(_response), do: {:error, :workflow_state_create_failed}

  defp find_issue_in_state(issues, state_name) do
    case Enum.find(issues, &(&1.state == state_name)) do
      nil -> :none
      issue -> {:ok, issue}
    end
  end

  defp find_state(states, state_name) do
    case Enum.find(states, &(&1.name == state_name)) do
      nil -> {:error, {:state_not_found, state_name}}
      state -> {:ok, state}
    end
  end

  defp normalize_issue(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: issue["state"]["name"],
      state_id: issue["state"]["id"],
      state_type: issue["state"]["type"]
    }
  end

  defp merge_issue_fields(existing_issue, updated_issue) do
    Enum.reduce(updated_issue, existing_issue, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_state(state) do
    %{
      id: state["id"],
      name: state["name"],
      type: state["type"]
    }
  end
end
