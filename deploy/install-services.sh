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

install -d -o "$SERVICE_USER" -g staff "$DATA_DIR"/{bin,data,backups,logs}

say "Installing the watchdog into $SUPPORT_DIR"
install_support_files

render server.plist.template "$SERVER_LABEL"
render backup.plist.template "$BACKUP_LABEL"
render watchdog.plist.template "$WATCHDOG_LABEL"
reload "$SERVER_LABEL"
wait_for_health 60 || die "The relay didn't answer within a minute. See $DATA_DIR/logs/relay.log"
reload "$BACKUP_LABEL"
reload "$WATCHDOG_LABEL"

say "Done. Local: $LOCAL_URL/v1/health  Public: https://$PUBLIC_HOSTNAME/v1/health"
say "Next: deploy/tunnel-add-hostname.sh (once), a key with '$BIN issue-key --label iPhone', then deploy/smoke.sh"
