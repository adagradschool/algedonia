# Codebase Knowledge

## Repository Path

The current repository root is `/Users/ada/fun/algedonia`. All relative paths in documentation and configuration are relative to this root.

## Architecture Patterns

### Browser auth via daemon (`ag connect` opens browser)
Users don't log in through a form. The daemon already has the project token from `ag login`, so `ag connect` opens the browser to `/auth?name=<name>&token=<token>`, which sets a session cookie with the display name. This means:
- No password/login UI needed — the daemon is the auth source
- Display name comes from the `--name` flag (or hostname fallback)
- The server validates the token with `Plug.Crypto.secure_compare/2` against `:project_token` config
- Protected routes use a `RequireDisplayName` plug that redirects unauthenticated browsers to "run `ag connect`"

### Presence tracking via `on_mount` hook
Cross-cutting concerns like presence use a `live_session` with `on_mount` hooks rather than duplicating logic in each LiveView. The hook:
- Subscribes to a topic derived from `socket.view` (e.g., `"presence:tickets"`)
- Uses `attach_hook(:presence_diff, :handle_info, ...)` to intercept broadcasts before they reach the LiveView
- Assigns `:display_name`, `:presences`, `:presence_topic` — LiveViews just render them

### Test session defaults in `conn_case.ex`
When adding plugs/hooks that gate on session values, update `conn_case.ex` setup to include defaults (e.g., `display_name: "TestUser"`) so existing tests don't break. Tests that need the "missing session" path must use a fresh `build_conn()`.

### Terminal streaming pipeline (Slice 5)
The full terminal streaming path is: daemon PTY -> output chunker -> Phoenix channel -> server TerminalBuffer GenServer -> PubSub -> LiveView -> xterm.js hook. Key design decisions:
- **Output chunker** flushes on 50ms timer or 4KB buffer, whichever comes first. UTF-8 safe boundary splitting required (see gotcha below).
- **TerminalBuffer** is a per-loop GenServer under a DynamicSupervisor, registered via Registry by loop_id. Use `restart: :temporary` — these are ephemeral processes that should not restart when stopped.
- **Channel handlers** for `terminal_output` and `loop_exited` bridge daemon events to the server's PubSub system.
- **xterm.js** is mounted as a Phoenix LiveView hook. The terminal div needs absolute positioning with concrete pixel dimensions at mount time — CSS flex/`h-full` alone is insufficient.

### Typing into TUI agents (Claude Code, Ink-based) (Slice 5)
Ink-based TUI agents (like Claude Code) do not read stdin as lines. They process terminal input events. To deliver a prompt:
1. Wait for the agent to be ready — use idle detection (PTY output goes quiet for 1.5s after a 2s minimum post-spawn delay).
2. Type characters one at a time with 5ms inter-character delays, simulating keyboard input.
3. Pause 300ms after the last character.
4. Send `\r` (carriage return), NOT `\n` (line feed). TUI terminals expect CR.
This mirrors how tmux `send-keys` works and is the same approach used by the `scope` tool.

### Monorepo path discipline — use `just` recipes (Slice 6)
Running `mix test`, `mix format`, `go vet`, etc. from the repo root fails silently or with confusing errors because those tools expect to be in `server/` or `daemon/` respectively. This happened repeatedly. Always use `just test`, `just lint`, `just format` (and their `-server`/`-daemon` variants) from the repo root. The justfile handles the `cd` automatically. If you must run a raw command, specify the full path: `cd server && mix test`, never just `mix test`.

### Base64 passthrough for stdin data (Slice 6)
User terminal input flows browser (xterm.js `onData` -> `btoa`) -> LiveView (`pushEvent`) -> server (`push_stdin_input`) -> daemon channel -> daemon (`base64.StdEncoding.DecodeString`). The server never decodes or re-encodes the base64 — it passes the string through as-is via `DaemonChannel.push_stdin_input/3`. Only the daemon decodes. This keeps the server simple and avoids double-encoding bugs. The same pattern applies in reverse for terminal output (daemon encodes, server decodes in `handle_in("terminal_output", ...)` for the TerminalBuffer, then re-encodes in the LiveView `push_event`).

### Agent adapter interface — shared PTY helpers (Slice 7)
The 6-method `AgentAdapter` interface works well for pluggable agents. Both Claude Code and Codex adapters share PTY lifecycle logic via helper functions (`allocatePTY`, `killProcess`, `waitProcess`), keeping each adapter file focused on CLI flag construction. Adding a new adapter is: one new file implementing the interface + one registry entry. No other code changes needed.

