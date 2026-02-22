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

## Gotchas

### `attach_hook/4` is in `Phoenix.LiveView`, not `Phoenix.Component`
Easy to assume it's in `Phoenix.Component` since `assign/3` is there. Will get a compile error if you import from the wrong module.

### `on_mount` hook handlers must `{:halt, socket}` for handled messages
Returning `{:cont, socket}` from a hook's `handle_info` interceptor passes the message through to the LiveView's own `handle_info/2`. If the LiveView has no matching clause (e.g., for `%Phoenix.Socket.Broadcast{event: "presence_diff"}`), it crashes. Use `{:halt, socket}` for messages the hook fully handles, `{:cont, socket}` only for messages the LiveView should also see.

### `Plug.Test.init_test_session/2` merges, doesn't replace
Calling `init_test_session(conn, %{})` on a conn that already has session data won't clear existing keys. To test the "no session" path, start from a fresh `Phoenix.ConnTest.build_conn()`.

### Presence tests are timing-dependent
`Process.sleep(100)` passes locally but is flaky on CI. Use an `assert_eventually` retry helper (50ms intervals, ~50 attempts) instead of fixed sleeps for presence propagation assertions.

## Useful Commands

## Rubric Notes
