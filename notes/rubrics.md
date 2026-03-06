# Algedonia -- Quality Rubrics

Reference: [PRD v5](prd.md), [SDD v4](sdd.md), [Tickets](tickets.md)

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
| ET1 | Context modules (`Algedonia.Tickets`, `Algedonia.Loops`, `Algedonia.Workspaces`, etc.) are the seam for testing. LiveViews and GenServers call context functions, not Repo directly. |
| ET2 | Side effects are injected via configuration or passed as arguments (e.g., passing a `notify_fn` instead of hardcoding `PubSub.broadcast`). |
| ET3 | Use `Mox` for behavior-based mocks. Define behaviours for external boundaries (daemon communication, PubSub, tracker API). |
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
| ED2 | `TODO` or `FIXME` comments without a linked ticket number. |
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
| LV5 | Every LiveView subscribes to workspace-scoped PubSub topics (e.g., `workspace:{id}:loop:{loop_id}`) in `mount/3`. Topic must include `workspace_id`. |
| LV6 | HEEx templates are in separate `.heex` files, not inline `~H` sigils, when they exceed ~30 lines. |
| LV7 | No raw HTML strings. Use HEEx components and function components exclusively. |
| LV8 | Form changesets are validated client-side via `phx-change` before submission. |
| LV9 | No diff or code display — server never sees code. Show verdicts, summaries, and file paths only. Scrollback is streamed live from the daemon for detail. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| LVI1 | Use `assign_new/3` for expensive computations that shouldn't re-run on every mount. | Re-fetching data in `mount` that was already available. |
| LVI2 | Use `streams` for lists of items (tickets, loops, queue entries) to minimize DOM patching. Board/list views update incrementally via PubSub — insert/update the changed item in the stream, never re-fetch the full list. | Assigning full lists, re-rendering entire lists on every change, or re-querying all items after a single-item update. |
| LVI3 | Use `push_event/3` for JavaScript interop (terminal widget). | Direct JavaScript calls via inline `<script>` tags. |
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
| LVC1 | Every user-facing interaction from the tickets verification criteria has a corresponding LiveView integration test. |
| LVC2 | Real-time update paths (PubSub -> LiveView -> DOM change) have at least one test per workspace-scoped PubSub topic. |
| LVC3 | Navigation between views (`/queue` -> `/loops/:id` -> `/monitor`) is tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| LVD1 | `assigns` contains data only used by a child component (should be passed as props or fetched by the child). |
| LVD2 | Multiple LiveViews duplicating the same PubSub subscription and handling logic (extract to a shared hook module). |
| LVD3 | JavaScript hooks that grow significantly beyond ~50 lines without extraction into a separate JS module. |
| LVD4 | Synchronous database queries in `handle_event` that could cause UI lag. Use `assign_async` or `start_async` for queries over 100ms. |
| LVD5 | LiveView subscribing to a non-workspace-scoped PubSub topic (missing workspace isolation). |

---

## Phoenix Channels (Real-Time Communication)

### Quality

| # | Criterion |
|---|-----------|
| CH1 | Each channel module handles one topic pattern. `DaemonChannel` handles `daemon:*`. No god-channels. |
| CH2 | `handle_in/3` callbacks validate incoming payloads and return `{:reply, {:error, reason}, socket}` on invalid input. Never silently drop malformed messages. |
| CH3 | Channel authentication happens in `join/3`. An invalid user token returns `{:error, %{reason: "unauthorized"}}`. Server resolves workspace membership from the authenticated user. |
| CH4 | Binary data (terminal output) uses the channel's binary encoding. Do not Base64-encode binary payloads as JSON strings. |
| CH5 | Channel modules should be <=150 lines (soft gate — a few lines over is acceptable if the code is succinct). Delegate business logic to context modules or the LoopEngine. |

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
| CHT2 | Authentication rejection is tested: invalid user token -> join fails. |
| CHT3 | Each command type (`run_maker`, `run_checker_step`, `land`, `stop_loop`, `pause_agent`, `resume_agent`, `stdin_input`) has a test that pushes the command and asserts the expected reply or broadcast. |

### Test Coverage

