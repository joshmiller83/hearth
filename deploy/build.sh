#!/bin/bash
# Build the relay in release mode and stage it in $DATA_DIR/bin. No sudo.
# The swap is atomic, so a running relay keeps its old binary until it restarts.
source "$(dirname "$0")/lib.sh"

[[ $EUID -ne 0 ]] || die "run without sudo"

say "Testing the relay first"
swift test --package-path "$REPO_DIR/Relay" >/dev/null || die "relay tests failed; not deploying"

say "Building $SERVER_PRODUCT (release)"
swift build -c release --package-path "$REPO_DIR/Relay" --product "$SERVER_PRODUCT"
built="$(swift build -c release --package-path "$REPO_DIR/Relay" --show-bin-path)/$SERVER_PRODUCT"
[[ -x "$built" ]] || die "no binary at $built"

install -d "$DATA_DIR"/{bin,data,backups,logs}
install -d -m 700 "$DATA_DIR/secrets"
[[ -f "$HOUSEHOLD_FILE" ]] || warn "No $HOUSEHOLD_FILE yet. Copy deploy/household.example.json there and fill it in."
cp "$built" "$BIN.new"
mv -f "$BIN.new" "$BIN"
git -C "$REPO_DIR" rev-parse --short HEAD > "$DATA_DIR/bin/VERSION"
git -C "$REPO_DIR" diff --quiet || echo "dirty" >> "$DATA_DIR/bin/VERSION"
say "Staged $BIN ($(tr '\n' ' ' < "$DATA_DIR/bin/VERSION"))"
