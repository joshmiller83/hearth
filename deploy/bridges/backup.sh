#!/bin/bash
# Nightly copy of the bridges' state, run as the service user at 3:35 by launchd
# (launchd/matrix-backup.plist.template), from the copy install.sh puts beside config.env.
# sqlite3's online backup makes consistent copies while everything keeps running.
# One archive a night, newest 30 kept, mode 600: it holds the homeserver's signing key,
# the bridges' sessions and @hearth's password and token, which is what lets a restore
# skip logging in again.
# Media isn't included: it's large, and Synapse deletes what nobody opens in 90 days.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/config.env"

MATRIX_DIR="$DATA_DIR/matrix"
KEEP=30
umask 077
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/synapse" "$work/secrets"
sqlite3 "$MATRIX_DIR/synapse/homeserver.db" ".backup '$work/synapse/homeserver.db'"
cp "$MATRIX_DIR"/synapse/*.yaml "$MATRIX_DIR"/synapse/*.signing.key "$work/synapse/"
for secret in matrix-password matrix-token; do
  if [[ -f "$DATA_DIR/secrets/$secret" ]]; then cp "$DATA_DIR/secrets/$secret" "$work/secrets/"; fi
done

for dir in "$MATRIX_DIR"/bridges/*/; do
  [[ -d "$dir" ]] || continue
  net="$(basename "$dir")"
  mkdir -p "$work/bridges/$net"
  [[ -f "$dir$net.db" ]] && sqlite3 "$dir$net.db" ".backup '$work/bridges/$net/$net.db'"
  cp "$dir"*.yaml "$work/bridges/$net/"
done

out="$DATA_DIR/backups/matrix-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$out" -C "$work" .
log "wrote $out ($(du -h "$out" | cut -f1))"

ls -t "$DATA_DIR"/backups/matrix-*.tar.gz | tail -n +$(( KEEP + 1 )) | while read -r old; do
  rm -f "$old" && log "removed $old"
done
