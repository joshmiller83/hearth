#!/bin/bash
# End-to-end check against a running relay (local or public).
#   deploy/smoke.sh            checks https://$PUBLIC_HOSTNAME
#   deploy/smoke.sh --local    checks http://$HOST:$PORT
# With HEARTH_KEY set (a relay key) it also reads the full health and the calendar.
source "$(dirname "$0")/lib.sh"

base="https://$PUBLIC_HOSTNAME"
[[ "${1:-}" == "--local" ]] && base="$LOCAL_URL"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

say "Smoke test: $base"
health="$(curl -fsS --max-time 15 "$base/v1/health")" || fail "health check failed"
[[ "$(jq -r .status <<<"$health")" == "ok" ]] && pass "health: $(jq -c '{status,version,commit}' <<<"$health")" || fail "health: $health"
[[ "$(jq -r '.accounts // empty' <<<"$health")" == "" ]] && pass "health without a key shows nothing else" || fail "health leaked details without a key"

code="$(curl -s -o /dev/null -w '%{http_code}' "$base/v1/calendar/events")"
[[ "$code" == "401" ]] && pass "calendar without a key is refused (401)" || fail "calendar without a key answered $code"

if [[ -z "${HEARTH_KEY:-}" ]]; then
  warn "Set HEARTH_KEY to a relay key to check gmailkit and the calendar too."
  exit 0
fi
H=(-H "authorization: Bearer $HEARTH_KEY")
full="$(curl -fsS --max-time 30 "${H[@]}" "$base/v1/health")" || fail "keyed health failed"
pass "gmailkit: $(jq -r '.gmailkit.state' <<<"$full"); accounts: $(jq -r '[.accounts[]?.alias] | join(", ")' <<<"$full")"
events="$(curl -fsS --max-time 90 "${H[@]}" "$base/v1/calendar/events")" || fail "calendar failed"
pass "calendar: $(jq '.events | length' <<<"$events") events, $(jq '.problems | length' <<<"$events") problems"
say "All good."
