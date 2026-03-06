# Algedonia -- Quality Rubrics

Reference: [PRD v4](prd.md), [SDD v3](sdd.md), [Slices v2](slices.md)

---

# Part 1: Codebase Quality Rubrics

---

## Elixir (Language-Level)

### Quality

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| E1 | Function length | Functions should be <=20 lines (soft gate — a few lines over is acceptable if the code is succinct and readable). Exception: pipeline-heavy functions with a single logical flow may reach 30. |
| E2 | Module length | Modules should be <=300 lines (soft gate — a few lines over is acceptable if the code is succinct). Split into submodules if significantly exceeded. |
| E3 | Public function documentation | Every public function has `@doc` and `@spec`. |
| E4 | Module documentation | Every module has `@moduledoc` describing its responsibility. |
| E5 | Naming | Modules use `CamelCase`, functions use `snake_case`, constants use `@snake_case`. No abbreviations unless universally understood (e.g., `id`, `pid`, `ref`). |
| E6 | Pattern matching | Use pattern matching in function heads instead of `if`/`case` when dispatching on shape. |
| E7 | Pipe operator | Pipelines read top-to-bottom. Never pipe into an anonymous function; extract a named function. |
| E8 | Compiler warnings | Zero compiler warnings. Treat `--warnings-as-errors` as a hard gate. |
| E9 | Formatting | All code passes `mix format --check-formatted`. No exceptions. |
| E10 | Credo | All code passes `mix credo --strict` with zero issues. Custom `.credo.exs` may disable specific checks with a comment explaining why. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| EI1 | Use `with` for happy-path chains that need early return on error. | Nested `case` statements deeper than 2 levels. |
| EI2 | Return tagged tuples (`{:ok, value}`, `{:error, reason}`) from context functions. | Raising exceptions for expected failure paths. |
| EI3 | Use `Enum` and `Stream` for collection processing. | Manual recursion for simple list operations. |
| EI4 | Destructure in function arguments. | Accessing struct fields deep inside function bodies when the value could be bound at the head. |
| EI5 | Use module attributes (`@default_timeout 5_000`) for constants. | Hardcoded magic numbers in function bodies. |
| EI6 | Separate pure functions from side-effecting ones. Pure functions go in the context module; side effects go in LiveView or GenServer callbacks. | Mixing database calls and data transformation in the same function. |

### Testability

| # | Criterion |
|---|-----------|
| ET1 | Context modules (`Algedonia.Tickets`, etc.) are the seam for testing. LiveViews and GenServers call context functions, not Repo directly. |
| ET2 | Side effects are injected via configuration or passed as arguments (e.g., passing a `notify_fn` instead of hardcoding `PubSub.broadcast`). |
| ET3 | Use `Mox` for behavior-based mocks. Define behaviours for external boundaries (daemon communication, PubSub). |
| ET4 | Avoid `Application.get_env` inside functions. Pass config through function arguments or module attributes set at compile time. |

### Test Coverage

| # | Criterion |
|---|-----------|
| EC1 | Every public function in a context module has at least one happy-path and one error-path test. |
| EC2 | Line coverage target: >=85% for server code overall. |
| EC3 | Every Ecto changeset has tests for valid input and every validation rule (required fields, format constraints, enum values). |
| EC4 | No test uses `assert true` or similar tautologies. Every assertion checks a meaningful property. |
| EC5 | Tests run in under 30 seconds total for the server suite (`mix test`). Individual test files run in under 5 seconds. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| ED1 | A module imports another module's internal functions (not part of the public API). |
| ED2 | `TODO` or `FIXME` comments without a linked ticket or slice number. |
| ED3 | Dead code: unused functions, unreachable clauses. Detectable by `mix credo` or `mix compile --warnings-as-errors`. |
| ED4 | String-typed fields used where an enum or atom would be safer (e.g., status fields without validation). |
| ED5 | More than 3 levels of module nesting (e.g., `Algedonia.Foo.Bar.Baz.Qux`). |
| ED6 | Copy-pasted logic across modules instead of extracting a shared function or behaviour. |

---

## Phoenix LiveView (UI Layer)

### Quality

| # | Criterion |
|---|-----------|
| LV1 | Socket assigns are minimal. No full lists in assigns when only a count or summary is needed. Use `stream` for collections that update incrementally. |
| LV2 | `handle_event/3` callbacks are thin dispatchers: validate params, call a context function, assign the result. No business logic in LiveView modules. |
| LV3 | `handle_info/2` callbacks for PubSub messages update only the affected assigns, not the entire state. |
| LV4 | LiveView modules should be <=200 lines (soft gate — a few lines over is acceptable if the code is succinct). Extract function components and live components for complex UI sections. |
| LV5 | Every LiveView subscribes to PubSub topics in `mount/3`, not in `handle_params/2` (unless topic depends on params, in which case unsubscribe from the old topic first). |
| LV6 | HEEx templates are in separate `.heex` files, not inline `~H` sigils, when they exceed ~30 lines. |
| LV7 | No raw HTML strings. Use HEEx components and function components exclusively. |
| LV8 | Form changesets are validated client-side via `phx-change` before submission. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| LVI1 | Use `assign_new/3` for expensive computations that shouldn't re-run on every mount. | Re-fetching data in `mount` that was already available. |
| LVI2 | Use `streams` for lists of items (tickets, loops, comments) to minimize DOM patching. | Assigning full lists and re-rendering entire lists on every change. |
| LVI3 | Use `push_event/3` for JavaScript interop (terminal widget, DAG visualization). | Direct JavaScript calls via inline `<script>` tags. |
| LVI4 | Use `Phoenix.Component` function components for stateless UI pieces. | Live components for things that don't need their own lifecycle. |

### Testability

| # | Criterion |
|---|-----------|
| LVT1 | LiveView tests use `Phoenix.LiveViewTest` (`live/2`, `render_click/2`, etc.). |
| LVT2 | Each LiveView has at least one test verifying mount renders without error. |
| LVT3 | PubSub-driven updates are tested by broadcasting a message and asserting the LiveView re-renders with the new data. |
| LVT4 | Form submissions are tested for both valid and invalid input. |

### Test Coverage

| # | Criterion |
|---|-----------|
| LVC1 | Every user-facing interaction from the slices verification criteria has a corresponding LiveView integration test. |
| LVC2 | Real-time update paths (PubSub -> LiveView -> DOM change) have at least one test per PubSub topic. |
| LVC3 | Navigation between views (`/tickets` -> `/dags/:id` -> `/loops/:id`) is tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| LVD1 | `assigns` contains data only used by a child component (should be passed as props or fetched by the child). |
| LVD2 | Multiple LiveViews duplicating the same PubSub subscription and handling logic (extract to a shared hook module). |
| LVD3 | JavaScript hooks that grow significantly beyond ~50 lines without extraction into a separate JS module. |
| LVD4 | Synchronous database queries in `handle_event` that could cause UI lag. Use `assign_async` or `start_async` for queries over 100ms. |

---

## Phoenix Channels (Real-Time Communication)

### Quality

| # | Criterion |
|---|-----------|
| CH1 | Each channel module handles one topic pattern. `DaemonChannel` handles `daemon:*`. No god-channels. |
| CH2 | `handle_in/3` callbacks validate incoming payloads and return `{:reply, {:error, reason}, socket}` on invalid input. Never silently drop malformed messages. |
| CH3 | Channel authentication happens in `join/3`. An invalid project token returns `{:error, %{reason: "unauthorized"}}`. |
| CH4 | Binary data (terminal output) uses the channel's binary encoding. Do not Base64-encode binary payloads as JSON strings. |
| CH5 | Channel modules should be <=150 lines (soft gate — a few lines over is acceptable if the code is succinct). Delegate business logic to context modules or the Orchestrator. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| CHI1 | Use `Phoenix.Channel.push/3` for server-to-client. Use `broadcast/3` only when all channel subscribers need the message. | Broadcasting to a channel when only one client needs the data. |
| CHI2 | Use `Presence` (not custom tracking) for user presence on channels. | Hand-rolled presence tracking with GenServers. |
| CHI3 | Use `intercept/1` only when you need to filter or modify outgoing broadcasts per-client. | Intercepting every event "just in case." |

### Testability

| # | Criterion |
|---|-----------|
| CHT1 | Channel tests use `Phoenix.ChannelTest` (`subscribe_and_join/3`, `push/3`, `assert_push/2`). |
| CHT2 | Authentication rejection is tested: invalid token -> join fails. |
| CHT3 | Each command type (`start_loop`, `stop_loop`, etc.) has a test that pushes the command and asserts the expected reply or broadcast. |

