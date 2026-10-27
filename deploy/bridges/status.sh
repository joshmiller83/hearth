#!/bin/bash
# The message bridges' part of `make status`: daemons, versions, and each bridge's
# login. No sudo.
source "$(dirname "$0")/lib.sh"
set +e

echo
echo "Message bridges ($MATRIX_USER):"
labels="$MATRIX_LABEL"
for net in $BRIDGES; do labels="$labels $(bridge_label "$net")"; done
for label in $labels "$MATRIX_BACKUP_LABEL"; do
  if launchctl print "system/$label" >/dev/null 2>&1; then
    state="$(launchctl print "system/$label" 2>/dev/null | awk -F'= ' '/^\tstate/ {print $2; exit}')"
    printf '%-34s loaded (%s)\n' "$label" "${state:-?}"
  else
    printf '%-34s not loaded\n' "$label"
  fi
done

echo
synapse="$("$SYNAPSE_VENV/bin/python" -c 'import synapse; print(synapse.__version__)' 2>/dev/null || echo 'not installed')"
health="$(curl -fsS --max-time 5 "$MATRIX_URL/health" 2>/dev/null || echo DOWN)"
printf 'Synapse:   %s, %s (pinned %s)\n' "$health" "$synapse" "$SYNAPSE_VERSION"

has_token=false
[[ -s "$MATRIX_TOKEN_FILE" ]] && has_token=true
for net in $BRIDGES; do
  live=ok
  curl -fsS -o /dev/null --max-time 5 "$(bridge_url "$net")/_matrix/mau/live" 2>/dev/null || live=DOWN
  built="$(cat "$(bridge_bin "$net").version" 2>/dev/null || echo 'not built')"
  logins="no account yet (deploy/bridges/login.sh $net makes it)"
  if [[ "$has_token" == true && "$live" == ok ]]; then
    logins="$(curl -fsS --max-time 10 -H @<(auth_header) \
      "$(bridge_url "$net")/_matrix/provision/v3/whoami?user_id=$(jq -rn --arg u "$MATRIX_USER" '$u | @uri')" 2>/dev/null \
      | jq -r '[.logins[] | "\(.name) \(.state.state_event)"] | if length == 0 then "not logged in (deploy/bridges/login.sh)" else join(", ") end')"
  fi
  printf '%-10s %s, %s (pinned %s): %s\n' "$net:" "$live" "$built" "$(bridge_version "$net")" "${logins:-?}"
done

latest="$(ls -t "$DATA_DIR"/backups/matrix-*.tar.gz 2>/dev/null | head -1)"
printf 'Backup:    %s\n' "${latest:-none yet}"
printf 'Size:      %s\n' "$(du -sh "$MATRIX_DIR" 2>/dev/null | awk '{print $1}')"
echo "Logs:      $DATA_DIR/logs/matrix.log, bridge-<network>.log"