| # | Criterion |
|---|-----------|
| CHC1 | Every server->daemon command from the protocol spec has a channel test. |
| CHC2 | Every daemon->server event from the protocol spec has a channel test. |
| CHC3 | Error cases (malformed payloads, unknown loop IDs, daemon at capacity, workspace membership check failure) are tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| CHD1 | Channel callbacks containing database queries or complex logic instead of delegating to context modules. |
| CHD2 | Hardcoded topic strings scattered across the codebase instead of using a topic-builder function (e.g., `Topics.daemon(id)`). |
| CHD3 | Missing rate limiting on `terminal_output` or `stdin_input` events. |
| CHD4 | Channel accepting commands for workspaces the daemon's user is not a member of. |

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
| EQ8 | All tenant-scoped queries include `WHERE workspace_id = ?`. No unscoped queries on workspace-owned tables. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| ECI1 | Use `Ecto.Multi` for operations that must be atomic (e.g., creating a loop + queue entry + event). | Multiple sequential `Repo.insert` calls without a transaction. |
| ECI2 | Use `Repo.preload` explicitly in the listing query. Never use `has_many` with eager loading by default. N+1 is a hard fail — no per-item queries inside an `Enum.map` or comprehension. | Loading a list then preloading or querying associations in a loop. |
| ECI3 | Use `Ecto.Enum` for status fields (`status: Ecto.Enum, values: [:backlog, :in_progress, ...]`). | String-typed status fields with ad-hoc validation. |
| ECI4 | Use upserts (`on_conflict`) for daemon heartbeat updates instead of select-then-update. | Separate SELECT + UPDATE for heartbeat writes (race condition risk). |
| ECI5 | Cast and validate all external input through changesets, even for internal API boundaries. | Passing raw maps to `Repo.insert` without changeset validation. |
| ECI6 | Scope all context function queries by `workspace_id` as the first filter. | Querying by entity ID alone without workspace scoping (breaks tenant isolation). |

### Testability

| # | Criterion |
|---|-----------|
| ECT1 | Use `Ecto.Adapters.SQL.Sandbox` in test mode. Every test runs in a transaction that rolls back. |
| ECT2 | Factory module (e.g., `Algedonia.Factory` or ExMachina) provides builders for every schema including `workspace` and `user`. |
| ECT3 | Context function tests use the factory, not raw SQL. |
| ECT4 | Migration tests: run `mix ecto.migrate` and `mix ecto.rollback` as part of CI. |

### Test Coverage

| # | Criterion |
|---|-----------|
| ECC1 | Every changeset function: one test per validation rule, one test with valid input. |
| ECC2 | Every context function: happy path + at least one error path. |
| ECC3 | Queries that filter by status, priority, or workspace_id have tests verifying correct filtering. |
| ECC4 | `Ecto.Multi` operations are tested for both full success and partial failure (rollback). |
| ECC5 | Workspace isolation tests: verify that querying workspace A's data with workspace B's scope returns nothing. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| ECD1 | Raw SQL queries (`Repo.query`) when Ecto's query DSL can express the same thing. Exception: complex CTEs or window functions. |
| ECD2 | Schemas with fields not in the SDD data model (schema drift). |
| ECD3 | Missing indexes on columns used in WHERE clauses or JOINs. |
| ECD4 | Changesets that `cast` all fields including those that should be server-controlled (e.g., `inserted_at`). |
| ECD5 | Context modules significantly over ~300 lines. Split by entity (e.g., `Tickets`, `Loops`, `Workspaces`). |
| ECD6 | Missing `workspace_id` scoping on a tenant-owned table query. |

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
| GS6 | State recovery: on startup, GenServers for `CircuitBreaker`, `QueueManager`, and `LoopEngine` reload state from PostgreSQL. |
| GS7 | Supervision tree is documented: which supervisor owns which children, restart strategy (`:one_for_one` vs `:rest_for_one`). |
| GS8 | GenServer modules should be <=200 lines (soft gate — a few lines over is acceptable if the code is succinct). Extract helper functions into a companion module. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| GSI1 | Use `GenServer.call/3` with an explicit timeout for operations that must respond. | Infinite timeouts on calls that hit the database. Default timeout: 5_000ms. |
| GSI2 | Use `handle_continue/2` for post-init work. | Blocking `init/1` with database queries or network calls. |
| GSI3 | Persist state changes to PostgreSQL before responding to the caller (write-ahead). | Responding to calls with in-memory state that hasn't been persisted (crash loses data). |
| GSI4 | Use `Process.send_after/3` for periodic tasks (daemon health checks, tracker polling). | `:timer.send_interval` (harder to cancel and test). |
| GSI5 | Use `Registry` or `:via` tuples for process lookup when there may be multiple instances (e.g., per-workspace GenServers). | Hardcoded atom names for processes that could be parameterized. |