### Test Coverage

| # | Criterion |
|---|-----------|
| CHC1 | Every server->daemon command from SDD Section 4.5 has a channel test. |
| CHC2 | Every daemon->server event from SDD Section 4.5 has a channel test. |
| CHC3 | Error cases (malformed payloads, unknown loop IDs, daemon at capacity) are tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| CHD1 | Channel callbacks containing database queries or complex logic instead of delegating to context modules. |
| CHD2 | Hardcoded topic strings scattered across the codebase instead of using a topic-builder function (e.g., `Topics.daemon(id)`). |
| CHD3 | Missing rate limiting on `terminal_output` or `stdin_input` events. |

---

## Ecto (Data Layer)

### Quality

| # | Criterion |
|---|-----------|
| EQ1 | Schemas mirror the SDD Section 9 table definitions exactly. Column names, types, and constraints match. |
| EQ2 | Changesets validate all constraints that the database enforces. Never rely on the database to catch a validation that Ecto should catch (except uniqueness, which requires a DB constraint). |
| EQ3 | Migrations are reversible (`change` function) unless truly irreversible (data migration). Irreversible migrations use `up`/`down` with a comment explaining why `down` is not possible. |
| EQ4 | No `Repo` calls outside context modules. LiveViews, Channels, and GenServers call context functions. |
| EQ5 | Queries use named bindings and keyword syntax for simple queries. Use `from` macro only for joins or complex conditions. |
| EQ6 | Every schema has explicit `@primary_key` and `@foreign_key_type` declarations when not using the default. |
| EQ7 | Indexes exist for every foreign key and every column used in `WHERE` clauses (as specified in SDD Section 9). |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| ECI1 | Use `Ecto.Multi` for operations that must be atomic (e.g., creating a DAG + loops + dependencies). | Multiple sequential `Repo.insert` calls without a transaction. |
| ECI2 | Use `Repo.preload` explicitly. Never use `has_many` with eager loading by default. | N+1 queries: loading a list then preloading in a loop. |
| ECI3 | Use `Ecto.Enum` for status fields (`status: Ecto.Enum, values: [:backlog, :in_progress, ...]`). | String-typed status fields with ad-hoc validation. |
| ECI4 | Use upserts (`on_conflict`) for daemon heartbeat updates instead of select-then-update. | Separate SELECT + UPDATE for heartbeat writes (race condition risk). |
| ECI5 | Cast and validate all external input through changesets, even for internal API boundaries. | Passing raw maps to `Repo.insert` without changeset validation. |

### Testability

| # | Criterion |
|---|-----------|
| ECT1 | Use `Ecto.Adapters.SQL.Sandbox` in test mode. Every test runs in a transaction that rolls back. |
| ECT2 | Factory module (e.g., `Algedonia.Factory` or ExMachina) provides builders for every schema. No hand-crafting `%Ticket{}` structs in tests. |
| ECT3 | Context function tests use the factory, not raw SQL. |
| ECT4 | Migration tests: run `mix ecto.migrate` and `mix ecto.rollback` as part of CI. |

### Test Coverage

| # | Criterion |
|---|-----------|
| ECC1 | Every changeset function: one test per validation rule, one test with valid input. |
| ECC2 | Every context function: happy path + at least one error path. |
| ECC3 | Queries that filter by status, priority, or assignee have tests verifying correct filtering. |
| ECC4 | `Ecto.Multi` operations are tested for both full success and partial failure (rollback). |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| ECD1 | Raw SQL queries (`Repo.query`) when Ecto's query DSL can express the same thing. Exception: complex CTEs or window functions. |
| ECD2 | Schemas with fields not in the SDD data model (schema drift). |
| ECD3 | Missing indexes on columns used in WHERE clauses or JOINs. |
| ECD4 | Changesets that `cast` all fields including those that should be server-controlled (e.g., `inserted_at`). |
| ECD5 | Context modules significantly over ~300 lines. Split by entity (e.g., `Tickets`, `Loops`, `Dags`). |

---

## OTP / GenServer (Stateful Processes)

### Quality

| # | Criterion |
|---|-----------|
| GS1 | Every GenServer has a clear, documented reason for being stateful. If the process only wraps database calls, it should be a plain module, not a GenServer. |
| GS2 | GenServer state is a well-typed struct, not a bare map. Define a `defstruct` in the module. |
| GS3 | `init/1` is fast (<100ms). Defer expensive setup to `handle_continue/2`. |
| GS4 | Every `handle_call/3` and `handle_cast/2` has a catch-all clause that logs unexpected messages. `handle_cast` catch-all returns `{:noreply, state}`. `handle_call` catch-all returns `{:reply, {:error, :unknown_message}, state}` (never `{:noreply, state}`, which would cause caller timeouts). |
| GS5 | `handle_info/2` handles `:DOWN` and `:EXIT` messages for any monitored/linked processes. |
| GS6 | State recovery: on startup, GenServers for `CircuitBreaker` and `Orchestrator` reload state from PostgreSQL. |
| GS7 | Supervision tree is documented: which supervisor owns which children, restart strategy (`:one_for_one` vs `:rest_for_one`). |
| GS8 | GenServer modules should be <=200 lines (soft gate — a few lines over is acceptable if the code is succinct). Extract helper functions into a companion module. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| GSI1 | Use `GenServer.call/3` with an explicit timeout for operations that must respond. | Infinite timeouts on calls that hit the database. Default timeout: 5_000ms. |
| GSI2 | Use `handle_continue/2` for post-init work. | Blocking `init/1` with database queries or network calls. |
| GSI3 | Persist state changes to PostgreSQL before responding to the caller (write-ahead). | Responding to calls with in-memory state that hasn't been persisted (crash loses data). |
| GSI4 | Use `Process.send_after/3` for periodic tasks (daemon health checks). | `:timer.send_interval` (harder to cancel and test). |
| GSI5 | Use `Registry` or `:via` tuples for process lookup when there may be multiple instances. | Hardcoded atom names for processes that could be parameterized. |

### Testability

| # | Criterion |
|---|-----------|
| GST1 | GenServers can be started in tests with `start_supervised/2` and a test-specific name to avoid global state leaks. |
| GST2 | Time-dependent behavior (heartbeat timeouts, circuit breaker thresholds) is configurable, not hardcoded. Tests pass short intervals. |
| GST3 | The public API of a GenServer (the client functions) is the test surface, not the internal callbacks. |
| GST4 | Crash recovery is tested: kill the GenServer, restart it, verify state is reconstructed from the database. |

### Test Coverage

