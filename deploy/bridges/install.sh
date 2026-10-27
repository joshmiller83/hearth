#!/bin/bash
# Install the message bridges' launchd daemons. Needs root; rerun it whenever BRIDGES
# changes or after editing a template:
#   sudo deploy/bridges/install.sh
#   <prefix>.hearth-matrix             Synapse, the bridges' homeserver, on 127.0.0.1:$MATRIX_PORT
#   <prefix>.hearth-bridge-<network>   one per bridge in $BRIDGES, on 127.0.0.1
#   <prefix>.hearth-matrix-backup      a nightly copy of their databases and keys at 3:35
# Like the relay, they start at boot without anyone logging in, run as $SERVICE_USER,
# and launchd restarts them when they exit; the watchdog restarts them when they hang.
# A network taken out of BRIDGES loses its daemon; with BRIDGES empty, all of these go.
# The data stays in $DATA_DIR/matrix either way. It also gives the relay the new list,
# since the relay reads the bridges' chats into Texts. Run deploy/bridges/build.sh first.
source "$(dirname "$0")/lib.sh"

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0"

# relay_follows: re-render the relay's daemon with the current BRIDGES and restart it,
# if it's installed (deploy/install-services.sh).
relay_follows() {
  [[ -f "/Library/LaunchDaemons/$SERVER_LABEL.plist" ]] || return 0
  render server.plist.template "$SERVER_LABEL"
  reload "$SERVER_LABEL"
  wait_for_health 60 || warn "The relay didn't answer within a minute. See $DATA_DIR/logs/relay.log"
}

# remove <label>: unload a daemon and delete its plist, if it's installed.
remove() {
  if [[ -f "/Library/LaunchDaemons/$1.plist" ]]; then
    launchctl bootout "system/$1" 2>/dev/null || true
    rm -f "/Library/LaunchDaemons/$1.plist"
    say "removed $1"
  fi
}

say "Installing the watchdog and backup scripts into $SUPPORT_DIR"
install_support_files

if [[ -z "$BRIDGES" ]]; then
  for net in $KNOWN_BRIDGES; do remove "$(bridge_label "$net")"; done
  remove "$MATRIX_BACKUP_LABEL"
  remove "$MATRIX_LABEL"
  relay_follows
  say "No bridges in BRIDGES, so none are installed. Their data stays in $MATRIX_DIR."
  exit 0
fi

[[ -f "$SYNAPSE_DIR/hearth.yaml" ]] || die "nothing built yet; run deploy/bridges/build.sh first (without sudo)"
for net in $BRIDGES; do
  [[ -x "$(bridge_bin "$net")" && -f "$(bridge_dir "$net")/registration.yaml" ]] \
    || die "$net isn't built; run deploy/bridges/build.sh first (without sudo)"
  grep -q "$(bridge_dir "$net")/registration.yaml" "$SYNAPSE_DIR/hearth.yaml" \
    || die "$net was added after the last build; run deploy/bridges/build.sh again (without sudo)"
done

render matrix.plist.template "$MATRIX_LABEL" \
  -e "s|__SYNAPSE_VENV__|$SYNAPSE_VENV|g" -e "s|__SYNAPSE_DIR__|$SYNAPSE_DIR|g"
reload "$MATRIX_LABEL"
wait_for_url "$MATRIX_URL/health" 120 || die "Synapse didn't answer within two minutes. See $DATA_DIR/logs/matrix.log"

for net in $KNOWN_BRIDGES; do
  label="$(bridge_label "$net")"
  if in_bridges "$net"; then
    render bridge.plist.template "$label" -e "s|__NETWORK__|$net|g" \
      -e "s|__BRIDGE_BIN__|$(bridge_bin "$net")|g" -e "s|__BRIDGE_DIR__|$(bridge_dir "$net")|g"
    reload "$label"
    wait_for_url "$(bridge_url "$net")/_matrix/mau/live" 60 \
      || warn "the $net bridge didn't answer within a minute. See $DATA_DIR/logs/bridge-$net.log"
  else
    remove "$label"
  fi
done

render matrix-backup.plist.template "$MATRIX_BACKUP_LABEL"
reload "$MATRIX_BACKUP_LABEL"
relay_follows

say "Done. Next, once per network: deploy/bridges/login.sh <network>  (without sudo; $BRIDGES)"
say "Their chats reach Texts within two minutes of signing in."