### Testability

| # | Criterion |
|---|-----------|
| GST1 | GenServers can be started in tests with `start_supervised/2` and a test-specific name to avoid global state leaks. |
| GST2 | Time-dependent behavior (heartbeat timeouts, circuit breaker thresholds, tracker poll intervals) is configurable, not hardcoded. Tests pass short intervals. |
| GST3 | The public API of a GenServer (the client functions like `QueueManager.enqueue/2`) is the test surface, not the internal callbacks. |
| GST4 | Crash recovery is tested: kill the GenServer, restart it, verify state is reconstructed from the database. |

### Test Coverage

| # | Criterion |
|---|-----------|
| GSC1 | `Algedonia.LoopEngine`: test every loop state transition from SDD loop state machine (idle -> running -> passed/review_gate/escalated/tapered, landing transient state, CI failure retry). |
| GSC2 | `Algedonia.QueueManager`: test dispatch logic (play/pause, concurrency limits, dependency-aware skip, blocker re-evaluation), daemon routing (scored selection with eligibility filter). |
| GSC3 | `Algedonia.CircuitBreaker`: test all state transitions (closed->open, open->half_open, half_open->closed, half_open->open). |
| GSC4 | `Algedonia.DaemonMonitor`: test healthy->unhealthy->offline transitions at correct time thresholds. |
| GSC5 | `Algedonia.TrackerSync`: test poll cycle (upsert, planning trigger, auto-enqueue, reconcile terminal tickets). |

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
| GOC2 | Every command handler (`run_maker`, `run_checker_step`, `land`, `stop_loop`, `pause_agent`, `resume_agent`, `stdin_input`) has unit tests. |
| GOC3 | Error paths (agent crash, push failure, CI failure) have tests. |
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
| WSC1 | Connection establishment and authentication (user token) tested. |
| WSC2 | Reconnection after disconnect tested (verify backoff behavior). |
| WSC3 | Every command from the protocol spec (server->daemon) is tested: message is deserialized and dispatched correctly. |
| WSC4 | Every event from the protocol spec (daemon->server) is tested: message is serialized and sent correctly. |
| WSC5 | Buffer overflow during disconnection is tested. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| WSD1 | Hardcoded server URL or user token instead of configuration. |
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
| GIT3 | Bare clone layout: `<baseDir>/<slug>/root/` for the bare repo. Worktrees at `<workspaceDir>/worktrees/<ticketPrefix>/`. |
| GIT4 | `EnsureRepo` does `git clone --bare` on first use, `git fetch --all` on subsequent. Near-instant worktree creation via `git worktree add --detach`. |

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
| GITC1 | Bare repo clone tested (`git clone --bare`). |
| GITC2 | Fetch on existing bare repo tested (`git fetch --all`). |
| GITC3 | Worktree creation and cleanup tested. |
| GITC4 | Squash-rebase onto base branch tested (verify single commit on base branch after squash). |
| GITC5 | Push success and push failure (e.g., conflicting remote changes) tested. |
| GITC6 | Landing sequence tested: squash, push, PR create (`gh pr create`), CI poll (`gh pr checks`), merge (`gh pr merge`). |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| GITD1 | Hardcoded branch naming conventions instead of using the server-provided `branch_name`. |
| GITD2 | No timeout on git operations (a slow network can hang the daemon). All git operations should have a context timeout of 120s max. |
| GITD3 | Stale worktrees not cleaned up after loop completion. |

---

## PostgreSQL Schema (Data Model)

### Quality

| # | Criterion |
|---|-----------|
| PG1 | Every table has a primary key. UUIDs for application tables, `bigserial` only for the `events` table (as specified in SDD). |
| PG2 | Every foreign key has a corresponding index. |
| PG3 | `NOT NULL` constraints on every column specified as "Not null" in SDD Section 9. |
| PG4 | Status columns use `CHECK` constraints to enforce valid values (e.g., `CHECK (status IN ('backlog', 'planning', 'todo', ...))`). |
| PG5 | `timestamptz` (not `timestamp`) for all time columns. |
| PG6 | The `events` table is append-only. No UPDATE or DELETE operations. Enforce via application code. |
| PG7 | All tenant-scoped tables have a `workspace_id` FK with index. |
| PG8 | RLS policies exist on all tenant-scoped tables: `USING (workspace_id = current_setting('app.workspace_id')::uuid)`. |
| PG9 | Unique constraints: `workspace_memberships(workspace_id, user_id)`, `workspaces.slug`, `tickets(workspace_id, external_id)`. |