| # | Criterion |
|---|-----------|
| GSC1 | `Algedonia.Orchestrator`: test every loop state transition from SDD Section 9 loop state machine. |
| GSC2 | `Algedonia.Scheduler`: test daemon selection logic (prefer creator's daemon, fallback to least-loaded). |
| GSC4 | `Algedonia.CircuitBreaker`: test all state transitions (closed->open, open->half_open, half_open->closed, half_open->open). |
| GSC5 | `Algedonia.DaemonMonitor`: test healthy->unhealthy->offline transitions at correct time thresholds. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| GSD1 | GenServer state growing unboundedly (e.g., accumulating terminal buffer without a cap). |
| GSD2 | Synchronous `call` to a GenServer from within another GenServer's callback (deadlock risk). |
| GSD3 | Business logic inside GenServer callbacks instead of delegating to pure functions. |
| GSD4 | Missing supervision: a GenServer started outside the supervision tree. |
| GSD5 | Catch-all `handle_info/2` that silently swallows messages without logging. |

---

## Go (Daemon Language)

### Quality

| # | Criterion |
|---|-----------|
| GO1 | Functions should be <=40 lines (soft gate — a few lines over is acceptable if the code is succinct and readable). Exception: switch statements with many cases may exceed this. |
| GO2 | Files should be <=500 lines (soft gate — a few lines over is acceptable if the code is succinct). Split by concern if significantly exceeded (e.g., `pty.go`, `repo.go`, `adapter.go`). |
| GO3 | Exported functions and types have godoc comments starting with the name. |
| GO4 | Error handling: every error is either handled, wrapped with `fmt.Errorf("context: %w", err)`, or returned. No ignored errors (no blank `_` for error returns except in tests or deferred Close calls). |
| GO5 | Formatting: all code passes `gofmt`. No exceptions. |
| GO6 | Linting: all code passes `golangci-lint run` with the project config. |
| GO7 | No `panic` in production code. Exception: `init()` functions for truly unrecoverable setup failures. |
| GO8 | Struct fields are documented with comments when their purpose is not self-evident. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| GOI1 | Accept interfaces, return structs. | Returning interface types from constructors. |
| GOI2 | Use `context.Context` for cancellation and timeouts on all I/O operations. | Goroutines without a cancellation mechanism. |
| GOI3 | Use `sync.WaitGroup` or `errgroup.Group` for coordinating concurrent operations. | Bare goroutines with no join/wait mechanism. |
| GOI4 | Use table-driven tests. | Repetitive test functions with copy-pasted setup. |
| GOI5 | Use `errors.Is` and `errors.As` for error checking. | String comparison on error messages. |
| GOI6 | Close resources with `defer` immediately after acquisition. | Deferred Close calls far from the Open call. |
| GOI7 | Use structured logging (e.g., `slog`) with key-value pairs. | `fmt.Println` for logging. |

### Testability

| # | Criterion |
|---|-----------|
| GOT1 | External dependencies (WebSocket connection, file system, process spawning) are behind interfaces. Tests inject fakes. |
| GOT2 | Time-dependent behavior uses a clock interface or `time.AfterFunc` with injectable timers. |
| GOT3 | Tests do not depend on network access or external binaries (mock the agent adapters). |
| GOT4 | Test helpers are in `_test.go` files in the same package, not in separate test utility packages. |

### Test Coverage

| # | Criterion |
|---|-----------|
| GOC1 | Line coverage target: >=80% for daemon code overall. |
| GOC2 | Every command handler (`start_loop`, `stop_loop`, `pause_agent`, `resume_agent`, `stdin_input`, `squash_and_push`) has unit tests. |
| GOC3 | Error paths (agent crash, push failure) have tests. |
| GOC4 | Reconnection with exponential backoff has a test verifying backoff intervals. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| GOD1 | Package-level variables used for mutable state (use dependency injection instead). |
| GOD2 | Goroutine leaks: goroutines started without a cancellation path or WaitGroup. |
| GOD3 | `interface{}` / `any` used when a concrete type or narrower interface would work. |
| GOD4 | Error messages that don't include context about what operation failed. |
| GOD5 | Commented-out code checked in. |

---

## Go WebSocket Client (Daemon-Server Communication)

### Quality

| # | Criterion |
|---|-----------|
| WS1 | Connection lifecycle is a state machine: `connecting -> connected -> disconnecting -> disconnected`. State transitions are logged. |
| WS2 | Reconnection uses exponential backoff with jitter. Initial delay: 1s. Max delay: 60s. |
| WS3 | Message serialization/deserialization is centralized in one module. No ad-hoc JSON marshaling scattered across the codebase. |
| WS4 | Outbound messages are queued during disconnection (up to a configurable buffer size). Overflow drops oldest messages and logs a warning. |
| WS5 | The WebSocket client implements the Phoenix Channel protocol: join, heartbeat (Phoenix-level, distinct from daemon heartbeat), push, reply matching via `ref`. |
| WS6 | Heartbeat (Phoenix-level) is sent every 30s. If no reply within 10s, the connection is considered dead and reconnection begins. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| WSI1 | Use a single long-lived goroutine for reading and a single one for writing. Coordinate via channels. | Multiple goroutines writing to the same WebSocket connection. |
| WSI2 | Use `context.Context` to shut down the connection cleanly. | Calling `os.Exit` or leaving goroutines orphaned on shutdown. |
| WSI3 | Match Phoenix reply refs to correlate responses with requests. Use a pending-replies map with timeouts. | Fire-and-forget pushes when the server expects a reply. |

### Testability

| # | Criterion |
|---|-----------|
| WST1 | A mock WebSocket server exists in tests that speaks the Phoenix Channel protocol (join, push, reply). |
| WST2 | Reconnection logic is testable without real network delays (inject a clock or use short intervals). |
| WST3 | Message send and receive paths are tested independently of the WebSocket transport (test the serialization layer separately). |

### Test Coverage

| # | Criterion |
|---|-----------|
| WSC1 | Connection establishment and authentication (project token) tested. |
| WSC2 | Reconnection after disconnect tested (verify backoff behavior). |
| WSC3 | Every command from SDD Section 4.5 (server->daemon) is tested: message is deserialized and dispatched correctly. |
| WSC4 | Every event from SDD Section 4.5 (daemon->server) is tested: message is serialized and sent correctly. |
| WSC5 | Buffer overflow during disconnection is tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| WSD1 | Hardcoded server URL or project token instead of configuration. |
| WSD2 | No timeout on WebSocket read/write operations. |
| WSD3 | Phoenix channel ref counter that can overflow or is not thread-safe. |
| WSD4 | Missing graceful shutdown: daemon exits without sending a leave message or draining in-flight messages. |

---

## Go PTY / Process Management (Agent Lifecycle)

### Quality

| # | Criterion |
|---|-----------|
| PTY1 | PTY allocation uses `os/exec` with `Cmd.SysProcAttr` for process group management (SIGSTOP/SIGCONT target the group, not just the leader). |
| PTY2 | PTY master fd is closed when the process exits. No fd leaks. Verify with a test that checks open fd count. |
| PTY3 | Output chunking: flush every 50ms or at 4KB, whichever comes first. Both thresholds are configurable. |
| PTY4 | Process exit is detected via `Wait()` in a goroutine. Crash (non-zero exit) is distinguished from normal exit. |
| PTY5 | SIGTERM is sent first; SIGKILL after a 5s grace period. Grace period is configurable. |
| PTY6 | Concurrent access to the process table (running loops map) is protected by a mutex or uses a channel-based actor. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| PTYI1 | Use `syscall.Kill(-pid, signal)` to signal the process group. | Signaling only the leader process (children survive). |
| PTYI2 | Use a context for each spawned process. Canceling the context triggers cleanup. | Manual cleanup paths that can be skipped on error. |
| PTYI3 | Use `io.Copy` or a buffered reader in a goroutine to drain PTY output. | Blocking the main goroutine on PTY reads. |

### Testability

| # | Criterion |
|---|-----------|
| PTYT1 | Tests spawn a real subprocess (e.g., `echo`, `cat`, `sleep`) to verify PTY behavior. No mocking of the PTY layer itself. |
| PTYT2 | Signal handling (pause/resume/kill) is tested with a subprocess that writes output, verifying output stops on SIGSTOP and resumes on SIGCONT. |
| PTYT3 | Output chunking is tested: verify flush timing and size thresholds produce expected chunk boundaries. |

### Test Coverage

| # | Criterion |
|---|-----------|
| PTYC1 | Spawn + normal exit path tested. |
| PTYC2 | Spawn + crash (non-zero exit) path tested. |
| PTYC3 | Pause (SIGSTOP) + resume (SIGCONT) tested. |
| PTYC4 | Kill (SIGTERM -> SIGKILL after timeout) tested. |
| PTYC5 | stdin write (user steering) tested: data written to PTY master appears in process stdin. |
| PTYC6 | Concurrent PTY sessions (3+ simultaneous) tested for fd leaks and interference. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| PTYD1 | Hardcoded PTY window size instead of configurable (or negotiated with the terminal widget). |
| PTYD2 | Missing cleanup of PTY resources in error paths (e.g., fd leak when process spawn fails after PTY allocation). |
| PTYD3 | Process table (loop_id -> process) without a cleanup sweep for orphaned entries. |

---

## Go Git Operations (Repo Management)

### Quality

| # | Criterion |
|---|-----------|
| GIT1 | All git operations shell out to the `git` CLI (not a Go git library). Rationale: rebase behavior must match the user's git exactly. |
| GIT2 | Every git command captures both stdout and stderr. Errors include the stderr output in the error message. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| GITI1 | Use `exec.CommandContext` so git operations respect cancellation. | Long-running git operations without timeout (e.g., a clone that hangs). |
| GITI2 | Parse git output minimally. Use exit codes for success/failure. Parse stdout only when specific data is needed (e.g., branch name). | Parsing `git status --porcelain` output with regexes when a simpler check suffices. |

### Testability

| # | Criterion |
|---|-----------|
| GITT1 | Tests use a temporary git repository (created with `git init` in a temp dir). No reliance on an external repo. |
| GITT2 | The git binary path is configurable (injectable) so tests can substitute a wrapper that records calls. |

### Test Coverage

| # | Criterion |
|---|-----------|
| GITC1 | Bare repo clone tested. |
| GITC2 | Fetch on existing repo tested. |
| GITC3 | Squash-rebase onto base branch tested (verify single commit on base branch after squash). |
| GITC4 | Push success and push failure (e.g., conflicting remote changes) tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| GITD1 | Hardcoded branch naming conventions instead of using the server-provided `branch_name`. |
| GITD2 | No timeout on git operations (a slow network can hang the daemon). All git operations should have a context timeout of 120s max. |

---

## PostgreSQL Schema (Data Model)

### Quality

| # | Criterion |
|---|-----------|
| PG1 | Every table has a primary key. UUIDs for application tables, `bigserial` only for the `events` table (as specified in SDD). |
| PG2 | Every foreign key has a corresponding index. |
| PG3 | `NOT NULL` constraints on every column specified as "Not null" in SDD Section 9. |
| PG4 | Status columns use `CHECK` constraints to enforce valid values (e.g., `CHECK (status IN ('backlog', 'decomposing', ...))`). |
| PG5 | `timestamptz` (not `timestamp`) for all time columns. |
| PG6 | The `events` table is append-only. No UPDATE or DELETE operations. Enforce via application code (no DB-level trigger required in v1, but no context function should update or delete events). |
| PG7 | Array columns (`text[]`) have a GIN index if they appear in WHERE clauses. |
| PG8 | Unique constraints match SDD: `dags.ticket_id` is unique, `loop_dependencies(upstream_loop_id, downstream_loop_id)` is unique. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| PGI1 | Use database-level constraints (NOT NULL, CHECK, UNIQUE, FK) as the last line of defense. Ecto validates first, but the DB catches what Ecto misses. | Relying solely on application-level validation. |
| PGI2 | Use `jsonb` (not `json`) for all JSON columns. It supports indexing and comparison. | `json` type, which stores as text and doesn't support efficient querying. |
| PGI3 | Name indexes explicitly following the pattern `idx_{table}_{columns}`. | Default auto-generated index names that are hard to reference in discussions. |

### Testability

| # | Criterion |
|---|-----------|
| PGT1 | Migrations can be run forward and backward (`mix ecto.migrate` + `mix ecto.rollback`) without data loss in test fixtures. |
| PGT2 | Constraint violations (unique, FK, check) are tested by attempting the violating operation and asserting the error. |

### Test Coverage

| # | Criterion |
|---|-----------|
| PGC1 | Every migration is covered by the rollback test (see PGT1). |
| PGC2 | Constraint tests exist for: unique ticket DAG, unique file lock per loop, unique loop dependency pair. |
| PGC3 | Foreign key cascade behavior is tested (e.g., deleting a ticket cascades to comments and DAGs as appropriate). |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| PGD1 | Tables or columns that exist in the database but not in SDD Section 9 (schema drift). |
| PGD2 | Missing indexes on columns used in WHERE or JOIN clauses. |
| PGD3 | `text` columns storing structured data that should be `jsonb` or a separate table. |
| PGD4 | Migrations that modify data in-place without a reversible strategy. |

---

## Server-Daemon Protocol (Interface Contract)

### Quality

| # | Criterion |
|---|-----------|
| PR1 | Message schemas are defined once and shared: a schema file or module on each side (Elixir struct/map spec on server, Go struct with JSON tags on daemon). |
| PR2 | Every message includes `loop_id` for traceability (except `heartbeat` and connection-level messages). |
| PR3 | Every command from server has an acknowledged reply or error from the daemon. No fire-and-forget commands. |
| PR4 | Unknown message types are logged and ignored, not crashed on. Forward-compatible. |
| PR5 | Message payloads match SDD Section 7.1 exactly. No extra fields, no missing fields, no renamed fields. |
| PR6 | Binary data (`terminal_output.data`) is sent as binary frames, not Base64-encoded JSON strings. |
| PR7 | Timestamps use Unix milliseconds (integer), not formatted strings. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| PRI1 | Version the protocol. Include a `protocol_version` field in the join message. Server rejects incompatible versions. | Breaking the protocol without a version bump. |
| PRI2 | Use the same field names on both sides (Elixir and Go). JSON keys are `snake_case`. | Camel case in Go JSON tags that don't match Elixir atom keys. |
| PRI3 | Validate incoming messages against the schema before processing. | Trusting that the other side always sends correct payloads. |

### Testability

| # | Criterion |
|---|-----------|
| PRT1 | Server-side channel tests simulate a daemon: join the channel and push events, assert server behavior. |
| PRT2 | Daemon-side tests use a mock server: connect, send commands, verify daemon responses. |
| PRT3 | End-to-end integration test: real server + real daemon (no mocks) for at least one full flow (connect -> start_loop -> terminal_output -> attempt_complete). |

### Test Coverage

| # | Criterion |
|---|-----------|
| PRC1 | Every command type (6 commands in SDD 4.5) has a round-trip test. |
| PRC2 | Every event type (4 events in SDD 4.5) has a round-trip test. |
| PRC3 | Protocol version mismatch is tested: server rejects daemon with wrong version. |
| PRC4 | Large payload handling: `terminal_output` with 4KB+ data, `attempt_complete` with a large diff. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| PRD1 | Server and daemon have divergent message schemas (different field names, types, or structures). |
| PRD2 | Hardcoded message type strings instead of constants/enums on both sides. |
| PRD3 | No timeout on expecting a reply from the daemon after sending a command. |
| PRD4 | Terminal output events without timestamps (makes latency measurement impossible). |

---

## Planning Quality

Criteria for planning phases when extending schemas, adding enum variants, or modifying shared data models. Motivated by [Postmortem 001](postmortems/001-hook-loop-isolation.md).

### Impact Audit

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P1 | Impact audit for schema changes | When adding a field, enum variant, or association to an existing schema, the plan must include a grep/search for all existing queries, filters, and pattern matches on that schema. Each hit must be evaluated for correctness with the new variant. Fail if no search evidence is provided. |

### Blast Radius

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P2 | Blast radius subsection | Every plan that modifies a shared schema (used by >1 context module) must include a "Blast Radius" subsection listing: (a) all modules that query or pattern-match on the schema, (b) which ones need changes, (c) which ones are confirmed safe. Fail if the subsection is missing or incomplete. |

### Isolation Invariants

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P3 | Isolation invariants specification | When adding a new variant to a type used for dispatch (e.g., loop role, ticket status), the plan must state the isolation invariant: which code paths handle the new variant, and which existing paths must exclude it. Fail if the invariant is not stated or if existing paths are not explicitly addressed. |

### Cross-Cutting Query Audit

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P4 | Cross-cutting query audit for new enum variants | When adding a new enum variant, every query that filters or groups by the enum field must be listed in the plan with a disposition: "needs update", "safe as-is" (with reason), or "new query". Fail if any query is unlisted. Search patterns to use: the field name (e.g., `role`), query function names (e.g., `list_loops`, `_for_dag`), and enum values in the same field. |

### Interaction Tests

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P5 | Interaction test requirements for shared data models | When a new variant coexists with existing variants in the same table/collection, the plan must require interaction tests: scenarios where both old and new variants are present and existing logic produces correct results. Fail if interaction tests are not listed as deliverables. |

---

# Part 2: Per-Slice Rubrics

---

## Slice 1: Ticket CRUD

### Verification Criteria (from slices doc)

1. User can create a ticket with title, description, type, priority, assignee, and acceptance criteria.
2. Created ticket appears in the ticket list without a page reload.
3. User can click a ticket to open the detail panel showing all fields.
4. User can edit any field on an existing ticket; changes persist after page reload.
5. User can delete a ticket; it disappears from the list.
6. Status field defaults to `backlog`.
7. Tickets are sortable by priority.
8. Tickets are filterable by status and assignee.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S1-Q1 | `Algedonia.Tickets` context module exists with `list_tickets/1`, `get_ticket!/1`, `create_ticket/1`, `update_ticket/2`, `delete_ticket/1`. All return tagged tuples (except `get_ticket!` which raises). |
| S1-Q2 | `Ticket` schema uses `Ecto.Enum` for `status` and `type` fields. |
| S1-Q3 | `TicketLive.Index` uses `stream` for the ticket list, not a plain assign. |
| S1-Q4 | Changeset validates: `title` is required, `status` is one of the SDD-defined values, `priority` is 1-5, `type` is one of `feature/bug/chore/spike`. |
| S1-Q5 | Filter and sort parameters are in the URL query string so the view is bookmarkable. |
| S1-Q6 | The detail panel does not reload the entire ticket list when opened. |
| S1-Q7 | Seed data script is in `priv/repo/seeds.exs` with at least 5 tickets across different statuses. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | `Ticket` changeset: valid attrs, missing title, invalid status, invalid priority, invalid type. |
| Unit | `Algedonia.Tickets` context: create, read, update, delete, list with filters, list with sort. |
| Integration (LiveView) | Mount `/tickets` renders ticket list. Create via form, verify appears in list. Edit a field, verify persistence. Delete, verify removal. Open detail panel. Sort by priority. Filter by status. |

---

## Slice 2: Ticket Comments

### Verification Criteria (from slices doc)

1. User can post a top-level comment on a ticket.
2. Comment appears immediately without page reload.
3. User can reply to an existing comment; the reply renders indented beneath its parent.
4. A second browser tab viewing the same ticket sees new comments in real time.
5. Comments display author name and timestamp.
6. Comments render Markdown body content.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S2-Q1 | `Algedonia.Comments` context module (or `Algedonia.Tickets.Comments` submodule) with `list_comments/1`, `create_comment/1`. |
| S2-Q2 | Comment `parent_id` is nullable. Top-level comments have `parent_id: nil`. |
| S2-Q3 | Comments are loaded with a single query + in-memory tree assembly, not N+1 queries per nesting level. |
| S2-Q4 | PubSub broadcast uses topic `ticket:{ticket_id}`. The comment component handles the broadcast to append new comments without refetching the list. |
| S2-Q5 | Markdown rendering is sanitized (no XSS via raw HTML in Markdown). |
| S2-Q6 | Author name is required and non-empty in the changeset. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | `Comment` changeset: valid attrs, missing body, missing author, missing ticket_id. |
| Unit | Context: create top-level comment, create reply (with parent_id), list comments for a ticket (verify threading structure). |
| Integration (LiveView) | Post a comment, verify it appears. Post a reply, verify indentation. PubSub test: broadcast a comment, verify second LiveView session receives it. Markdown rendering. |

---

## Slice 3: Daemon Connection and Heartbeat

### Verification Criteria (from slices doc)

1. Daemon binary starts and connects to the server using a project token.
2. Server creates a `daemon_registrations` row with status `online`.
3. `/monitor` page shows the daemon name, status "online", capacity, and last heartbeat time.
4. Heartbeat updates are visible in the UI without page reload (last heartbeat time updates).
5. Stopping the daemon causes status to transition to `unhealthy` within 30 seconds, reflected in the UI.
6. After 5 minutes of silence, daemon status becomes `offline`.
7. Restarting the daemon re-establishes the connection and status returns to `online`.
8. An invalid project token is rejected at channel join.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S3-Q1 | `DaemonChannel` authenticates on `join/3` by verifying the project token. Returns `{:error, %{reason: "unauthorized"}}` on failure. |
| S3-Q2 | `Algedonia.DaemonMonitor` GenServer checks heartbeats periodically (configurable interval, default 10s). Uses `Process.send_after/3` for scheduling. |
| S3-Q3 | Daemon health transitions are persisted to `daemon_registrations` table and broadcast on `monitor` PubSub topic. |
| S3-Q4 | Go daemon reconnection uses exponential backoff: 1s, 2s, 4s, ... up to 60s max. |
| S3-Q5 | Go daemon heartbeat includes: `daemon_id`, `running_loops`, `capacity`, `system` (cpu_percent, memory_available_mb). Matches SDD Section 7.1 schema. |
| S3-Q6 | Go daemon is a single static binary with no runtime dependencies beyond `git`. |
| S3-Q7 | Daemon config (server URL, project token, display name, max capacity) is read from environment variables or a config file. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Elixir) | `DaemonChannel` join with valid token, join with invalid token. Heartbeat handler updates daemon record. |
| Unit (Elixir) | `DaemonMonitor` GenServer: healthy->unhealthy after 30s silence, unhealthy->offline after 5min. |
| Unit (Go) | Heartbeat message construction and serialization. Config loading from env vars. |
| Unit (Go) | Reconnection backoff logic: verify delay sequence (1s, 2s, 4s, 8s, ..., 60s cap). |
| Integration | Channel test: daemon joins, sends heartbeat, server updates registration. |
| Integration (LiveView) | Mount `/monitor`, verify daemon appears. Simulate missed heartbeats, verify status change in UI. |

