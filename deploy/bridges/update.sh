#!/bin/bash
# Ship new bridge or Synapse versions after bumping versions.env: build, restart, check.
# No sudo: the daemons run as $SERVICE_USER, so that user can stop them and launchd's
# KeepAlive starts the new builds right away (as deploy/update.sh does for the relay).
source "$(dirname "$0")/lib.sh"

"$DEPLOY_DIR/bridges/build.sh"

# restart <pattern> <name>: stop the matching process; launchd starts it again.
restart() {
  if pgrep -u "$SERVICE_USER" -f "$1" >/dev/null; then
    say "Restarting $2"
    pkill -TERM -u "$SERVICE_USER" -f "$1"
  else
    warn "$2 isn't running. Install the daemons with: sudo deploy/bridges/install.sh"
    exit 1
  fi
}

# Synapse first: it reads the registrations only at start.
restart "synapse.app.homeserver --config-path $SYNAPSE_DIR/" Synapse
sleep 3
wait_for_url "$MATRIX_URL/health" 120 || die "Synapse didn't come back. See $DATA_DIR/logs/matrix.log"

for net in $BRIDGES; do
  [[ -f "/Library/LaunchDaemons/$(bridge_label "$net").plist" ]] \
    || die "$net has no daemon yet; run: sudo deploy/bridges/install.sh"
  restart "$(bridge_bin "$net") -c" "the $net bridge"
done
sleep 3
for net in $BRIDGES; do
  wait_for_url "$(bridge_url "$net")/_matrix/mau/live" 60 \
    || die "the $net bridge didn't come back. See $DATA_DIR/logs/bridge-$net.log"
done

"$DEPLOY_DIR/bridges/status.sh"
