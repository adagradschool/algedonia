---
name: lint-daemon
type: command
run: just lint-daemon
pass: exit_code == 0
description: Run Go vet and build checks
---

# Lint Daemon

Runs Go static analysis:
- `go vet ./...`
- `go build ./...`

This is a base pipeline skill — it runs on every ticket regardless of planning output.