---

## Slice 4: Presence and Real-Time Collaboration

### Verification Criteria (from slices doc)

1. User is prompted for a display name on first visit.
2. Viewing `/tickets` shows other users also viewing that page.
3. Viewing `/loops/:id` shows other users viewing that specific loop.
4. When a user navigates away, their presence disappears within a few seconds.
5. Presence works across the ticket list, DAG view, Loop Inspector, and Monitor.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S4-Q1 | Display name is stored in the browser session (Phoenix session / cookie), not re-prompted on every page load. |
| S4-Q2 | Presence uses `Phoenix.Presence` module, not a custom tracking implementation. |
| S4-Q3 | Presence topic is scoped to the specific view (e.g., `presence:tickets`, `presence:loops:123`), not a global topic. |
| S4-Q4 | Presence data includes only `display_name` and `current_view`. No sensitive data. |
| S4-Q5 | Presence indicators are a reusable function component used across all four views. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Presence tracking: user joins, appears in presence list. User leaves, disappears. |
| Integration (LiveView) | Two LiveView sessions on the same page see each other in the presence list. Navigation away removes presence. |

---

## Slice 5: Terminal Streaming

### Verification Criteria (from slices doc)

1. Server sends a `start_loop` command to the daemon; daemon spawns the specified process in a PTY.
2. Terminal output streams to the browser and renders in an interactive terminal widget.
3. ANSI color codes and cursor movement render correctly.
4. A second browser tab opening the same loop sees the scrollback buffer.
5. Stopping the loop (via `stop_loop`) terminates the process and the terminal shows it has ended.
6. Latency from daemon PTY output to browser render is under 200ms.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S5-Q1 | Server terminal buffer is in-memory, keyed by `loop_id`, capped at 10,000 lines (configurable). |
| S5-Q2 | Terminal buffer is cleaned up when a loop completes (pass, fail, or escalate). No memory leaks for completed loops. |
| S5-Q3 | `terminal:{loop_id}` PubSub topic is used for fan-out to browser clients. |
| S5-Q4 | `LoopLive.Show` uses `push_event/3` to send terminal data to the xterm.js JavaScript hook. |
| S5-Q5 | Daemon output chunking (50ms / 4KB) is implemented as specified. No character splitting mid-UTF-8 sequence. |
| S5-Q6 | `stop_loop` sends SIGTERM, waits 5s, then SIGKILL. Both signals target the process group. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Go) | PTY spawn, output reading, chunking logic (time-based and size-based flush). |
| Unit (Go) | Stop loop: SIGTERM then SIGKILL sequence. |
| Unit (Elixir) | Terminal buffer: write data, read scrollback, verify cap enforcement, verify cleanup on loop completion. |
| Integration (Channel) | `start_loop` command -> daemon spawns process -> `terminal_output` events arrive at server. |
| Integration (Channel) | `stop_loop` command -> process is terminated -> daemon reports completion. |
| Integration (LiveView) | Mount `/loops/:id`, verify terminal widget renders. Late-join viewer sees scrollback. |

