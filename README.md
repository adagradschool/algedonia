# Algedonia

**Algedonia helps teams ship AI-generated code they can trust.**

Most agent tools help you produce code faster. Algedonia helps you produce code that is both fast and reliable by making verification part of the core workflow.

## The Product Pitch

Algedonia is an AI coding orchestrator built for real software delivery, not demo output.

You create a ticket with acceptance criteria. Algedonia breaks the work into smaller steps, runs them in parallel when safe, and verifies each result before it moves forward. If quality is unclear, it escalates with context so a human can decide quickly.

The outcome is simple: fewer broken merges, clearer decision points, and cleaner progress from request to shipped code.

## Core Features

- Maker-checker loops: one agent proposes changes, another independently verifies them
- Per-task quality rubrics so "done" is explicit, not guessed
- Automatic retries with feedback when checks fail
- Escalation queue for issues that need human clarification
- Circuit breaker to stop repeated failures from creating noise
- Parallel execution for independent tasks
- Clear artifact trail: diffs, verdicts, attempts, and final commits
- Live visibility into what is running and what is blocked

## Why It Is Different From Conductor-Style Orchestrators

Tools like Conductor, Temporal, and other workflow orchestrators are excellent at moving jobs through pipelines.

Algedonia is designed for a different problem: **trusting AI-written code in active development.**

Key differences:

- Verification-first: independent checking is built into every loop
- Code-quality focus: progress is measured by passing quality gates, not just task completion
- Human-attention design: escalations are structured and prioritized, not buried in logs
- Developer-native output: the product is working code and commit-ready artifacts

In short: traditional orchestrators optimize flow. Algedonia optimizes trustworthy outcomes.

## Who It Is For

- Teams using AI coding agents that want stronger quality control
- Developers who want speed without giving up review discipline
- Engineering groups that need a clear audit trail for what changed and why

## Repository Layout

- `daemon/` local agent runner
- `server/` orchestration service and UI
- `notes/` product and design documents (including the PRD)

For server setup, see `server/README.md`.

## License

See [LICENSE](LICENSE).