### Idioms

| # | Follow | Avoid |
|---|--------|-------|
| PGI1 | Use database-level constraints (NOT NULL, CHECK, UNIQUE, FK) as the last line of defense. Ecto validates first, but the DB catches what Ecto misses. | Relying solely on application-level validation. |
| PGI2 | Use `jsonb` (not `json`) for all JSON columns (`checker_config`, `tracker_config`, `token_usage`, etc.). It supports indexing and comparison. | `json` type, which stores as text and doesn't support efficient querying. |
| PGI3 | Name indexes explicitly following the pattern `idx_{table}_{columns}`. | Default auto-generated index names that are hard to reference in discussions. |

### Testability

| # | Criterion |
|---|-----------|
| PGT1 | Migrations can be run forward and backward (`mix ecto.migrate` + `mix ecto.rollback`) without data loss in test fixtures. |
| PGT2 | Constraint violations (unique, FK, check, RLS) are tested by attempting the violating operation and asserting the error. |

### Test Coverage

| # | Criterion |
|---|-----------|
| PGC1 | Every migration is covered by the rollback test (see PGT1). |
| PGC2 | RLS policies tested: set `app.workspace_id` to workspace A, verify workspace B data is invisible. |
| PGC3 | Foreign key cascade behavior is tested (e.g., deleting a workspace cascades to memberships). |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| PGD1 | Tables or columns that exist in the database but not in SDD Section 9 (schema drift). |
| PGD2 | Missing indexes on columns used in WHERE or JOIN clauses. |
| PGD3 | `text` columns storing structured data that should be `jsonb` or a separate table. |
| PGD4 | Migrations that modify data in-place without a reversible strategy. |
| PGD5 | Tenant-scoped table missing RLS policy. |

---

## Server-Daemon Protocol (Interface Contract)

### Quality

| # | Criterion |
|---|-----------|
| PR1 | Message schemas are defined once and shared: a schema file or module on each side (Elixir struct/map spec on server, Go struct with JSON tags on daemon). |
| PR2 | Every message includes `loop_id` for traceability (except `heartbeat` and connection-level messages). |
| PR3 | Every command from server has an acknowledged reply or error from the daemon. No fire-and-forget commands. |
| PR4 | Unknown message types are logged and ignored, not crashed on. Forward-compatible. |
| PR5 | Message payloads match the protocol spec exactly. No extra fields, no missing fields, no renamed fields. |
| PR6 | Binary data (`terminal_output.data`) is sent as binary frames, not Base64-encoded JSON strings. |
| PR7 | Timestamps use Unix milliseconds (integer), not formatted strings. |
| PR8 | `maker_result` sends only `exit_code`, `files_changed` (paths), `duration_ms`, `token_usage`. No diffs, no raw output. Server never sees code. |
| PR9 | `step_result` sends `skill_name`, `passed`, `summary` (structured text), `duration_ms`. No raw output or artifacts. |
| PR10 | `land_result` sends `status` (landed/ci_failed/review_gate), `pr_url`, `merge_sha` (if landed), `ci_output` (if failed). |

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
| PRT3 | End-to-end integration test: real server + real daemon (no mocks) for at least one full flow (connect -> run_maker -> maker_result -> run_checker_step -> step_result -> land -> land_result). |

### Test Coverage

| # | Criterion |
|---|-----------|
| PRC1 | Every command type has a round-trip test. |
| PRC2 | Every event type has a round-trip test. |
| PRC3 | Protocol version mismatch is tested: server rejects daemon with wrong version. |
| PRC4 | No-code invariant: verify `maker_result` never contains file contents or diffs. |
| PRC5 | `land` command round-trip tested: land -> land_result with CI pass, CI fail, and review_gate outcomes. |

### Tech Debt / Code Smells

