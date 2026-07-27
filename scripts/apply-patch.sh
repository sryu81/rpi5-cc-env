#!/bin/bash
# Idempotently apply a patch to a repo's working tree. Safe to call on
# every build: if the patch is already applied (still there from a previous
# run), this is a no-op; if the repo was reset/re-cloned and lost it,
# this re-applies it. Patches live in patches/, NOT inside the repos —
# never commits anything inside a repo.
# Usage: apply-patch.sh <repo-dir> <patch-file>
set -euo pipefail

REPO_DIR="$1"
PATCH="$2"

cd "$REPO_DIR"

if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "apply-patch: already applied — $(basename "$PATCH")"
else
    echo "apply-patch: applying — $(basename "$PATCH")"
    git apply "$PATCH"
fi
