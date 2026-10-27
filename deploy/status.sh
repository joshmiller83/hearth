#!/bin/bash
# One screen of everything about the running relay. No sudo.
source "$(dirname "$0")/lib.sh"
set +e

for label in "$SERVER_LABEL" "$BACKUP_LABEL" "$WATCHDOG_LABEL"; do
  if launchctl print "system/$label" >/dev/null 2>&1; then
    state="$(launchctl print "system/$label" 2>/dev/null | awk -F'= ' '/^\tstate/ {print $2; exit}')"
    printf '%-34s loaded (%s)\n' "$label" "${state:-?}"
  else
    printf '%-34s not loaded\n' "$label"
  fi
done

echo
deployed="$(head -1 "$DATA_DIR/bin/VERSION" 2>/dev/null || echo unknown)"
git -C "$REPO_DIR" fetch -q origin main 2>/dev/null
main="$(git -C "$REPO_DIR" rev-parse --short origin/main 2>/dev/null || echo '?')"
behind="$(git -C "$REPO_DIR" rev-list --count "$deployed..origin/main" 2>/dev/null || echo '?')"
printf 'Binary:  %s (deployed %s; main is %s, %s commit(s) ahead)\n' "$BIN" "$deployed" "$main" "$behind"
printf 'Local:   %s\n' "$(curl -fsS --max-time 5 "$LOCAL_URL/v1/health" 2>/dev/null || echo DOWN)"
printf 'Public:  %s\n' "$(curl -fsS --max-time 10 "https://$PUBLIC_HOSTNAME/v1/health" 2>/dev/null || echo DOWN)"
latest="$(ls -t "$DATA_DIR"/backups/*.sqlite 2>/dev/null | head -1)"
printf 'Backup:  %s\n' "${latest:-none yet}"
printf 'DB size: %s\n' "$(du -h "$DATA_DIR"/data/*.sqlite 2>/dev/null | awk '{print $1}' | head -1)"
echo
echo "Last log lines ($DATA_DIR/logs/relay.log):"
tail -n 8 "$DATA_DIR/logs/relay.log" 2>/dev/null

if [[ -n "${BRIDGES:-}" ]]; then
  "$DEPLOY_DIR/bridges/status.sh"
fi