---

## Slice 6: User Terminal Input (Steering)

### Verification Criteria (from slices doc)

1. User types in the browser terminal; keystrokes appear in the daemon process's stdin.
2. Interactive prompts (e.g., a shell) respond to user input from the browser.
3. User can pause a running process; terminal freezes and process is stopped.
4. User can resume a paused process; it continues from where it left off.
5. Multiple browser tabs can send input to the same session; inputs arrive in order.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S6-Q1 | Browser terminal hook captures raw keystrokes and sends them via `push_event` to the LiveView, which forwards via Channel `stdin_input` command. |
| S6-Q2 | `stdin_input` data is written directly to the PTY master fd with no transformation. |
| S6-Q3 | Pause/resume buttons are disabled when the loop is not in `running_maker` or `running_checker` status. |
| S6-Q4 | Pause/resume state is reflected in the Loop Inspector UI (e.g., "Paused" badge). |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Go) | Write to PTY master fd, verify child process receives it on stdin. |
| Unit (Go) | SIGSTOP pauses process, SIGCONT resumes. Output stops during pause and resumes after. |
| Integration (Channel) | `stdin_input` command -> data appears in process stdin. `pause_agent` -> process stops. `resume_agent` -> process continues. |
| Integration (LiveView) | Simulate keystroke in terminal hook, verify round-trip. Pause/resume buttons toggle state. |

---

## Slice 7: Agent Adapter and Claude Code (Daemon-side)

### Verification Criteria (from slices doc)