| # | Smell |
|---|-------|
| PRD1 | Server and daemon have divergent message schemas (different field names, types, or structures). |
| PRD2 | Hardcoded message type strings instead of constants/enums on both sides. |
| PRD3 | No timeout on expecting a reply from the daemon after sending a command. |
| PRD4 | Terminal output events without timestamps (makes latency measurement impossible). |
| PRD5 | Any code or file contents leaking into server-bound protocol messages. |

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
| P3 | Isolation invariants specification | When adding a new variant to a type used for dispatch (e.g., loop status, ticket status), the plan must state the isolation invariant: which code paths handle the new variant, and which existing paths must exclude it. Fail if the invariant is not stated or if existing paths are not explicitly addressed. |

### Cross-Cutting Query Audit

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P4 | Cross-cutting query audit for new enum variants | When adding a new enum variant, every query that filters or groups by the enum field must be listed in the plan with a disposition: "needs update", "safe as-is" (with reason), or "new query". Fail if any query is unlisted. Search patterns to use: the field name (e.g., `status`), query function names, and enum values in the same field. |

### Interaction Tests

| # | Criterion | Pass/Fail Rule |
|---|-----------|---------------|
| P5 | Interaction test requirements for shared data models | When a new variant coexists with existing variants in the same table/collection, the plan must require interaction tests: scenarios where both old and new variants are present and existing logic produces correct results. Fail if interaction tests are not listed as deliverables. |

---

# Part 2: Per-Phase Verification Criteria

Reference: [Tickets](tickets.md) for detailed ticket descriptions.

---

## Phase 0: Clean Up — Remove v4 Primitives

### Verification Criteria

| # | Criterion |
|---|-----------|
| P0-1 | DAG machinery fully removed: `DecomposeOrchestrator`, `Algedonia.Dags` context, `dags` schema, `loop_dependencies` schema, `DagLive.Show`, DAG tree panel, decompose/impact_analysis prompts, related daemon channel handling. |
| P0-2 | File-level locking fully removed: `file_locks` table, `LockManager` GenServer, lock acquire/release in scheduler. |
| P0-3 | Loop schema migrated: `dag_id`, `role`, `path_prefixes`, `rubric` columns removed. `checker_config` (jsonb), `land_mode` (text), `pr_url` (text) added. Status enum matches v5: `running`, `tapered`, `review_gate`, `landing`. |
| P0-4 | "Start Work" button and decomposition trigger removed. Full ticket CRUD retained — create, edit, status transitions all sync bidirectionally with tracker. Board view with drag-to-change-status. Detail panel with editable fields (title, description, acceptance_criteria) and inline comments. Board uses `stream` for incremental updates — no full list re-fetches on change. Zero N+1 queries: ticket lists loaded with preloads in a single query, not per-ticket fetches. |
| P0-5 | All removed code paths have zero references in remaining codebase (verified by grep). |
| P0-6 | All existing tests pass after cleanup (`mix test`, `go test ./...`). |

---

## Phase 1: Multi-Tenancy and Data Model

### Verification Criteria

| # | Criterion |
|---|-----------|
| P1-1 | `users` table exists with `github_id` (unique), `github_username`, `name`, `email`, `avatar_url`. GitHub OAuth creates/updates user records. |
| P1-2 | `workspaces` table exists with `name`, `slug` (unique), `github_repo_url`, `tracker_config`, `playback_config`, `defaults`, `planning_mode`. |
| P1-3 | `workspace_memberships` table with unique constraint on `(workspace_id, user_id)` and `role` (owner/member). |
| P1-4 | All tenant-scoped tables (`tickets`, `loops`, `queue_entries`, `events`) have `workspace_id` FK with index. |
| P1-5 | Postgres RLS policies active on all tenant-scoped tables. Verified with a test that sets `app.workspace_id` to one workspace and proves data from another is invisible. |
| P1-6 | All context module queries scope by `workspace_id`. No unscoped tenant queries. |
| P1-7 | `daemon_registrations` has `user_id` (not `workspace_id`), `available_agents` (text[]), `bare_repos` (text[]). Daemon authenticates with user token. |
| P1-8 | All PubSub topics include workspace_id: `workspace:{id}:loop:{loop_id}`, `workspace:{id}:queue`, `workspace:{id}:monitor`. |
| P1-9 | `tickets` schema updated: `external_id`, `identifier`, `labels`, `tracker_url`, `synced_at`, `blocked_by`, `proposed_checker_config`, `approved_checker_config` added. |
| P1-10 | `loop_iterations` table: `loop_id`, `iteration_number`, `maker_duration_ms`, `maker_token_usage`, `verdict`, `human_feedback`. No diffs, no raw output. |
| P1-11 | `checker_step_results` table: `loop_iteration_id`, `step_index`, `skill_name`, `passed`, `summary`, `duration_ms`. No raw output or artifacts. |

