# Codebase Knowledge

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

## Gotchas

### `attach_hook/4` is in `Phoenix.LiveView`, not `Phoenix.Component`
Easy to assume it's in `Phoenix.Component` since `assign/3` is there. Will get a compile error if you import from the wrong module.

### `on_mount` hook handlers must `{:halt, socket}` for handled messages
Returning `{:cont, socket}` from a hook's `handle_info` interceptor passes the message through to the LiveView's own `handle_info/2`. If the LiveView has no matching clause (e.g., for `%Phoenix.Socket.Broadcast{event: "presence_diff"}`), it crashes. Use `{:halt, socket}` for messages the hook fully handles, `{:cont, socket}` only for messages the LiveView should also see.

### `Plug.Test.init_test_session/2` merges, doesn't replace
Calling `init_test_session(conn, %{})` on a conn that already has session data won't clear existing keys. To test the "no session" path, start from a fresh `Phoenix.ConnTest.build_conn()`.

### Presence tests are timing-dependent
`Process.sleep(100)` passes locally but is flaky on CI. Use an `assert_eventually` retry helper (50ms intervals, ~50 attempts) instead of fixed sleeps for presence propagation assertions.

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

## Useful Commands

## Rubric Notes
