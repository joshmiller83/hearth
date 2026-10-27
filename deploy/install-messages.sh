#!/bin/bash
# Texts for Hearth: build hearth-messages, sign it, and run it every two minutes as
# a LaunchAgent (no sudo). It alone reads the Messages database, read-only; the
# relay serves the export it leaves in $DATA_DIR/data.
#
# Signed with your Developer ID and a fixed identifier, so the Full Disk Access you
# grant once keeps working when this script rebuilds it. Rerun it after changes to
# Relay/Sources/ChatReader or MessagesExport.
#   deploy/install-messages.sh            install or update
#   deploy/install-messages.sh --remove   stop it and delete its export
source "$(dirname "$0")/lib.sh"

[[ $EUID -ne 0 ]] || die "run without sudo: it's a LaunchAgent for $SERVICE_USER"
MESSAGES_LABEL="$LABEL_PREFIX.hearth-messages"
MESSAGES_BIN="$DATA_DIR/bin/hearth-messages"
AGENT="$HOME/Library/LaunchAgents/$MESSAGES_LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "$DOMAIN/$MESSAGES_LABEL" 2>/dev/null || true
  rm -f "$AGENT" "$DATA_DIR/data/messages.json" "$DATA_DIR/data/messages-status.json"
  say "Removed. You can also take hearth-messages out of Full Disk Access in System Settings."
  exit 0
fi

say "Building hearth-messages (release)"
swift build -c release --package-path "$REPO_DIR/Relay" --product hearth-messages
built="$(swift build -c release --package-path "$REPO_DIR/Relay" --show-bin-path)/hearth-messages"
[[ -x "$built" ]] || die "no binary at $built"

install -d "$DATA_DIR"/{bin,data,logs}
cp "$built" "$MESSAGES_BIN.new"
identity="${MESSAGES_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$identity" ]]; then
  say "Signing with $identity"
  codesign --force --sign "$identity" --identifier "$MESSAGES_LABEL" --timestamp=none "$MESSAGES_BIN.new"
else
  warn "No Developer ID in the keychain: signing ad hoc. Full Disk Access will need granting again after each rebuild."
  codesign --force --sign - --identifier "$MESSAGES_LABEL" "$MESSAGES_BIN.new"
fi
mv -f "$MESSAGES_BIN.new" "$MESSAGES_BIN"

sed -e "s|__LABEL__|$MESSAGES_LABEL|g" -e "s|__BIN__|$MESSAGES_BIN|g" -e "s|__DATA_DIR__|$DATA_DIR|g" \
  "$DEPLOY_DIR/launchd/messages.plist.template" > "$AGENT"
plutil -lint "$AGENT" >/dev/null || die "bad plist: $AGENT"
launchctl bootout "$DOMAIN/$MESSAGES_LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$AGENT"
launchctl kickstart -k "$DOMAIN/$MESSAGES_LABEL"
sleep 3

state="$(sed -n 's/.*"state" *: *"\([a-zA-Z]*\)".*/\1/p' "$DATA_DIR/data/messages-status.json" 2>/dev/null | head -1)"
case "$state" in
  ok) say "Reading texts: $(tail -1 "$DATA_DIR/logs/messages.log")" ;;
  needsAccess)
    warn "hearth-messages needs Full Disk Access (once):"
    echo "   System Settings › Privacy & Security › Full Disk Access › +"
    echo "   press ⌘⇧G, enter $MESSAGES_BIN, Open, and switch it on."
    echo "   It runs again within two minutes; or now: launchctl kickstart -k $DOMAIN/$MESSAGES_LABEL"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true ;;
  *) warn "hearth-messages said: $(tail -1 "$DATA_DIR/logs/messages.log" 2>/dev/null)" ;;
esac