---

## Phase 2: Skills and Planning

### Verification Criteria

| # | Criterion |
|---|-----------|
| P2-1 | Skills are discovered from `.algedonia/skills/*.md` in the repo. Markdown with YAML frontmatter parsed into `%Skill{name, type, config}`. Types: `command`, `browser`, `agent_review`. |
| P2-2 | Daemon resolves skill config from repo's `.algedonia/skills/` on `run_checker_step`, merges with per-ticket params from command payload. |
| P2-3 | Planning agent dispatches when ticket enters planning state. Evaluates clarity, composes checker config, stores as `approved_checker_config` (clear) or `proposed_checker_config` (ambiguous). |
| P2-4 | Planning mode (auto/always_approve/always_review) is a workspace-level setting, not a config file toggle. |
| P2-5 | Base pipeline skills from `defaults.base_pipeline` are prepended to every loop's checker config regardless of planning output. |

---

## Phase 3: Loop Engine

### Verification Criteria

| # | Criterion |
|---|-----------|
| P3-1 | `run_checker_step` pushes skill-based commands to daemon. Payload: `loop_id`, `workspace_slug`, `iteration_number`, `step_index`, `skill` (name, type, config, params). |
| P3-2 | `maker_result` contains only `exit_code`, `files_changed` (paths), `duration_ms`, `token_usage`. No diffs. |
| P3-3 | `LoopEngine` executes checker steps sequentially: step 0 -> step N. Fail-fast on first failure. |
| P3-4 | On iteration pass: check `land_mode` -> dispatch `land` command or move to `passed`. |
| P3-5 | On iteration fail: increment iteration, assemble feedback from failing step summary, dispatch next maker. |
| P3-6 | On max iterations: loop -> `escalated`. |
| P3-7 | Taper detection: same step fails with same summary hash for N consecutive iterations -> `tapered`. |
| P3-8 | `landing` is a transient state between running and passed/review_gate. |

---

## Phase 4: Queue, Playback, and Routing

### Verification Criteria

| # | Criterion |
|---|-----------|
| P4-1 | `queue_entries` table: `workspace_id`, `ticket_id` (unique), `position`, `status`, `land_mode`, `pinned`. |
| P4-2 | `QueueManager` respects play/pause per workspace, concurrency limits, dependency-aware dispatch (skip blocked tickets). |
| P4-3 | Effective concurrency = `min(configured, total_daemon_capacity - total_running_loops)`. UI shows both configured and effective. |
| P4-4 | Daemon routing: eligibility filter (online, workspace member, capacity, agent type) + scoring (bare repo locality +3, capacity +2, recency +1). Ties broken by daemon name. |
| P4-5 | Blocker re-evaluation: when a loop lands, tickets with completed blockers are re-evaluated for dispatch. |
| P4-6 | Queue UI: play/pause toggle, concurrency slider, drag-to-reorder, per-entry actions (pin, skip, pause, land mode), blocked badge. |
| P4-7 | `/queue` is the default landing page. |

---

## Phase 5: Tracker Sync (Linear)

### Verification Criteria

| # | Criterion |
|---|-----------|
| P5-1 | `Algedonia.Tracker` behaviour with `create_ticket/2`, `update_ticket/3`, `fetch_active_tickets/1`, `post_comment/3`, `attach_link/4`. Bidirectional: local creates/edits push to tracker, tracker changes pull in. |
| P5-2 | Linear client: GraphQL via `Req`, auth via `LINEAR_API_KEY`, pagination, `blocked_by` from relations. |
| P5-3 | `TrackerSync` polls on configurable interval. Upserts tickets, triggers planning for planning-state tickets, auto-enqueues active tickets if `auto_start: true`. |
| P5-4 | Outbound updates: loop dispatched -> "In Progress", review_gate -> "Ready for Review" + PR link, escalated -> comment with context. |

---

## Phase 6: Loop Viewer Refactor

### Verification Criteria