1. Daemon receives a `start_loop` command with role `decompose` and spawns Claude Code via the adapter interface.
2. The agent adapter interface is defined as a Go interface type with all six methods.
3. Claude Code adapter constructs the correct CLI invocation and passes the task description.
4. Daemon loads the decompose system prompt from `.algedonia/prompts/decompose.md`.
5. Terminal output from the agent process streams to the server via PTY.
6. On agent exit, the daemon parses structured output and returns the DAG + rubrics to the server.
7. Agent crash is detected and reported as an error event.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S7-Q1 | `AgentAdapter` Go interface has exactly: `Start`, `AttachPTY`, `SendInput`, `Wait`, `Kill`, `SessionID`. |
| S7-Q2 | Claude Code adapter is in its own file (`adapter_claude.go` or similar). |
| S7-Q3 | Prompt loading reads from the repo's `.algedonia/prompts/` directory, not a hardcoded system path. |
| S7-Q4 | Structured output parsing has clear error handling: if the agent output is malformed, return an error event (don't panic or silently drop). |
| S7-Q5 | Agent session ID is captured and included in the `attempt_complete` event. |
| S7-Q6 | Agent environment variables (LLM API keys) are inherited from the daemon process environment. Never logged or sent to the server. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Go) | `AgentAdapter` interface compliance: verify Claude Code adapter implements all methods. |
| Unit (Go) | CLI invocation construction: correct binary, flags, and task passing. |
| Unit (Go) | Prompt loading: reads correct file from prompts directory. Missing prompt file returns error. |
| Unit (Go) | Structured output parsing: valid output, malformed output. |
| Integration | `start_loop` with role `decompose` -> agent spawns -> output streams -> structured result returned. (Can use a mock agent binary that emits canned output.) |

---

## Slice 8: Decomposition and DAG View (Server/UI)

### Verification Criteria (from slices doc)

1. Clicking "Start Work" transitions the ticket status to `decomposing`.
2. The decomposition agent runs and its terminal output streams to the Loop Inspector.
3. On success, the DAG view shows the resulting loops as nodes with dependency edges.
4. Each loop has a title, description, and generated rubric.
5. Generated rubrics follow SDD Section 7.4 format: Hard Gates, Weighted Checks, Acceptance Criteria, Threshold, and Options sections.
6. Loop statuses start as `pending`.
7. Ticket status transitions to `in_progress` after successful decomposition.
8. If decomposition fails 3 times, ticket status becomes `decomposition_failed` and the user can retry.
9. The DAG view updates in real time via PubSub.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S8-Q1 | DAG creation uses `Ecto.Multi` to atomically insert the `dags` row, all `loops` rows, and all `loop_dependencies` rows. |
| S8-Q2 | `Algedonia.Orchestrator` handles the `start_work` command and manages decomposition retries (up to 3, exponential backoff). |
| S8-Q3 | `DagLive.Show` renders the graph using a JavaScript library (e.g., dagre, d3-dag) via a hook. The graph layout is computed client-side, not in Elixir. |
| S8-Q4 | DAG view node colors match SDD Section 2.2: pending=gray, running=blue, verifying=yellow, passed=green, failed=red, escalated=orange, needs_clarification=purple, pending_approval=teal. |
| S8-Q5 | "Start Work" button is disabled when ticket status is not `backlog` (prevent double-clicks or re-decomposition of in-progress tickets). |
| S8-Q6 | PubSub broadcasts on `dag:{ticket_id}` for every loop status change in the DAG. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | `Algedonia.Dags` context: create DAG with loops and dependencies (via Multi), verify all rows created. |
| Unit | Orchestrator: `start_work` triggers decomposition, handles success (creates DAG), handles failure (retries, eventually sets `decomposition_failed`). |
| Unit | Rubric format validation: generated rubrics contain required sections (Hard Gates, Weighted Checks, Acceptance Criteria, Threshold, Options). |
| Integration (LiveView) | Click "Start Work" on a ticket, verify ticket status changes. DAG view renders nodes. PubSub updates propagate to DAG view. |

---

## Slice 9: Maker Agent Execution

### Verification Criteria (from slices doc)

1. After decomposition, root loops (no upstream dependencies) transition to `ready` then `assigned`.
2. The maker agent spawns and its terminal output streams to the Loop Inspector.
4. When the agent exits, the diff is captured and sent to the server.
5. The attempt is recorded in `loop_attempts` with diff, exit code, and session ID.
6. A state transition event is recorded in the `events` table.
7. The diff is visible in the Loop Inspector's right panel.
8. The DAG view shows the loop node as `running_maker` during execution.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S9-Q1 | `Algedonia.Scheduler` GenServer identifies root loops (no incoming edges in `loop_dependencies`) after DAG creation. |
| S9-Q2 | Loop state transitions are persisted to the `events` table before the next action (write-ahead pattern). |
| S9-Q3 | `loop_attempts` records include `duration_ms` calculated from attempt start to completion. |
| S9-Q4 | Daemon runs `git fetch` before spawning the agent to ensure the base branch is current. |
| S9-Q5 | Diff viewer in Loop Inspector sanitizes the diff (no XSS via crafted file contents). |
| S9-Q6 | Attempt history component is a reusable function component (reused in slices 10, 12, 14). |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Elixir) | Scheduler: after DAG creation, root loops are identified and transition to `ready`. Daemon assignment: prefers ticket creator's daemon. |
| Unit (Elixir) | Event recording: each state transition produces an event row. |
| Unit (Go) | Attempt result collection: diff, exit code, session ID. |
| Integration (Channel) | Server sends `start_loop` with role `maker` -> daemon spawns agent -> `attempt_complete` event returns diff. |
| Integration (LiveView) | Loop Inspector shows diff viewer after maker completes. DAG view shows `running_maker` color. |

---

## Slice 10: Checker Agent and Merge Gate

### Verification Criteria (from slices doc)

1. After the maker completes, the server sends a checker `start_loop` to the daemon.
2. The checker agent runs in the same working directory and its terminal output streams to the Loop Inspector.
3. Daemon loads checker system prompt from `.algedonia/prompts/checker.md`.
4. Checker scores per pyramid layer are recorded and displayed in the heatmap.
5. A `pass` verdict with all hard gates passing transitions the loop to `passed`.
6. A `pass` verdict with a hard gate failure (e.g., typecheck fails) is overridden to a `fail` verdict.
7. Weighted threshold is applied across pyramid layers as configured in the rubric.
8. A `fail` verdict with remaining attempts sends checker feedback to the maker for retry.
9. A `fail` verdict at max attempts transitions the loop to `escalated`.
10. The DAG view reflects all status transitions in real time.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S10-Q1 | The checker `start_loop` payload does NOT include the maker's conversation history or session ID. Only: diff, task, rubric, acceptance criteria. |
| S10-Q2 | Merge gate logic is a pure function (no side effects, no DB calls) that takes scores + rubric and returns a verdict. Testable in isolation. |
| S10-Q3 | Verification pyramid heatmap component displays five rows: static, deterministic, generative, runtime, semantic. Each row shows pass/fail and confidence as a color gradient. |
| S10-Q4 | Hard gate failures are visually distinct in the heatmap (e.g., red border, icon). |
| S10-Q5 | Orchestrator verdict routing is a single function with pattern matching on `{verdict, hard_gates_passed, attempts_remaining}`. |
| S10-Q6 | The `scores` field in `loop_attempts` uses the `jsonb` structure: `{static: {passed, confidence, details}, ...}`. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Merge gate function: pass with all hard gates passing, pass with hard gate failure (overridden to fail), weighted threshold boundary (just above, just below), all five pyramid layers. |
| Unit | Orchestrator verdict routing: pass -> passed, fail with retries -> running_maker, fail at max -> escalated. |
| Unit (Go) | Checker role: correct payload sent to agent (no maker history), structured result parsed (scores, verdict, feedback). |
| Integration (Channel) | Maker completes -> server sends checker start_loop -> daemon runs checker -> `loop_result` arrives at server -> correct state transition. |
| Integration (LiveView) | Checker scores appear in heatmap. DAG status colors update. |

---

## Slice 11: Clarify-Resume Flow

### Verification Criteria (from slices doc)

