# Code Quality Rubrics

Operational rubrics for maker and checker agents. Derived from [notes/rubrics.md](../notes/rubrics.md).

---

## Elixir

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
- Socket assigns are minimal; use `stream` for collections
- GenServer state must be a struct, not a bare map
- `init/1` must be fast (<100ms); defer to `handle_continue/2`
- Persist state to PostgreSQL before responding (write-ahead)

### Testing

- Every public context function: at least one happy-path and one error-path test
- Every changeset: tests for valid input and each validation rule
- LiveView mount renders without error
- PubSub-driven updates tested via broadcast + re-render assertion
- Use `Mox` for behavior-based mocks
- Use `Ecto.Adapters.SQL.Sandbox`; factory module for schema builders
- No `assert true` tautologies
- Line coverage target: >=85% server

---

## Go

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

### Testing

- External dependencies behind interfaces; tests inject fakes
- Time-dependent behavior uses injectable clocks/timers
- No tests depend on network access or external binaries
- Test helpers in `_test.go` files in same package
- Line coverage target: >=80% daemon

---

## Protocol (Server <-> Daemon)

- JSON keys: `snake_case`
- Timestamps: Unix milliseconds
- Binary data: raw frames, not Base64
- Channel authentication in `join/3`; invalid token returns `{:error, %{reason: "unauthorized"}}`
- Validate incoming payloads; never silently drop malformed messages

---

## Database

- Tables: `snake_case`, UUIDs for app tables (bigserial for `events` only)
- Status fields: `Ecto.Enum` on Elixir side, `CHECK` constraints in SQL
- Schemas mirror SDD table definitions exactly
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
