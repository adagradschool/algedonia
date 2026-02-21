alias Algedonia.Repo
alias Algedonia.Tickets.Ticket

tickets = [
  %{
    title: "User authentication flow",
    description: "Implement OAuth2 login with GitHub and Google providers",
    type: :feature,
    priority: 1,
    status: :in_progress,
    assignee: "alice",
    acceptance_criteria:
      "- Users can sign in with GitHub\n- Users can sign in with Google\n- Session persists across page reloads"
  },
  %{
    title: "Fix WebSocket reconnection loop",
    description: "Daemon reconnects every 2s when server sends invalid frame",
    type: :bug,
    priority: 1,
    status: :in_progress,
    assignee: "bob"
  },
  %{
    title: "DAG visualization component",
    description: "Render loop DAGs as interactive node graphs using LiveView",
    type: :feature,
    priority: 2,
    status: :backlog,
    assignee: "alice"
  },
  %{
    title: "Set up CI pipeline",
    description: "GitHub Actions for mix test, go test, lint, and format checks",
    type: :chore,
    priority: 2,
    status: :completed,
    assignee: "carol"
  },
  %{
    title: "Evaluate LLM response caching",
    description: "Spike on caching agent responses to reduce API costs during retries",
    type: :spike,
    priority: 3,
    status: :backlog,
    assignee: nil
  },
  %{
    title: "Loop timeout handling",
    description:
      "Maker loops that exceed the configured timeout should be cancelled and marked failed",
    type: :feature,
    priority: 2,
    status: :backlog,
    assignee: "bob",
    acceptance_criteria:
      "- Timeout is configurable per-loop\n- Timed-out loops are marked as failed\n- CircuitBreaker is notified"
  },
  %{
    title: "Migrate to Tailwind v4",
    description: "Update Tailwind CSS configuration for v4 syntax and features",
    type: :chore,
    priority: 4,
    status: :completed,
    assignee: "carol"
  },
  %{
    title: "Agent adapter interface design",
    description: "Define the Go interface for pluggable agent adapters (Claude, Codex, Aider)",
    type: :spike,
    priority: 3,
    status: :backlog,
    assignee: nil
  },
  %{
    title: "File lock contention deadlock",
    description: "Two loops requesting overlapping file sets can deadlock the LockManager",
    type: :bug,
    priority: 1,
    status: :backlog,
    assignee: "alice"
  },
  %{
    title: "Seed data for development",
    description: "Add realistic seed data for tickets, loops, and DAGs",
    type: :chore,
    priority: 5,
    status: :completed,
    assignee: "carol"
  }
]

for attrs <- tickets do
  %Ticket{}
  |> Ticket.changeset(attrs)
  |> Repo.insert!()
end