1. A `clarify` verdict from the checker transitions the loop to `needs_clarification`.
2. A system comment is automatically posted on the parent ticket with the checker's clarification feedback.
3. The loop appears in the Monitor escalation queue with a distinct visual indicator (purple).
4. The DAG view shows the loop node as `needs_clarification` (purple).
5. User edits the ticket's acceptance criteria or description.
6. User clicks "Resume" on the halted loop.
7. The loop transitions back to `running_maker` with the updated ticket context (new acceptance criteria, description).
8. The resumed maker attempt receives the updated context and produces a new diff.
9. Full round-trip verified: clarify verdict -> needs_clarification -> ticket update -> resume -> running_maker -> checker re-evaluation.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S11-Q1 | System comments have author `"system"` and are visually distinct from user comments (different styling or badge). |
| S11-Q2 | The "Resume" button is only visible when the loop is in `needs_clarification` status. |
| S11-Q3 | File locks are released when a loop enters `needs_clarification` (the loop is halted, not actively working). |
| S11-Q4 | Resume sends the updated ticket `description` and `acceptance_criteria` to the maker, not the stale original. |
| S11-Q5 | The clarification comment on the ticket includes which loop requested clarification (loop title and ID). |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Orchestrator: `clarify` verdict -> needs_clarification transition, auto-comment creation, lock release. |
| Unit | Resume: loop transitions to `running_maker`, updated ticket context is passed. |
| Integration (LiveView) | Clarification flow round-trip: verify system comment appears, "Resume" button works, maker retries with new context. |

---

## Slice 12: Maker-Checker Loop (Retry, Squash, Merge)

### Verification Criteria (from slices doc)

1. When a maker attempt fails, the next attempt receives compressed summaries of all prior attempts plus full detail on the most recent.
2. Retry increments the attempt counter and records each attempt separately.
3. On pass, the daemon squash-rebases and pushes to the remote.
4. After a loop passes, downstream dependent loops transition from `pending` to `ready`.
5. Multiple loops in a DAG execute in the correct dependency order.
6. Parallel loops (no dependency between them) can execute simultaneously on the same or different daemons.
7. Attempt history in the Loop Inspector shows all attempts with their verdicts and feedback.
8. When all loops in a DAG pass, the ticket transitions to `completed`.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S12-Q1 | Prior attempt compression: attempts older than the most recent 2 are summarized (attempt number, verdict, one-line summary). The 2 most recent attempts include full feedback. |
| S12-Q2 | `squash_and_push` is a separate daemon command (not bundled into `attempt_complete`). The server sends it explicitly after confirming pass. |
| S12-Q3 | If `squash_and_push` fails (e.g., merge conflict), the server receives an error and the loop enters `escalated`. |
| S12-Q4 | DAG completion check uses a single query: `SELECT count(*) FROM loops WHERE dag_id = ? AND status NOT IN ('passed', 'skipped')`. |
| S12-Q5 | Downstream loop unblocking is triggered by the Scheduler after a loop passes, not by the Orchestrator directly (separation of concerns). |
| S12-Q6 | Attempt history displays: attempt number, role (maker/checker), verdict, duration, token usage, session ID (clickable). |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Elixir) | Prior attempt context construction: verify compression logic for 1, 2, 3+ prior attempts. |
| Unit (Elixir) | Scheduler: after loop passes, downstream loops are unblocked. All DAG loops passed -> ticket completed. |
| Unit (Go) | `squash_and_push`: squash-rebase, push, cleanup. Push failure handling. |
| Integration | Full loop lifecycle: maker -> checker pass -> squash_and_push -> downstream unblocked. |
| Integration | Retry flow: maker -> checker fail -> retry with feedback -> checker pass. |
| Integration (LiveView) | Attempt history component renders all attempts. Ticket status updates to completed when all loops pass. |

---

## Slice 13: (Removed)

File-level locking (`LockManager`, `file_locks`, `path_prefixes`) has been removed from the architecture. See T0.2 for rationale.

---

## Slice 14: Escalation Queue

### Verification Criteria (from slices doc)

1. An escalated loop appears in the Monitor escalation queue.
2. Only one escalation is shown at a time; a badge shows remaining count.
3. Escalations are displayed in FIFO order (oldest first).
4. Providing feedback on an escalation transitions the loop back to `running_maker` with the feedback.
5. Editing the rubric on an escalation applies to the next attempt.
6. Skipping a loop marks it as `skipped` and unblocks downstream dependents with a `degraded` flag.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S14-Q1 | Escalation queue is a live query, not a separate table: `SELECT * FROM loops WHERE status IN ('escalated', 'needs_clarification') ORDER BY updated_at ASC`. |
| S14-Q2 | `MonitorLive.Index` uses `assign_async` or a stream for the escalation queue to avoid blocking mount. |
| S14-Q3 | Feedback text is stored in the `loop_attempts` record for the next attempt. |
| S14-Q4 | "Skip" action sets `status: skipped` on the loop and adds a `degraded: true` flag to downstream loops (stored on the loop record or as metadata). |
| S14-Q5 | Rubric edits in the escalation view update the `loops.rubric` field, not the ticket-level rubric. |
| S14-Q6 | Escalation queue updates in real time via `monitor` PubSub topic when a new loop escalates or a resolution occurs. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Escalation query: returns escalated and needs_clarification loops in FIFO order. |
| Unit | Feedback action: loop transitions to `running_maker`, feedback is included in next attempt payload. |
| Unit | Skip action: loop status -> skipped, downstream loops unblocked with degraded flag. |
| Unit | Rubric edit: loop's rubric field is updated. |
| Unit | Manually resolve action: loop transitions to `passed` (manual override), downstream loops unblocked. |
| Integration (LiveView) | Monitor view shows escalation. Resolve one, next appears. Badge count updates. |

---

## Slice 15: Circuit Breaker

### Verification Criteria (from slices doc)

1. After N consecutive escalations (configurable, default 3), circuit breaker transitions to `open`.
2. When circuit breaker is open, the Scheduler does not dispatch new loops.
3. In-flight loops continue to completion when the breaker is open.
4. Manual resume transitions breaker to `half_open` and dispatches one test loop.
5. If the test loop passes, breaker closes. If it escalates, breaker reopens.
6. Circuit breaker state is visible in the Monitor view with correct color coding.
7. Circuit breaker state updates in real time via PubSub.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S15-Q1 | `Algedonia.CircuitBreaker` GenServer stores state as `%{state: :closed | :open | :half_open, consecutive_escalations: integer, threshold: integer}`. |
| S15-Q2 | Threshold N is configurable via application config, not hardcoded. |
| S15-Q3 | State transitions are persisted to the `events` table (entity_type: `circuit_breaker`). |
| S15-Q4 | On server restart, CircuitBreaker reconstructs its state from the latest `circuit_breaker` event. |
| S15-Q5 | The Scheduler checks circuit breaker state before dispatching: `CircuitBreaker.allow_dispatch?/0`. |
| S15-Q6 | In `half_open`, only one loop is dispatched. Subsequent scheduling passes wait for that loop's result. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | CircuitBreaker: N escalations -> open. Manual resume -> half_open. Test loop pass -> closed. Test loop escalate -> open. |
| Unit | Scheduler integration: verify dispatch is blocked when breaker is open, allowed in half_open (one only), allowed in closed. |
| Unit | Crash recovery: kill CircuitBreaker, restart, verify state from events table. |
| Integration (LiveView) | Monitor view shows breaker state with color coding. Resume button works. Real-time updates. |

---

## Slice 16: Manual Gate and Approval

### Verification Criteria (from slices doc)

1. User can edit a loop's rubric from the Loop Inspector; changes persist.
2. Setting `manual_gate: true` in the rubric causes a passing loop to enter `pending_approval` instead of auto-merging.
3. The Loop Inspector shows "Approve" and "Reject" buttons for loops in `pending_approval`.
4. Clicking "Approve" triggers the squash-merge flow.
5. Clicking "Reject" with feedback sends the loop back to `running_maker` with that feedback.
6. The DAG view shows `pending_approval` (teal) as a distinct status.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S16-Q1 | Rubric editor is a Markdown textarea with syntax highlighting (or at minimum, a monospace font). |
| S16-Q2 | Rubric edits are validated: the rubric must contain the required sections (Hard Gates, Threshold at minimum). |
| S16-Q3 | Rubric edits apply to the NEXT attempt, not the current running one. The UI communicates this clearly (e.g., "Changes take effect on next attempt"). |
| S16-Q4 | `pending_approval` loops appear in the escalation queue alongside escalated loops (but are visually distinct — teal badge). |
| S16-Q5 | Approve and Reject create events in the `events` table (event_type: `approved` or `rejected`). |
| S16-Q6 | Reject requires non-empty feedback text. The UI validates this before submission. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Orchestrator: checker pass with `manual_gate: true` -> `pending_approval`. Approve -> squash merge. Reject -> `running_maker` with feedback. |
| Unit | Rubric update: changeset validates required sections. |
| Integration (LiveView) | Edit rubric in Loop Inspector, verify persistence. Toggle manual_gate, verify pending_approval on next pass. Approve and reject buttons work. |