### `push_start_loop` opts pattern (Slice 7)
The `DaemonChannel.push_start_loop(daemon_name, loop_id, opts \\ %{})` with `Map.merge` makes it easy to pass through additional fields like `role` and `agent_type` without changing the channel code. New fields flow through automatically.

### LiveView query params need `handle_params/3` (Slice 7)
Phoenix LiveView's `mount/3` only receives path params from the router (e.g., `:loop_id`). Query params like `?role=maker&agent_type=codex` must be captured in `handle_params/3`, not `mount`. This is easy to miss because both callbacks receive the params map, but only `handle_params` includes query string parameters.

### Agent pause/resume is keyboard events, not signals (Slice 6)
Ink-based TUI agents (Claude Code, etc.) cannot be paused/resumed with SIGSTOP/SIGCONT. They are full-screen terminal applications that manage their own input loop. To pause or resume, send the appropriate keyboard sequences through the PTY (e.g., Escape `\x1b`, Shift+Tab `\x1b[Z`). Additionally, macOS has PTY + Setpgid conflicts (see existing gotcha) that make process group signals unreliable anyway.

### xterm.js `onData` captures all input including special keys (Slice 6)
The xterm.js `onData` callback receives raw terminal input including Escape (`\x1b`), Ctrl+C (`\x03`), Shift+Tab (`\x1b[Z`), and all other special key sequences. No special key handling or filtering is needed in the hook — raw passthrough via base64 to the daemon PTY works correctly for all inputs.

## Gotchas

### `attach_hook/4` is in `Phoenix.LiveView`, not `Phoenix.Component`
Easy to assume it's in `Phoenix.Component` since `assign/3` is there. Will get a compile error if you import from the wrong module.

### `on_mount` hook handlers must `{:halt, socket}` for handled messages
Returning `{:cont, socket}` from a hook's `handle_info` interceptor passes the message through to the LiveView's own `handle_info/2`. If the LiveView has no matching clause (e.g., for `%Phoenix.Socket.Broadcast{event: "presence_diff"}`), it crashes. Use `{:halt, socket}` for messages the hook fully handles, `{:cont, socket}` only for messages the LiveView should also see.

### `Plug.Test.init_test_session/2` merges, doesn't replace
Calling `init_test_session(conn, %{})` on a conn that already has session data won't clear existing keys. To test the "no session" path, start from a fresh `Phoenix.ConnTest.build_conn()`.

### Presence tests are timing-dependent
`Process.sleep(100)` passes locally but is flaky on CI. Use an `assert_eventually` retry helper (50ms intervals, ~50 attempts) instead of fixed sleeps for presence propagation assertions.

### PTY window size must be set explicitly (Slice 7)
`pty.Start(cmd)` from `creack/pty` does NOT set a terminal size, resulting in 0x0 dimensions. Codex rendered one character per line because it respected the PTY's reported column count of 0. Claude Code was unaffected (it has its own internal default). Fix: always use `pty.StartWithSize(cmd, &pty.Winsize{Rows: 40, Cols: 120})`. This was only caught during browser-based manual testing — unit tests don't exercise terminal rendering.

### PTY output must be drained before `cmd.Wait()` (Slice 7)
When using `cmd.Wait()` on a PTY-spawned process, the call hangs forever if nobody is reading from the PTY master fd. The PTY buffer fills up, the child process blocks on write, and `Wait` never returns. Fix: always `go io.Copy(io.Discard, reader)` (or use a TeeReader) before calling `Wait`. The existing `LoopManager` tests passed because `StartLoop` always sets up a reader goroutine — the bug only manifested in isolated adapter unit tests.

### `cmd.Wait()` can only be called once (Slice 7)
Go's `exec.Cmd.Wait` must only be called once. If two goroutines both call `Wait`, the second one deadlocks on the internal `wait4` syscall. The initial `killProcess` implementation called `sess.Wait()` to reap the process after signaling, but the caller's `Wait` goroutine was already waiting. Fix: `killProcess` just sends signals; the existing `Wait` goroutine handles process exit and status collection.

### Setpgid causes "operation not permitted" in sandboxed environments (Slice 7)
Setting `cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}` fails in sandboxed/restricted environments (not just macOS — also CI containers and similar). The PTY package already provides process isolation through the PTY session setup, so Setpgid is unnecessary. See also the macOS-specific gotcha below.

### macOS PTY + Setpgid conflict (Slice 5)
Setting `SysProcAttr.Setpgid = true` on a command started with `creack/pty` causes "operation not permitted" on macOS. The `creack/pty` library handles session setup internally via `Setsid`. Remove `Setpgid` entirely. To signal the process, send signals to the PID directly rather than the process group.

