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

# Copy-truncate: launchd holds the logs open in append mode, so truncating in place is safe.
for lf in "$LOG_DIR"/relay.log "$LOG_DIR"/backup.log; do
  [[ -f "$lf" ]] && (( $(stat -f %z "$lf") > MAX_LOG_BYTES )) || continue
  for i in 2 1; do [[ -f "$lf.$i.gz" ]] && mv -f "$lf.$i.gz" "$lf.$((i + 1)).gz"; done
  gzip -c "$lf" > "$lf.1.gz" && : > "$lf"
  chown "$SERVICE_USER:staff" "$lf.1.gz"
  log "rotated $lf"
done
