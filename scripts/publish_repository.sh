#!/bin/bash
# Run by an authorized work session with an authenticated gh CLI.
# Publishes this independent source repository, never ai-traces history.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(git rev-parse --show-toplevel)" != "$PWD" ]; then
  echo 'Refusing: project must be its own Git root, not a directory inside ai-traces.' >&2
  exit 78
fi
if [ -d private ] || git ls-files | grep -E '(^|/)(private|canonical|History|session-state)/|\.(p8|p12|pem|key|keychain-db|mobileprovision)$|Key-Recovery'; then
  echo 'Refusing: private material or private-repository paths are present.' >&2
  exit 78
fi
if [ -n "$(git status --porcelain)" ]; then
  echo 'Commit and review the complete source snapshot before publication.' >&2
  exit 78
fi
gh auth status
if gh repo view timelabs-npo/Rhea-RF-Spanner >/dev/null 2>&1; then
  echo 'Repository already exists. Inspect its state instead of overwriting it.' >&2
  exit 73
fi
gh repo create timelabs-npo/Rhea-RF-Spanner --public \
  --description 'Rhea RF Spanner — transparent, on-device iOS acoustic phase experiments. Swift 6, iOS 18+.' \
  --source . --remote origin --push

