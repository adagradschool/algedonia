---
name: test
type: command
run: just test
pass: exit_code == 0
description: Run all tests (server + daemon)
---

# Test

Runs the full test suite across both server (Elixir) and daemon (Go):
- `mix test` in `server/`
- `go test ./...` in `daemon/`

This is a base pipeline skill — it runs on every ticket regardless of planning output.
