---
name: rebase
description:
  Rebase the current branch onto a target base branch and resolve conflicts
  safely while preserving intended behavior.
---

# Rebase

## Use When

- Asked to rebase explicitly.
- Branch history needs cleanup before review/merge.

## Workflow

1. Ensure clean working tree.
2. Fetch latest refs (`git fetch origin`).
3. Rebase onto target base (default `origin/main`):
   - `git rebase origin/main`
4. Resolve conflicts file-by-file, then:
   - `git add <files>`
   - `git rebase --continue`
5. Abort if needed:
   - `git rebase --abort`
6. Run repository validation checks.
7. If rewritten history is published, push with lease:
   - `git push --force-with-lease`

## Guardrails

- Preserve semantics first; optimize second.
- Avoid broad refactors during conflict resolution.
- Never use plain `--force`.
