#!/bin/bash
# Log a bridge in to your account on its network, from the terminal. No sudo.
#   deploy/bridges/login.sh whatsapp           pick QR code or pairing code, then link it in
#                                              WhatsApp: Settings > Linked devices
#   deploy/bridges/login.sh facebook           pick how, e.g. cookies from messenger.com
#   deploy/bridges/login.sh <network> <flow>   skip the question (whatsapp: qr or phone)
# Rerun it whenever a network logs the bridge out (make status shows BAD_CREDENTIALS
# or LOGGED_OUT). The first run also makes @hearth, the Matrix account the bridges work
# for, and the relay's token for it. It drives the bridge's provisioning API on
# 127.0.0.1, the same login a Matrix client would do by chatting with the bridge bot.
source "$(dirname "$0")/lib.sh"

[[ $EUID -ne 0 ]] || die "run without sudo"
net="${1:-}"
flow="${2:-}"
[[ -n "$net" ]] || die "usage: deploy/bridges/login.sh <network> [flow]   (networks: ${BRIDGES:-none in BRIDGES})"
in_bridges "$net" || die "$net isn't in BRIDGES (${BRIDGES:-empty}) in deploy/config.env"

ensure_matrix_account
wait_for_url "$(bridge_url "$net")/_matrix/mau/live" 5 \
  || die "the $net bridge isn't answering. Is it installed? sudo deploy/bridges/install.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -z "$flow" ]]; then
  flows="$(provision "$net" GET /login/flows)"
  count="$(jq '.flows | length' <<<"$flows")"
  if (( count == 1 )); then
    flow="$(jq -r '.flows[0].id' <<<"$flows")"
  else
    echo "How should the $net bridge log in?"
    jq -r '.flows | to_entries[] | "  \(.key + 1). \(.value.name): \(.value.description)"' <<<"$flows"
    read -rp "Choose [1]: " choice
    [[ "${choice:-1}" =~ ^[0-9]+$ ]] || die "not a number: $choice"
    flow="$(jq -r --argjson i "$(( ${choice:-1} - 1 ))" '.flows[$i].id // empty' <<<"$flows")"
    [[ -n "$flow" ]] || die "there's no choice $choice"
  fi
fi

# show_display <step>: what a display_and_wait step wants on screen.
qr_count=0
show_display() {
  local kind data png
  kind="$(jq -r '.display_and_wait.type' <<<"$1")"
  data="$(jq -r '.display_and_wait.data // empty' <<<"$1")"
  case "$kind" in
    qr)
      [[ -x "$work/qr" ]] || swiftc -O -o "$work/qr" "$DEPLOY_DIR/qr.swift" 2>/dev/null \
        || die "couldn't build the QR drawer (deploy/qr.swift)"
      qr_count=$(( qr_count + 1 ))
      png="$work/$net-login-$qr_count.png"
      "$work/qr" "$data" "$png" || die "couldn't draw the QR code"
      open -a Preview "$png"
      say "The QR code is open in Preview. It expires quickly; when it does, a new one opens, so scan the newest."
      ;;
    code | emoji) printf '\n        %s\n\n' "$data" ;;
  esac
}

# rows <jq filter> <json>: one line per item, fields split by \x1f (unlike tabs, empty
# fields survive `read`). The filter makes an array of fields for each item.
rows() {
  jq -r "$1 | map(tostring | gsub(\"[\\n\\u001f]\"; \" \")) | join(\"\\u001f\")" <<<"$2"
}

# answer_fields <step>: ask for each user_input field; prints them as a JSON object.
answer_fields() {
  local answers='{}' id name type description options value
  while IFS=$'\x1f' read -r id name type description options; do
    [[ -n "$description" ]] && printf '  %s\n' "$description" >&2
    [[ -n "$options" ]] && printf '  One of: %s\n' "$options" >&2
    case "$type" in
      password | token) read -rsp "$name: " value </dev/tty && echo >&2 ;;
      *) read -rp "$name: " value </dev/tty ;;
    esac
    answers="$(V="$value" jq -c --arg k "$id" '. + {($k): env.V}' <<<"$answers")"
  done < <(rows '.user_input.fields[] | [.id, .name, .type, (.description // ""), ((.options // []) | join(", "))]' "$1")
  printf '%s' "$answers"
}

# answer_cookies <step>: ask for each cookie the bridge needs; prints a JSON object.
answer_cookies() {
  local answers='{}' id cookie required value
  printf '  Sign in at %s in a browser, open its developer tools (Safari: Develop >\n' "$(jq -r '.cookies.url' <<<"$1")" >&2
  printf '  Show Web Inspector > Storage > Cookies) and copy each value below.\n' >&2
  while IFS=$'\x1f' read -r id cookie required; do
    read -rsp "  cookie $cookie: " value </dev/tty && echo >&2
    if [[ -z "$value" ]]; then
      [[ "$required" == true ]] && die "$cookie is required"
      continue
    fi
    answers="$(V="$value" jq -c --arg k "$id" '. + {($k): env.V}' <<<"$answers")"
  done < <(rows '.cookies.fields[] | [.id, (.sources[0].name // .id), .required]' "$1")
  printf '%s' "$answers"
}

step="$(provision "$net" POST "/login/start/$flow" '{}')"
login_id="$(jq -r '.login_id' <<<"$step")"
while :; do
  type="$(jq -r '.type' <<<"$step")"
  step_id="$(jq -r '.step_id' <<<"$step")"
  instructions="$(jq -r '.instructions // empty' <<<"$step")"
  [[ -n "$instructions" && "$type" != complete ]] && say "$instructions"
  case "$type" in
    display_and_wait)
      show_display "$step"
      step="$(provision "$net" POST "/login/step/$login_id/$step_id/display_and_wait" '{}')"
      ;;
    user_input)
      answers="$(answer_fields "$step")"
      step="$(provision "$net" POST "/login/step/$login_id/$step_id/user_input" "$answers")"
      ;;
    cookies)
      answers="$(answer_cookies "$step")"
      step="$(provision "$net" POST "/login/step/$login_id/$step_id/cookies" "$answers")"
      ;;
    complete)
      say "The $net bridge is logged in. Its chats appear over the next few minutes; make status shows it."
      break
      ;;
    *)
      die "this login wants a $type step, which needs a Matrix client: sign in on this Mac at $MATRIX_URL as $MATRIX_USER (password in $MATRIX_PASSWORD_FILE) and message the bridge bot"
      ;;
  esac
done
