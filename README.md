# Algedonia

**Algedonia helps teams ship AI-generated code they can trust.**

Most agent tools help you produce code faster. Algedonia helps you produce code that is both fast and reliable by making verification part of the core workflow.

## The Product Pitch

Algedonia is an AI coding orchestrator built for real software delivery, not demo output.

You create a ticket with acceptance criteria. Algedonia breaks the work into smaller steps, runs them in parallel when safe, and verifies each result before it moves forward. If quality is unclear, it escalates with context so a human can decide quickly.

The outcome is simple: fewer broken merges, clearer decision points, and cleaner progress from request to shipped code.

## Core Features

- Maker-checker loops: one agent proposes changes, another independently verifies them
- Per-task quality rubrics so "done" is explicit, not guessed
- Automatic retries with feedback when checks fail
- Escalation queue for issues that need human clarification
- Circuit breaker to stop repeated failures from creating noise
- Parallel execution for independent tasks
- Clear artifact trail: diffs, verdicts, attempts, and final commits
- Live visibility into what is running and what is blocked

## Why It Is Different From Conductor-Style Orchestrators

Tools like Conductor, Temporal, and other workflow orchestrators are excellent at moving jobs through pipelines.

Algedonia is designed for a different problem: **trusting AI-written code in active development.**

Key differences:

- Verification-first: independent checking is built into every loop
- Code-quality focus: progress is measured by passing quality gates, not just task completion
- Human-attention design: escalations are structured and prioritized, not buried in logs
- Developer-native output: the product is working code and commit-ready artifacts

In short: traditional orchestrators optimize flow. Algedonia optimizes trustworthy outcomes.

## Who It Is For

- Teams using AI coding agents that want stronger quality control
- Developers who want speed without giving up review discipline
- Engineering groups that need a clear audit trail for what changed and why

## Repository Layout

- `daemon/` local agent runner
- `server/` orchestration service and UI
- `notes/` product and design documents (including the PRD)

## Local Setup

### Technologies Used

Install these before bootstrapping:

| Technology | Used for | Install |
|------------|----------|---------|
| [Go](https://go.dev/doc/install) | Daemon (`daemon/`) build and tests | Official install guide |
| [Elixir](https://elixir-lang.org/install.html) | Phoenix server (`server/`) | Official install guide |
| [Erlang/OTP](https://www.erlang.org/downloads) | Elixir runtime | Official install guide |
| [PostgreSQL](https://www.postgresql.org/download/) | Development database | Official install guide |
| [just](https://github.com/casey/just#installation) | Repository task runner | Official install guide |

### Bootstrap Steps

```bash
# From the repository root
cp .env.example .env

# Install dependencies, create DB, run migrations and seeds
cd server && mix setup && cd ..

# Build/install the local daemon CLIs (ag + agd) into ~/bin
just build-cli

# Run the app
just server
```

Open http://localhost:4000 after the server starts.

### Justfile Recipes

Run `just --list` from the repository root to see all recipes.

| Recipe | Description |
|--------|-------------|
| `just build-cli` | Build `daemon/cmd/algedonia-agent` as `ag` and `agd`, install to `~/bin/{ag,agd}` |
| `just db` | Create the configured dev DB if missing and migrate to the latest version |
| `just server` | Start Phoenix dev server on port `4000` |
| `just dev-server` | Start Phoenix dev server on port `4100` for local parallel-daemon development |
| `just format` | Run all formatters (`format-server`, `format-daemon`) |
| `just lint` | Run all linters (`lint-server`, `lint-daemon`) |
| `just test` | Run all tests (`test-server`, `test-daemon`) |
| `just format-server` | Format Elixir server code (`mix format`) |
| `just format-daemon` | Format Go daemon code (`go fmt ./...`) |
| `just lint-server` | Compile with warnings-as-errors, check formatting, run credo |
| `just lint-daemon` | Run Go vet and build daemon packages |
| `just test-server` | Run Elixir tests (`mix test`) |
| `just test-daemon` | Run Go tests (`go test ./...`) |
| `just github` | Open the GitHub repository in a browser |

### Parallel Local Dev (`ag` + `agd`)

Use `ag` for your normal profile and `agd` for local parallel verification.

- `ag` config stays at `~/.config/ag/config.json`
- `agd` config stays at `~/.config/agd/config.json`
- `agd` defaults:
  - server websocket: `ws://localhost:4100/daemon/websocket`
  - terminal websocket listen: `127.0.0.1:8766`

Typical local parallel flow:

```bash
just db
just dev-server
agd login
```

## License

See [LICENSE](LICENSE).