---

## Slice 17: Focus Mode

### Verification Criteria (from slices doc)

1. User can toggle focus mode on and off from the Monitor view.
2. When focus mode is active, only the current escalation is visible; all other Monitor sections are hidden.
3. Resolving an escalation in focus mode automatically shows the next escalation in the queue.
4. When the last escalation is resolved, focus mode exits and the full Monitor view is restored.
5. Focus mode state persists across page reloads (stored in browser session or local storage).

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S17-Q1 | Focus mode is a LiveView assign (`@focus_mode`), toggled via a `handle_event`. No separate LiveView or route. |
| S17-Q2 | Focus mode hides sections with CSS/conditional rendering, not by removing them from the socket (so state is preserved when exiting focus mode). |
| S17-Q3 | Focus mode persistence uses a JavaScript hook that reads/writes `localStorage`. |
| S17-Q4 | Keyboard shortcut for focus mode toggle (e.g., `Escape` to exit focus mode, `Shift+F` to enter) via a `phx-window-keydown` binding. Do not use `Ctrl+F` (conflicts with browser Find). |
| S17-Q5 | Focus mode is a pure UI concern. No server-side state changes. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Integration (LiveView) | Toggle focus mode, verify only escalation is visible. Resolve escalation, next appears. Last resolved, focus mode exits. |
| Unit (JS) | localStorage persistence: set focus mode, reload, verify state restored. |

---

## Slice 18: Reflection and Knowledge

### Verification Criteria (from slices doc)

1. After a loop passes, the server triggers a reflection step.
2. The reflection agent runs and produces structured output.
3. The reflection is appended to `.algedonia/knowledge.md` with a timestamp and loop ID tag.
4. The knowledge file follows SDD Section 10.3 structure: Architecture Patterns, Gotchas, Useful Commands, and Rubric Notes sections.
5. Future `start_loop` commands include the updated knowledge context.
6. If the reflection agent fails 3 times, the failure is logged and skipped without affecting the passed loop.
7. The knowledge file is committed to the repo and visible in version control.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S18-Q1 | Reflection is triggered AFTER `squash_and_push` succeeds (the loop's work is already merged). Reflection failure must never block or revert a passed loop. |
| S18-Q2 | Reflection runs with role `reflect` (as specified in SDD). |
| S18-Q3 | The daemon commits the knowledge file update directly to the main branch (separate from the loop's branch). |
| S18-Q4 | Knowledge file entries are appended, not overwritten. Each entry is tagged with the loop ID and timestamp. |
| S18-Q5 | The server reads `.algedonia/knowledge.md` at `start_loop` time (not cached indefinitely). |
| S18-Q6 | Reflection retry uses exponential backoff: 1s, 2s, 4s. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Elixir) | Orchestrator triggers reflection after loop passes. Reflection failure is logged and skipped (loop stays passed). |
| Unit (Go) | Reflect role handler: spawns agent, parses structured output, commits to knowledge file. |
| Unit (Go) | Knowledge file append: verify existing content is preserved, new entry is appended with correct tags. |
| Integration | Full flow: loop passes -> reflection runs -> knowledge file updated -> next loop receives updated context. |

---

## Slice 19: Agent Adapter Extensibility (Codex)

### Verification Criteria (from slices doc)

1. Codex adapter implements all six methods of the agent adapter interface.
2. Server can send a `start_loop` command with `agent.type: "codex"`.
3. Daemon dispatches to the Codex adapter and spawns the Codex agent process.
4. Terminal output from Codex streams to the server via PTY, same as Claude Code.
5. A loop configured to use Codex completes and returns results to the server.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S19-Q1 | Codex adapter is in its own file (e.g., `adapter_codex.go`). |
| S19-Q2 | Agent adapter selection is a factory function or map lookup keyed by `agent.type` string. Adding a new adapter requires only: new file + register in the lookup. No switch statement in the main flow. |
| S19-Q3 | Claude Code and Codex adapters share no code duplication. Common logic (PTY attachment, wait, kill) lives in a base or helper module. |
| S19-Q4 | The server-side `start_loop` payload validation accepts `"codex"` as a valid `agent.type`. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit (Go) | Codex adapter implements all six interface methods (compile-time check via interface assignment). |
| Unit (Go) | Adapter factory: `"claude_code"` -> Claude adapter, `"codex"` -> Codex adapter, unknown -> error. |
| Integration | `start_loop` with `agent.type: "codex"` -> Codex spawns -> output streams -> result returned. (Can use a mock Codex binary.) |

---

## Slice 20: Multi-Daemon Scheduling

### Verification Criteria (from slices doc)

1. With two daemons connected, loops are assigned to the daemon with more available capacity.
2. The ticket creator's daemon is preferred when it has capacity.
3. Monitor view shows daemon assignment per running loop.
4. If a daemon goes offline, its pending loops are reassigned to another daemon after 5 minutes.
5. In-progress loops on an offline daemon are not immediately killed; they wait for reconnection.

### Additional Quality Criteria

| # | Criterion |
|---|-----------|
| S20-Q1 | Scheduler daemon selection: (1) ticket creator's daemon if online + capacity > 0, (2) least-loaded online daemon. Tie-breaking is deterministic (e.g., alphabetical by daemon name). |
| S20-Q2 | Reassignment after offline (5 minutes) only applies to loops in `assigned` or `ready` status — never to `running_maker` or `running_checker`. |
| S20-Q3 | The Monitor running loops table is sortable by daemon name. |
| S20-Q4 | Daemon capacity is respected: never assign more loops than `daemon.capacity`. |
| S20-Q5 | When a daemon reconnects, its in-progress loops resume (they were still running locally). The server updates the daemon status and resumes terminal streaming. |

### Required Tests

| Test Type | What to Test |
|-----------|-------------|
| Unit | Scheduler: two daemons, verify loop goes to creator's daemon first. Creator at capacity, verify fallback to least-loaded. Both at capacity, loop stays in `ready`. |
| Unit | Reassignment: daemon offline for 5 min, pending loops reassigned. In-progress loops not reassigned. |
| Unit | Capacity enforcement: daemon at max, no new loops assigned. |
| Integration (LiveView) | Monitor view shows daemon column per running loop. Sorting by daemon works. |
| Integration | Two daemon channels connected, verify scheduling distributes loops. |

---

# Part 3: UX & Design Rubrics

---

## Performance

| # | Criterion |
|---|-----------|
| UX1 | Every interaction responds in ≤100ms. If backend work takes longer, show skeleton loading states immediately and resolve in place. |

## Onboarding

| # | Criterion |
|---|-----------|
| UX2 | No product tours, no modals on first visit, no coach marks. The UI is self-evident or it's broken. |

## Navigation & URLs

| # | Criterion |
|---|-----------|
| UX3 | URL slugs are short, human-readable, no UUIDs. Use short slugs or nanoids if needed. |
| UX4 | All navigation is reachable in ≤3 steps from anywhere. |
| UX5 | `Cmd+K` command palette is available globally. |

## State

| # | Criterion |
|---|-----------|
| UX6 | All state is persistent and resumable. Closing the browser and reopening lands you exactly where you left off. |
| UX7 | Reassure users about data loss — confirm destructive actions, show save status, surface undo when possible. |

## Visual Design

| # | Criterion |
|---|-----------|
| UX8 | Not more than 3 colors (plus neutral grays). One primary, one accent, one semantic (error/warning). |
| UX9 | No visible scrollbars. Use `overflow: auto` with hidden scrollbar styling. |
| UX10 | Optical alignment over geometric alignment. Elements should look aligned, not just be mathematically aligned. |
| UX11 | Layout optimized for left-to-right reading flow. Primary content and actions on the left, secondary on the right. |
| UX12 | Skeleton loading states for all async content. No spinners, no blank screens. |

## Interaction

| # | Criterion |
|---|-----------|
| UX13 | Larger hit targets — buttons ≥44px, inputs ≥40px height. Touch-friendly even on desktop. |
| UX14 | Honest one-click cancel. Cancellation is immediate, never "are you sure?" unless data loss is involved. |
| UX15 | Copy/paste from clipboard works everywhere text is displayed. No un-selectable text. |

## Brand

| # | Criterion |
|---|-----------|
| UX16 | Copyable SVG logo + brand kit available as a static asset. |

## Copy & Tooltips

| # | Criterion |
|---|-----------|
| UX17 | All UI copy is active voice, max 7 words per sentence. |
| UX18 | Tooltips are minimal — only on icons without labels. Never on buttons with text. |
