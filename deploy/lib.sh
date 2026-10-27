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
# Root-owned copies of the scripts launchd runs as root (or that config.env drives).
SUPPORT_DIR="/Library/Application Support/HearthRelay"

# Where the relay reads WhatsApp and Messenger (deploy/bridges), when BRIDGES has any:
# the bridges' homeserver, the relay's token for it, and the account the bridges work for.
RELAY_BRIDGES="${BRIDGES:-}"
RELAY_MATRIX_URL=""
RELAY_MATRIX_TOKEN_FILE=""
RELAY_MATRIX_USER=""
if [[ -n "$RELAY_BRIDGES" ]]; then
  RELAY_MATRIX_URL="http://127.0.0.1:${MATRIX_PORT:-8008}"
  RELAY_MATRIX_TOKEN_FILE="$DATA_DIR/secrets/matrix-token"
  RELAY_MATRIX_USER="@hearth:${MATRIX_SERVER_NAME:-hearth.local}"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# relay_env: the daemon's settings, for running relay commands by hand.
relay_env() {
  export HEARTH_DB="$DATA_DIR/data/hearth.sqlite" HEARTH_BACKUP_DIR="$DATA_DIR/backups" \
    HEARTH_HOUSEHOLD="$HOUSEHOLD_FILE" HEARTH_GMAILKIT_DIR="$GMAILKIT_DIR" \
    HEARTH_ANTHROPIC_KEY_FILE="${ANTHROPIC_KEY_FILE:-}" \
    HEARTH_APNS_KEY_FILE="${APNS_KEY_FILE:-}" HEARTH_APNS_KEY_ID="${APNS_KEY_ID:-}" \
    HEARTH_APNS_TEAM_ID="${APNS_TEAM_ID:-}" HEARTH_APNS_TOPIC="${APNS_TOPIC:-}" \
    HEARTH_APNS_ENV="${APNS_ENV:-development}" HEARTH_BRIDGES="$RELAY_BRIDGES" \
    HEARTH_MATRIX_URL="$RELAY_MATRIX_URL" HEARTH_MATRIX_TOKEN_FILE="$RELAY_MATRIX_TOKEN_FILE" \
    HEARTH_MATRIX_USER="$RELAY_MATRIX_USER"
}

# render <template> <label> [-e <sed expression> …]: a plist from deploy/launchd into
# /Library/LaunchDaemons, with the shared placeholders filled in plus any extra
# expressions. Root only.
render() {
  local template="$1" label="$2" dest="/Library/LaunchDaemons/$2.plist"
  shift 2
  sed -e "s|__LABEL__|$label|g" \
      -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
      -e "s|__DATA_DIR__|$DATA_DIR|g" \
      -e "s|__BIN__|$BIN|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__GMAILKIT_DIR__|$GMAILKIT_DIR|g" \
      -e "s|__ANTHROPIC_KEY_FILE__|${ANTHROPIC_KEY_FILE:-}|g" \
      -e "s|__APNS_KEY_FILE__|${APNS_KEY_FILE:-}|g" \
      -e "s|__APNS_KEY_ID__|${APNS_KEY_ID:-}|g" \
      -e "s|__APNS_TEAM_ID__|${APNS_TEAM_ID:-}|g" \
      -e "s|__APNS_TOPIC__|${APNS_TOPIC:-}|g" \
      -e "s|__APNS_ENV__|${APNS_ENV:-development}|g" \
      -e "s|__SUPPORT_DIR__|$SUPPORT_DIR|g" \
      -e "s|__BRIDGES__|$RELAY_BRIDGES|g" \
      -e "s|__MATRIX_URL__|$RELAY_MATRIX_URL|g" \
      -e "s|__MATRIX_TOKEN_FILE__|$RELAY_MATRIX_TOKEN_FILE|g" \
      -e "s|__MATRIX_USER__|$RELAY_MATRIX_USER|g" \
      "$@" \
      "$DEPLOY_DIR/launchd/$template" > "$dest"
  chown root:wheel "$dest"
  chmod 644 "$dest"
  plutil -lint "$dest" >/dev/null || die "invalid plist: $dest"
}

# reload <label>: (re)load a daemon rendered by render. Root only. bootout can return
# while a slow daemon is still stopping, and bootstrap fails until it's gone, so wait
# for it, and try again if bootstrap still loses a race (with the watchdog, say).
reload() {
  local attempt
  for attempt in 1 2 3; do
    launchctl bootout "system/$1" 2>/dev/null || true
    for _ in $(seq 30); do
      launchctl print "system/$1" >/dev/null 2>&1 || break
      sleep 1
    done
    if launchctl bootstrap system "/Library/LaunchDaemons/$1.plist"; then
      say "loaded $1"
      return 0
    fi
    warn "loading $1 failed (attempt $attempt of 3)"
    sleep 2
  done
  die "couldn't load $1; see: launchctl print system/$1"
}

# install_support_files: the root-owned copies in $SUPPORT_DIR. Root only; both
# installers run it, so either one picks up edits to these files or to config.env.
install_support_files() {
  install -d -o root -g wheel -m 755 "$SUPPORT_DIR"
  install -o root -g wheel -m 755 "$DEPLOY_DIR/watchdog.sh" "$SUPPORT_DIR/watchdog.sh"
  install -o root -g wheel -m 644 "$DEPLOY_DIR/config.env" "$SUPPORT_DIR/config.env"
  install -o root -g wheel -m 644 "$DEPLOY_DIR/bridges/networks.sh" "$SUPPORT_DIR/networks.sh"
  install -o root -g wheel -m 755 "$DEPLOY_DIR/bridges/backup.sh" "$SUPPORT_DIR/bridges-backup.sh"
}

# wait_for_health <seconds>: true once /v1/health answers.
wait_for_health() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -o /dev/null --max-time 3 "$LOCAL_URL/v1/health" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
