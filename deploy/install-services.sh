#!/bin/bash
# One-time (and re-runnable) system setup. Needs root:
#   sudo deploy/install-services.sh
# Installs three launchd daemons that start at boot without anyone logging in:
#   <prefix>.hearth           the relay, run as $SERVICE_USER, restarted if it exits
#   <prefix>.hearth-backup    a nightly database backup at 3:25
#   <prefix>.hearth-watchdog  restarts the relay if it stops answering, rotates logs
# Run deploy/build.sh (without sudo) first.
source "$(dirname "$0")/lib.sh"

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0"
[[ -x "$BIN" ]] || die "$BIN missing; run deploy/build.sh first (without sudo)"
[[ -f "$HOUSEHOLD_FILE" ]] || die "$HOUSEHOLD_FILE missing; copy deploy/household.example.json there and fill it in"
[[ -x "$GMAILKIT_DIR/.venv/bin/python" ]] || die "no gmailkit venv at $GMAILKIT_DIR/.venv (see docs/deploy.md)"

SUPPORT_DIR="/Library/Application Support/HearthRelay"
install -d -o "$SERVICE_USER" -g staff "$DATA_DIR"/{bin,data,backups,logs}

render() {  # render <template> <label>
  local dest="/Library/LaunchDaemons/$2.plist"
  sed -e "s|__LABEL__|$2|g" \
      -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
      -e "s|__DATA_DIR__|$DATA_DIR|g" \
      -e "s|__BIN__|$BIN|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__GMAILKIT_DIR__|$GMAILKIT_DIR|g" \
      -e "s|__ANTHROPIC_KEY_FILE__|${ANTHROPIC_KEY_FILE:-}|g" \
      -e "s|__SUPPORT_DIR__|$SUPPORT_DIR|g" \
      "$DEPLOY_DIR/launchd/$1" > "$dest"
  chown root:wheel "$dest"
  chmod 644 "$dest"
  plutil -lint "$dest" >/dev/null || die "invalid plist: $dest"
}

reload() {  # reload <label>
  launchctl bootout "system/$1" 2>/dev/null || true
  launchctl bootstrap system "/Library/LaunchDaemons/$1.plist"
  say "loaded $1"
}

say "Installing the watchdog into $SUPPORT_DIR"
install -d -o root -g wheel -m 755 "$SUPPORT_DIR"
install -o root -g wheel -m 755 "$DEPLOY_DIR/watchdog.sh" "$SUPPORT_DIR/watchdog.sh"
install -o root -g wheel -m 644 "$DEPLOY_DIR/config.env" "$SUPPORT_DIR/config.env"

render server.plist.template "$SERVER_LABEL"
render backup.plist.template "$BACKUP_LABEL"
render watchdog.plist.template "$WATCHDOG_LABEL"
reload "$SERVER_LABEL"
wait_for_health 60 || die "The relay didn't answer within a minute. See $DATA_DIR/logs/relay.log"
reload "$BACKUP_LABEL"
reload "$WATCHDOG_LABEL"

say "Done. Local: $LOCAL_URL/v1/health  Public: https://$PUBLIC_HOSTNAME/v1/health"
say "Next: deploy/tunnel-add-hostname.sh (once), a key with '$BIN issue-key --label iPhone', then deploy/smoke.sh"
