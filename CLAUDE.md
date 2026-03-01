# Algedonia

Agentic coding orchestration platform using maker-checker verification loops as the atomic unit of work. Breaks down coding tasks into DAGs of loops, manages parallel execution with file-level locking, and provides real-time collaboration and human oversight.

## Architecture

**Phoenix Server** (`server/`) — source of truth. Owns UI, tickets, DAGs, loop orchestration, state, collaboration, persistence.
- Elixir, Phoenix LiveView, Ecto, PostgreSQL
- Key GenServers: `Orchestrator`, `Scheduler`, `LockManager`, `CircuitBreaker`, `DaemonMonitor`

**Go Daemon** (`daemon/`) — thin remote executor. Runs on user's machine, connects to server via persistent Phoenix channel.
- PTY management, process spawning, bare repo management, agent adapter dispatch
- Pluggable adapters for Claude Code, Codex, Aider

## Monorepo Layout

```
algedonia/
├── CLAUDE.md              # This file
├── notes/                 # Design docs (PRD, SDD, slices, rubrics)
├── server/                # Phoenix LiveView app (Elixir)
├── daemon/                # Go daemon binary
│   ├── cmd/algedonia-agent/  # CLI entry point
│   └── internal/             # connection, pty, repo, adapter
└── .algedonia/            # Per-repo config and prompts
    ├── prompts/           # maker.md, checker.md, decompose.md, etc.
    └── knowledge.md       # Accumulated codebase knowledge
```

## Build & Test Commands

All common commands have `just` recipes (run from repo root):

```bash
just test                         # Run all tests (server + daemon)
just test-server                  # Elixir tests only
just test-daemon                  # Go tests only
just lint                         # Run all linters (server + daemon)
just lint-server                  # mix compile --warnings-as-errors + format check + credo --strict
just lint-daemon                  # go vet + go build
just format                       # Run all formatters (server + daemon)
just format-server                # mix format
just format-daemon                # go fmt
```

Setup and other commands (run from respective directories):

```bash
# Server (Elixir)
cd server
mix deps.get
mix ecto.setup                    # Create DB + run migrations + seeds
mix test --cover
mix phx.server                    # Start dev server on port 4000

# Daemon (Go)
cd daemon
go test -cover ./...
go build -o algedonia-agent ./cmd/algedonia-agent
```

## Conventions

### Elixir
- Modules: `CamelCase` (e.g., `Algedonia.Tickets`)
- Functions: `snake_case`
- ~300 lines/module, ~20 lines/function (30 for pipeline-heavy) — soft gates, a few lines over is fine if succinct
- Context modules are the test seam; no `Repo` calls outside contexts
- Side effects injected or passed as arguments
- LiveView: minimal socket assigns, use `stream` for collections, thin `handle_event`

### Go
- Exported: `PascalCase`, unexported: `camelCase`
- Error handling: wrap with `fmt.Errorf("context: %w", err)`, no ignored errors
- Interfaces for external boundaries (PTY, filesystem, WebSocket)
- Table-driven tests

### Protocol (Server ↔ Daemon)
- JSON keys: `snake_case`
- Timestamps: Unix milliseconds
- Binary data: raw frames, not Base64

### Database
- Tables: `snake_case`, UUIDs for app tables (bigserial for `events` only)
- Status fields: `Ecto.Enum` on Elixir side, `CHECK` constraints in SQL

## Design Docs

- `notes/prd.md` — Product Requirements Document
- `notes/sdd.md` — System Design Document
- `notes/slices.md` — Implementation slices and ordering
- `notes/rubrics.md` — Code quality rubrics and conventions
