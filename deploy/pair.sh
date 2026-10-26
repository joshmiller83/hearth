#!/bin/bash
# Pair a phone: makes a relay key and shows it as a QR code (a hearth://pair link).
# Scan it with the iPhone's camera; Hearth asks before saving it. The key never
# needs typing, and it isn't printed. No sudo.
source "$(dirname "$0")/lib.sh"

relay_env
link="$(cd "$DATA_DIR" && "$BIN" pair --url "https://$PUBLIC_HOSTNAME" --label "${1:-iPhone}" 2>/dev/null \
  | grep '^hearth://pair' | tail -1)"
[[ -n "$link" ]] || die "couldn't make a pairing link (is $BIN built?)"
out="$(mktemp -d)/hearth-pair.png"
swift "$DEPLOY_DIR/qr.swift" "$link" "$out" || die "couldn't draw the QR code"
say "Scan this with the iPhone's camera, then close it: $out"
open -a Preview "$out"
