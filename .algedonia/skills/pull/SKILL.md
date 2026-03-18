---
name: pull
description:
  Rebase current branch on top of latest origin/main (and latest remote branch
  tip) while resolving conflicts cleanly.
---

# Pull

This is a rebase-based pull skill.

## Goals

- Sync local branch with remote branch and `origin/main` using rebase.
- Keep history linear and review-friendly.
- Resolve conflicts with minimal behavioral drift.

## Workflow

1. Ensure working tree is clean (or stash/commit first).
2. Enable rerere for repeat conflict resolution:
   - `git config rerere.enabled true`
   - `git config rerere.autoupdate true`
3. From the worktree root, run the helper:
   - `./.algedonia/skills/pull/scripts/rebase_branch.sh`
4. The helper fetches `origin`, checks `refs/remotes/origin/$(git branch --show-current)`, and prints the selected path with the branch name:
   - remote branch exists: `pull: branch <name> using remote-branch rebase via origin/<name>`
   - remote branch missing: `pull: branch <name> using origin/main fallback because refs/remotes/origin/<name> is missing`
5. The helper always finishes with:
   - `git rebase origin/main`
6. If conflicts occur:
   - resolve files
   - `git add <files>`
   - `git rebase --continue`
7. If needed, abort safely:
   - `git rebase --abort`
8. Run project validation (repo-standard checks/tests).
9. Summarize conflict decisions and follow-ups.

## Conflict Guidance

- Decide intended final behavior before editing conflict hunks.
- Preserve existing invariants and contracts unless intentionally changed.
- Prefer minimal edits over broad rewrites during conflict resolution.
- Ensure markers are gone:
  - `git diff --check`

## Ask User Only When

- Product intent is ambiguous and code/tests provide no signal.
- Resolution changes public contract or migration behavior with risk.
- Two plausible designs exist with no local tie-breaker.
