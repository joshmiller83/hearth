#!/bin/bash
# Shared helpers for the deploy scripts. Sourced, not run.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$DEPLOY_DIR/config.env" ]] || die "Missing deploy/config.env. Copy deploy/config.env.example and edit it."
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.env"

SERVER_LABEL="$LABEL_PREFIX.hearth"
BACKUP_LABEL="$LABEL_PREFIX.hearth-backup"
WATCHDOG_LABEL="$LABEL_PREFIX.hearth-watchdog"
BIN="$DATA_DIR/bin/$SERVER_PRODUCT"
LOCAL_URL="http://$HOST:$PORT"
HOUSEHOLD_FILE="$DATA_DIR/household.json"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# wait_for_health <seconds>: true once /v1/health answers.
wait_for_health() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -o /dev/null --max-time 3 "$LOCAL_URL/v1/health" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
