---
name: push
description:
  Push current branch to origin and create/update the pull request with accurate
  title/body and validation notes.
---

# Push

## Goals

- Push branch safely.
- Ensure an open PR exists and reflects current scope.
- Avoid unsafe force pushes.

## Steps

1. Confirm branch and working tree state.
2. Run the repository's standard validation commands.
3. Push branch:
   - `git push -u origin HEAD`
4. If non-fast-forward, run the `pull` skill (rebase-based), then push again.
5. Use `git push --force-with-lease origin HEAD` only when history was intentionally rewritten.
6. Ensure PR exists:
   - create if missing
   - update title/body if existing scope changed
7. Return PR URL.

## Commands

```bash
branch=$(git branch --show-current)

git push -u origin HEAD

# If needed after intentional rewrite
# git push --force-with-lease origin HEAD

pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
pr_title="<clear title>"
pr_body="<what changed, why, validation>"

if [ -z "$pr_state" ]; then
  gh pr create --title "$pr_title" --body "$pr_body"
else
  gh pr edit --title "$pr_title" --body "$pr_body"
fi

gh pr view --json url -q .url
```

## Guardrails

- Never use plain `--force`.
- Do not switch remotes/protocols to bypass auth/permission issues.
- If push fails for policy or permissions, surface the exact error.