### xterm.js CSS must be explicitly linked (Slice 5)
esbuild extracts CSS from JS imports (like `import "xterm/css/xterm.css"`) into a separate `app.css` file in the JS output directory (`priv/static/assets/js/app.css`). This file is NOT automatically included — it must be explicitly linked in `root.html.heex` alongside the Tailwind CSS file. Easy to miss because the terminal renders but looks broken (zero-height lines, no cursor).

### xterm.js terminal sizing (Slice 5)
The xterm.js terminal div needs concrete pixel dimensions at mount time. Using `h-full w-full` inside flex containers is not enough — the terminal calculates rows/cols from pixel measurements. Use absolute positioning (`position: absolute; inset: 0` with small padding) inside a `position: relative` parent with defined dimensions.

### `time.Duration` double-conversion in Go (Slice 5)
`time.Duration(millisInt64) * time.Millisecond` is a double-conversion bug. `time.Duration` is already in nanoseconds, and `time.Millisecond` is 1,000,000 nanoseconds. If `millisInt64` is 1500, this produces 1500 * 1,000,000 = 1.5 trillion nanoseconds (~25 minutes), not 1.5 seconds. Correct: `time.Duration(millisInt64) * time.Millisecond` only if `millisInt64` is a raw integer, not already a Duration. When in doubt, use `time.Duration(millisInt64) * time.Millisecond` with a plain `int64`, or just `1500 * time.Millisecond`.

### DynamicSupervisor restart policy for ephemeral GenServers (Slice 5)
GenServers under DynamicSupervisor default to `restart: :permanent`, so `GenServer.stop/2` causes immediate restart. For ephemeral processes (like per-loop terminal buffers), use `use GenServer, restart: :temporary` so they stay stopped when stopped.

### Registry unregistration timing (Slice 5)
After stopping a process registered via Elixir `Registry`, there is a small window where `Registry.lookup/2` still returns the old (now-dead) PID. Tests must use polling/retry assertions (e.g., `assert_eventually`) rather than fixed `Process.sleep` calls.

### UTF-8 boundary splitting in output chunker (Slice 5)
`utf8.DecodeLastRune` does not reliably detect incomplete multi-byte sequences at chunk boundaries. Better approach: when the buffer is full, walk backward from the cut point to find a `utf8.RuneStart` byte, then use `utf8.DecodeRune` forward to check whether the full rune fits within the chunk. If not, split before that rune start and carry the incomplete bytes into the next chunk.

### Claude Code prompt delivery — failed approaches (Slice 5)
Three approaches that do NOT work for delivering prompts to Claude Code:
1. Writing `prompt + "\n"` to PTY master — TUI expects `\r`, not `\n`.
2. Pattern matching for `>` in output to detect readiness — `>` appears constantly in ANSI escape sequences and splash screen content, triggers false positives immediately.
3. Idle detection with incorrect duration math — see the `time.Duration` double-conversion gotcha above; the timeout comparison will never fire.

### Use `just` recipes for pre-commit workflow (Slice 7)
When formatting, linting, testing, and building before a commit, always use `just` recipes from the repo root: `just format`, `just lint`, `just test`. Do NOT run `go fmt`, `go vet`, `mix format`, `mix compile --warnings-as-errors` manually — they require `cd`-ing into the correct subdirectory and it's easy to forget or run from the wrong directory (which fails silently or with confusing errors). The justfile handles all of this. Same applies for `just build-cli` instead of `go build ./cmd/...`.

### Always read before writing to existing files (Slice 6)
When adding content to an existing file (like the justfile), use `Edit` (targeted replacement) rather than `Write` (full file overwrite). During Slice 6, the existing `build-cli` and `server` recipes in the justfile were destroyed by a `Write` that replaced the entire file. Rule: always `Read` first, then `Edit` to append or modify specific sections.

## Project Path

The project root is located at `/Users/ada/fun/algedonia`. All `just` recipes and relative paths in the codebase are anchored to this directory.

## Useful Commands

```bash
# Monorepo commands (run from repo root)
just test                    # All tests
just lint                    # All linters
just format                  # All formatters
just test-server             # Elixir tests only
just test-daemon             # Go tests only
just build-cli               # Build daemon CLI as "ag" and install to ~/bin
just server                  # Start Phoenix dev server
```

## Rubric Notes
### Session learnings (2026-02-24)
- Invite-token auth is fully removed. Migrations must not add `invite_token` to `workspaces`, and data seeds should not reference it. The GitHub device-flow auth migration now drops the column/index defensively.
- GoReleaser packaging expects a LICENSE file if included in `.goreleaser.yaml`; add a proprietary `LICENSE` for commercial use to avoid release failures.
- Use `just format`, `just lint`, `just test` for full-stack checks; Elixir Mix tasks may require extra permissions for local sockets in this environment.
