#!/usr/bin/env bash
set -euo pipefail

# Trigger the GitHub Actions APK build workflow.
# The APK artifact can be downloaded from the printed run URL.

cd "$(dirname "$0")"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required (https://cli.github.com/)." >&2
  exit 1
fi

run_url=$(gh workflow run android.yml 2>&1 | tail -n 1)
echo "Triggered: $run_url"
