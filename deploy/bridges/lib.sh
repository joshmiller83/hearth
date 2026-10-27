#!/bin/bash
# Shared helpers for the message bridges' scripts. Sourced, not run.
#
# The layout under $DATA_DIR/matrix:
#   venv/                    Synapse's Python
#   synapse/                 homeserver.yaml (generated once, with the signing key),
#                            hearth.yaml (this kit's settings, rewritten by build.sh),
#                            doublepuppet.yaml, homeserver.db, media_store/
#   bridges/<network>/       config.yaml, registration.yaml, <network>.db
#   bin/                     the bridge binaries, each with a .version beside it
#   src/                     build checkouts (disposable)
# Secrets: $DATA_DIR/secrets/matrix-password and matrix-token (mode 600).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
source "$DEPLOY_DIR/bridges/networks.sh"
source "$DEPLOY_DIR/bridges/versions.env"

BRIDGES="${BRIDGES:-}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-hearth.local}"
MATRIX_PORT="${MATRIX_PORT:-8008}"
MATRIX_PYTHON="${MATRIX_PYTHON:-/usr/local/bin/python3.13}"

MATRIX_DIR="$DATA_DIR/matrix"
SYNAPSE_DIR="$MATRIX_DIR/synapse"
SYNAPSE_VENV="$MATRIX_DIR/venv"
MATRIX_URL="http://127.0.0.1:$MATRIX_PORT"
MATRIX_LOCALPART=hearth
MATRIX_USER="@$MATRIX_LOCALPART:$MATRIX_SERVER_NAME"
MATRIX_PASSWORD_FILE="$DATA_DIR/secrets/matrix-password"
MATRIX_TOKEN_FILE="$DATA_DIR/secrets/matrix-token"
MATRIX_LABEL="$LABEL_PREFIX.hearth-matrix"
MATRIX_BACKUP_LABEL="$LABEL_PREFIX.hearth-matrix-backup"

for _net in $BRIDGES; do
  bridge_port "$_net" >/dev/null || die "BRIDGES has '$_net'; the kit knows: $KNOWN_BRIDGES"
done

bridge_label() { echo "$LABEL_PREFIX.hearth-bridge-$1"; }
bridge_dir() { echo "$MATRIX_DIR/bridges/$1"; }
bridge_bin() { echo "$MATRIX_DIR/bin/$(bridge_binary "$1")"; }
bridge_url() { echo "http://127.0.0.1:$(bridge_port "$1")"; }
bridge_version() {
  case "$1" in whatsapp) echo "$MAUTRIX_WHATSAPP_VERSION" ;; facebook) echo "$MAUTRIX_META_VERSION" ;; esac
}
in_bridges() {  # in_bridges <network>: true if it's in $BRIDGES
  case " $BRIDGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# wait_for_url <url> <seconds>: true once the URL answers 2xx.
wait_for_url() {
  local deadline=$(( $(date +%s) + $2 ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

# auth_header: the relay's Matrix token as a header line, for `curl -H @<(auth_header)`,
# which keeps the token out of the process list.
auth_header() { printf 'authorization: Bearer %s\n' "$(cat "$MATRIX_TOKEN_FILE")"; }

# provision <network> <GET|POST> <path> [json]: a call to the bridge's provisioning API
# (/_matrix/provision/v3), authenticated as @hearth with the relay's token. Prints the
# response; dies with the bridge's message on an error.
provision() {
  local net="$1" method="$2" path="$3" body="${4:-}" sep='?' out
  [[ "$path" == *\?* ]] && sep='&'
  # The body (which can hold cookies or a password) goes in on stdin, not the command line.
  local args=(-sS --max-time 900 -X "$method" -H "content-type: application/json")
  [[ -n "$body" ]] && args+=(--data-binary @-)
  out="$(curl "${args[@]}" -H @<(auth_header) \
    "$(bridge_url "$net")/_matrix/provision/v3$path${sep}user_id=$(jq -rn --arg u "$MATRIX_USER" '$u | @uri')" \
    <<<"$body")" \
    || die "the $net bridge didn't answer; is it running? (make status)"
  if [[ "$(jq -r '.errcode // empty' <<<"$out" 2>/dev/null)" != "" ]]; then
    die "$net: $(jq -r '.error // .errcode' <<<"$out")"
  fi
  printf '%s' "$out"
}

# ensure_matrix_account: make @hearth, the account the bridges work for, and the
# relay's token for it, unless the token already works. Run as $SERVICE_USER with
# Synapse up. The password stays in secrets too, for signing in with a Matrix client.
# If the password no longer matches (a lost or restored secrets folder), the token
# comes from the double-puppeting registration instead, which can sign in as anyone
# on this homeserver.
ensure_matrix_account() {
  if [[ -s "$MATRIX_TOKEN_FILE" ]] &&
    curl -fsS -o /dev/null --max-time 10 -H @<(auth_header) "$MATRIX_URL/_matrix/client/v3/account/whoami" 2>/dev/null; then
    return 0
  fi
  wait_for_url "$MATRIX_URL/health" 5 || die "Synapse isn't answering at $MATRIX_URL. Install the daemons: sudo deploy/bridges/install.sh"
  install -d -m 700 "$DATA_DIR/secrets"
  [[ -s "$MATRIX_PASSWORD_FILE" ]] || (umask 077 && openssl rand -hex 24 | tr -d '\n' > "$MATRIX_PASSWORD_FILE")
  "$SYNAPSE_VENV/bin/register_new_matrix_user" -c "$SYNAPSE_DIR/homeserver.yaml" -u "$MATRIX_LOCALPART" \
    --password-file "$MATRIX_PASSWORD_FILE" --no-admin --exists-ok "$MATRIX_URL" >/dev/null \
    || die "couldn't make $MATRIX_USER"
  local resp dp_token
  if ! resp="$(jq -n --rawfile pw "$MATRIX_PASSWORD_FILE" --arg user "$MATRIX_LOCALPART" '{
      type: "m.login.password", identifier: {type: "m.id.user", user: $user}, password: $pw,
      device_id: "HEARTH_RELAY", initial_device_display_name: "Hearth relay"}' \
    | curl -fsS --max-time 15 -H 'content-type: application/json' --data-binary @- \
      "$MATRIX_URL/_matrix/client/v3/login")"; then
    warn "$MATRIX_PASSWORD_FILE doesn't match $MATRIX_USER; signing in through double puppeting instead"
    dp_token="$(awk '/^as_token:/ {print $2}' "$SYNAPSE_DIR/doublepuppet.yaml")"
    resp="$(jq -n --arg user "$MATRIX_USER" '{
        type: "m.login.application_service", identifier: {type: "m.id.user", user: $user},
        device_id: "HEARTH_RELAY", initial_device_display_name: "Hearth relay"}' \
      | curl -fsS --max-time 15 -H 'content-type: application/json' --data-binary @- \
        -H @<(printf 'authorization: Bearer %s\n' "$dp_token") "$MATRIX_URL/_matrix/client/v3/login")" \
      || die "couldn't sign in as $MATRIX_USER"
  fi
  (umask 077 && jq -r '.access_token' <<<"$resp" | tr -d '\n' > "$MATRIX_TOKEN_FILE")
  say "Signed in as $MATRIX_USER; the relay's token is in $MATRIX_TOKEN_FILE"
}
