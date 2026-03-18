#!/usr/bin/env bash

set -euo pipefail

branch="$(git branch --show-current)"

if [[ -z "${branch}" ]]; then
  echo "pull: unable to determine current branch" >&2
  exit 1
fi

git config rerere.enabled true
git config rerere.autoupdate true
git fetch origin

remote_ref="refs/remotes/origin/${branch}"

if git show-ref --verify --quiet "${remote_ref}"; then
  echo "pull: branch ${branch} using remote-branch rebase via origin/${branch}"
  git pull --rebase origin "${branch}"
else
  echo "pull: branch ${branch} using origin/main fallback because ${remote_ref} is missing"
fi

git rebase origin/main