| # | Criterion |
|---|-----------|
| P6-1 | Left panel: flat list of loops for current ticket (replacing DAG tree). Status icon, iteration count, skill names. |
| P6-2 | Center panel: checker step-by-step verdicts (skill name, pass/fail, summary, duration). No diffs or raw output. Iteration history timeline. |
| P6-3 | Right panel (steer): feedback textarea, checker config viewer/editor, acceptance criteria (synced from ticket). |
| P6-4 | Taper indicator visible when taper detected. |

---

## Phase 7: Circuit Breaker and Escalation

### Verification Criteria

| # | Criterion |
|---|-----------|
| P7-1 | `CircuitBreaker` per workspace: closed -> open (N consecutive escalations) -> half_open (manual resume) -> closed/open. |
| P7-2 | When open, `QueueManager` stops dispatching. In-flight loops continue. |
| P7-3 | Escalation queue in Monitor: verdict history, failing step, human feedback trail. Actions: provide feedback, edit checker config, skip, resolve. |
| P7-4 | Daemon health section: each daemon shows owner (user name + avatar), capacity, status. Filtered to workspace members. |

---

## Phase 8: Landing (Daemon-Side)

### Verification Criteria

| # | Criterion |
|---|-----------|
| P8-1 | Server sends `land` command after all checker steps pass: `loop_id`, `land_mode`, `branch`, `base_branch`. |
| P8-2 | Daemon landing sequence: squash -> push -> `gh pr create` -> poll CI (`gh pr checks`, 30s interval, configurable timeout) -> send `land_result`. |
| P8-3 | `auto_land` + CI pass: daemon merges via `gh pr merge --squash`, reports `{status: "landed", merge_sha}`. Server marks loop `passed`. |
| P8-4 | CI failure: daemon reports `{status: "ci_failed", ci_output}`. Server treats as iteration failure, CI output becomes maker feedback. |
| P8-5 | `review_gate` + CI pass: daemon reports `{status: "review_gate", pr_url}`. Loop status: `review_gate`. |
| P8-6 | Review gate resolution: PR merged by human -> loop `passed`. PR closed with comments -> resume loop with review feedback. |

---

## Phase 9: Reflection and Process Improvement

### Verification Criteria

| # | Criterion |
|---|-----------|
| P9-1 | Reflection agent dispatches after loop lands, skips if first-iteration pass with no nudges. |
| P9-2 | Inputs: loop verdicts, human nudges, iteration count, checker config, `.algedonia/knowledge.md`, available skills. |
| P9-3 | Outputs: categorized items (`guideline`, `new_skill`, `skill_update`, `knowledge`, `recommendation`). Non-recommendation items become tracker tickets. |
| P9-4 | Nudge rate tracked per workspace: human_feedback count per loop, rolling 30-day trend. Surfaced in Monitor. |
| P9-5 | `.algedonia/knowledge.md` included in `run_maker` context. Updated knowledge from landed reflection tickets feeds future loops. |
| P9-6 | Reflection is non-critical: failure logged and skipped, never blocks the pipeline. |

---

## Phase 10: Advanced Checker Steps

### Verification Criteria

| # | Criterion |
|---|-----------|
| P10-1 | `browser` skill: boot app, wait for health endpoint, drive Playwright/CDP, capture screenshots/DOM (stay on daemon), report summary. |
| P10-2 | `agent_review` skill: spawn review agent with diff + skill prompt + criteria, capture structured verdict, report summary. |

---

## Phase 11: Configuration and Polish

### Verification Criteria

| # | Criterion |
|---|-----------|
| P11-1 | Workspace settings page: tracker connection, playback defaults, planning mode, base pipeline, max iterations. |
| P11-2 | `.algedonia/config.yml` parsed from repo as alternative to UI settings. File overrides where specified. Dynamic reload on change. |

---

## Phase 12: Open Source Daemon Prep

### Verification Criteria

| # | Criterion |
|---|-----------|
| P12-1 | Standalone protocol specification: all commands/events with payload schemas, auth flow, reconnection, heartbeat, version negotiation. |
| P12-2 | Trust contract verified: no file contents or code sent to server, no network requests except to server and agent LLM APIs, no file modifications outside worktree, no telemetry persistence. Integration tests for invariants. |
| P12-3 | Daemon extracted to standalone repo with README, LICENSE (Apache 2.0), CONTRIBUTING.md, CI pipeline. |
