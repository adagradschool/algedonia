# Code Quality Rubrics

Rubric library for maker, checker, and planning agents. Derived from [notes/rubrics.md](../notes/rubrics.md).

The planning agent selects which sections apply to each ticket and passes them as `params.rubrics` to the `agent-review` skill. Not every ticket is evaluated against every section.

**Section IDs**: `elixir`, `go`, `protocol`, `database`

Within Elixir: `liveview`, `channels`, `genserver`, `ecto` (use these as more specific rubric selections when the ticket scope is narrow).

---

## Elixir
ID: `elixir`

### Size Limits (Soft Gates)

- Functions: <=20 lines (30 for pipeline-heavy)
- Modules: <=300 lines
- LiveView modules: <=200 lines
- Channel modules: <=150 lines
- GenServer modules: <=200 lines

### Hard Gates

- Zero compiler warnings (`--warnings-as-errors`)
- `mix format --check-formatted` passes
- `mix credo --strict` passes with zero issues

### Style

- Modules: `CamelCase`, functions: `snake_case`, constants: `@snake_case`
- Every public function has `@doc` and `@spec`
- Every module has `@moduledoc`
- Pattern match in function heads over `if`/`case` for shape dispatch
- Pipelines read top-to-bottom; never pipe into anonymous functions
- Use `with` for happy-path chains; avoid nested `case` deeper than 2 levels
- Return tagged tuples (`{:ok, value}`, `{:error, reason}`) from context functions
- Use module attributes for constants; no magic numbers

### Architecture

- Context modules are the test seam — no `Repo` calls outside contexts
- Side effects injected or passed as arguments
- LiveView `handle_event` callbacks are thin dispatchers
- Socket assigns are minimal; use `stream` for collections — board/list views update incrementally, never re-fetch the full list
- Zero N+1 queries — preload associations in the listing query, never per-item
- All queries on tenant-scoped tables must include `WHERE workspace_id = ?`
- PubSub topics must be workspace-scoped: `workspace:{id}:*`
- GenServer state must be a struct, not a bare map
- `init/1` must be fast (<100ms); defer to `handle_continue/2`
- Persist state to PostgreSQL before responding (write-ahead)
- Server never sees code — no diffs, raw output, or file contents in protocol messages

### Testing

- Every public context function: at least one happy-path and one error-path test
- Every changeset: tests for valid input and each validation rule
- LiveView mount renders without error
- PubSub-driven updates tested via broadcast + re-render assertion
- Workspace isolation tested: query workspace A data with workspace B scope returns nothing
- Use `Mox` for behavior-based mocks (tracker API, PubSub)
- Use `Ecto.Adapters.SQL.Sandbox`; factory module for schema builders (including workspace and user)
- No `assert true` tautologies
- Line coverage target: >=85% server

---

## Go
ID: `go`

### Size Limits (Soft Gates)

- Functions: <=40 lines (exception: large switch statements)
- Files: <=500 lines

### Hard Gates

- All code passes `gofmt`
- All code passes `go vet`
- No `panic` in production code (exception: `init()` for unrecoverable failures)

### Style

- Exported: `PascalCase`, unexported: `camelCase`
- Exported functions and types have godoc comments starting with the name
- Every error is handled, wrapped (`fmt.Errorf("context: %w", err)`), or returned
- No ignored errors (no blank `_` for error returns except in tests or deferred `Close`)
- Use `context.Context` for cancellation and timeouts on all I/O
- Use `errors.Is` and `errors.As` for error checking
- Close resources with `defer` immediately after acquisition
- Use structured logging (`slog`) with key-value pairs
- Table-driven tests

### Architecture

- Accept interfaces, return structs
- External boundaries (PTY, filesystem, WebSocket) behind interfaces
- Single long-lived goroutine for reading, single for writing; coordinate via channels
- Connection lifecycle is a state machine with logged transitions
- Reconnection: exponential backoff with jitter (1s initial, 60s max)
- Bare clone layout: `<baseDir>/<slug>/root/` for bare repo, worktrees at `<workspaceDir>/worktrees/<ticketPrefix>/`
- Skills resolved from `.algedonia/skills/` in the repo worktree at checker step execution time
- Landing sequence (squash, push, PR create, CI poll, merge) runs entirely on daemon — no server involvement beyond the `land` command

### Testing

- External dependencies behind interfaces; tests inject fakes
- Time-dependent behavior uses injectable clocks/timers
- No tests depend on network access or external binaries
- Test helpers in `_test.go` files in same package
- Line coverage target: >=80% daemon

---

## Protocol (Server <-> Daemon)
ID: `protocol`

- JSON keys: `snake_case`
- Timestamps: Unix milliseconds
- Binary data: raw frames, not Base64
- Channel authentication in `join/3` with user token; server resolves workspace membership
- Validate incoming payloads; never silently drop malformed messages
- `maker_result`: only `exit_code`, `files_changed` (paths), `duration_ms`, `token_usage` — no diffs
- `step_result`: `skill_name`, `passed`, `summary`, `duration_ms` — no raw output
- `land_result`: `status`, `pr_url`, `merge_sha`, `ci_output` (on failure)
- `heartbeat`: includes `available_agents`, `bare_repos` for routing

---

## Database
ID: `database`

- Tables: `snake_case`, UUIDs for app tables (bigserial for `events` only)
- Status fields: `Ecto.Enum` on Elixir side, `CHECK` constraints in SQL
- Schemas mirror SDD table definitions exactly
- All tenant-scoped tables have `workspace_id` FK with index
- RLS policies on all tenant-scoped tables as safety net
- Migrations are reversible (`change`) unless truly irreversible
- Indexes on every foreign key and every column in `WHERE` clauses
- Use `Ecto.Multi` for atomic multi-step operations
- Use upserts (`on_conflict`) for heartbeat-style updates

---

## Code Smells to Avoid

- `TODO`/`FIXME` without a linked ticket
- Dead code (unused functions, unreachable clauses)
- Copy-pasted logic across modules
- GenServer state growing unboundedly
- Synchronous `call` between GenServers (deadlock risk)
- Goroutine leaks (no cancellation path or WaitGroup)
- Commented-out code checked in
- Hardcoded server URLs or tokens
- Package-level mutable state in Go
- N+1 queries — per-item fetches inside loops/comprehensions
- Unscoped tenant queries (missing `workspace_id` filter)
- Code or file contents leaking into server-bound protocol messages
