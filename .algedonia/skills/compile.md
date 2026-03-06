---
name: compile
type: command
run: just lint-server
pass: exit_code == 0
description: Compile Elixir with warnings-as-errors and run Credo strict
---

# Compile

Runs the full Elixir compilation pipeline with strict checks:
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`
- `mix credo --strict`

This is a base pipeline skill — it runs on every ticket regardless of planning output.
