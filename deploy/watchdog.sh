#!/bin/bash
# Health watchdog, run as root every 2 minutes by launchd (launchd/watchdog.plist.template).
# install-services.sh copies this file and config.env into a root-owned folder,
# so rerun that installer after editing either one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/config.env"

LABEL="$LABEL_PREFIX.hearth"
STATE_DIR=/var/db/hearth-relay
LOG_DIR="$DATA_DIR/logs"
FAIL_LIMIT=3              # consecutive failed checks (about 6 minutes) before a restart
MAX_LOG_BYTES=20971520    # rotate logs above 20 MB, keeping 3 compressed copies

mkdir -p "$STATE_DIR"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# launchd's KeepAlive only notices exits; this catches a relay that hangs.
if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
  log "$LABEL is not loaded; loading it"
  launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" || log "failed to load $LABEL"
fi

f="$STATE_DIR/fails"
if curl -fsS -o /dev/null --max-time 15 "http://$HOST:$PORT/v1/health" 2>/dev/null; then
  [[ -s "$f" ]] && log "relay is healthy again"
  rm -f "$f"
else
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$f"
  log "health check failed ($n/$FAIL_LIMIT)"
  if (( n >= FAIL_LIMIT )); then
    log "restarting $LABEL"
    launchctl kickstart -k "system/$LABEL"
    echo 0 > "$f"
  fi
fi

# Log (don't act on) the public URL; if it breaks while local is fine, it's DNS or the tunnel.
p="$STATE_DIR/public.state"
if curl -fsS -o /dev/null --max-time 20 "https://$PUBLIC_HOSTNAME/v1/health" 2>/dev/null; then now=up; else now=down; fi
[[ "$now" != "$(cat "$p" 2>/dev/null)" ]] && log "https://$PUBLIC_HOSTNAME is $now"
echo "$now" > "$p"

# Message bridges (deploy/bridges), when there are any: the same hang check for
# Synapse and each bridge. (Whether each is still signed in is the relay's to report:
# its bridges job asks every two minutes and the phone's Sources shows it.)
if [[ -n "${BRIDGES:-}" && -f "$HERE/networks.sh" ]]; then
  source "$HERE/networks.sh"

  # probe <name> <url> <label>: (re)load an installed daemon that isn't loaded, and
  # restart a loaded one after FAIL_LIMIT failed checks.
  probe() {
    local f="$STATE_DIR/$1.fails" n
    if ! launchctl print "system/$3" >/dev/null 2>&1; then
      [[ -f "/Library/LaunchDaemons/$3.plist" ]] || return 0  # not installed
      log "$3 is not loaded; loading it"
      launchctl bootstrap system "/Library/LaunchDaemons/$3.plist" || log "failed to load $3"
      return 1
    fi
    if curl -fsS -o /dev/null --max-time 15 "$2" 2>/dev/null; then
      [[ -s "$f" ]] && log "$1 is healthy again"
      rm -f "$f"
      return 0
    fi
    n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$f"
    log "$1 health check failed ($n/$FAIL_LIMIT)"
    if (( n >= FAIL_LIMIT )); then
      log "restarting $3"
      launchctl kickstart -k "system/$3"
      echo 0 > "$f"
    fi
    return 1
  }

  probe matrix "http://127.0.0.1:${MATRIX_PORT:-8008}/health" "$LABEL_PREFIX.hearth-matrix"
  for net in $BRIDGES; do
    bport="$(bridge_port "$net")" || continue
    probe "$net" "http://127.0.0.1:$bport/_matrix/mau/live" "$LABEL_PREFIX.hearth-bridge-$net"
  done
fi

# Copy-truncate: launchd holds the logs open in append mode, so truncating in place is safe.
# It runs as the service user, who owns the logs folder, so root never follows a link
# planted there.
for lf in "$LOG_DIR"/relay.log "$LOG_DIR"/backup.log "$LOG_DIR"/messages.log "$LOG_DIR"/matrix.log "$LOG_DIR"/bridge-*.log; do
  [[ -f "$lf" && ! -L "$lf" ]] && (( $(stat -f %z "$lf") > MAX_LOG_BYTES )) || continue
  if sudo -u "$SERVICE_USER" /bin/sh -c '
    for i in 2 1; do [ -f "$1.$i.gz" ] && mv -f "$1.$i.gz" "$1.$((i + 1)).gz"; done
    gzip -c "$1" > "$1.1.gz" && : > "$1"' _ "$lf"; then
    log "rotated $lf"
  else
    log "couldn't rotate $lf as $SERVICE_USER"
  fi
done
