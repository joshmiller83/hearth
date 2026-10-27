#!/bin/bash
# Build the message bridges and their homeserver at the versions in versions.env.
# No sudo, and safe to rerun (deploy/bridges/update.sh runs it on every update):
#   - Synapse in its own venv (built from source: there are no macOS wheels)
#   - each bridge in $BRIDGES, cloned at its tag and built with Go into $MATRIX_DIR/bin
#   - first time only: the homeserver's config and signing key, the double-puppeting
#     registration, and each bridge's config and appservice registration
#   - every time: hearth.yaml and log.yaml, the homeserver settings this kit owns
# Running daemons keep their old builds until they restart.
source "$(dirname "$0")/lib.sh"

[[ $EUID -ne 0 ]] || die "run without sudo"
[[ -n "$BRIDGES" ]] || die "BRIDGES is empty in deploy/config.env, so there's nothing to build (sudo deploy/bridges/install.sh removes installed bridges)"

need() { command -v "$1" >/dev/null || die "$1 not found: $2"; }
need go "brew install go"
need cargo "brew install rust (Synapse compiles its Rust parts on macOS)"
need jq "brew install jq"
[[ -x "$MATRIX_PYTHON" ]] || die "no Python at $MATRIX_PYTHON: brew install python@3.13, or set MATRIX_PYTHON in deploy/config.env"
"$MATRIX_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || die "Synapse needs Python 3.10 or newer; $MATRIX_PYTHON is $("$MATRIX_PYTHON" --version 2>&1)"

install -d -m 700 "$MATRIX_DIR" "$DATA_DIR/secrets"
install -d "$MATRIX_DIR"/{bin,src,bridges,synapse} "$DATA_DIR"/{logs,backups}

# --- Synapse ---------------------------------------------------------------

installed="$("$SYNAPSE_VENV/bin/python" -c 'import synapse; print(synapse.__version__)' 2>/dev/null || true)"
if [[ "$installed" == "$SYNAPSE_VERSION" ]]; then
  say "Synapse $SYNAPSE_VERSION is installed"
else
  say "Installing Synapse $SYNAPSE_VERSION${installed:+ (was $installed)}; compiling takes a few minutes"
  [[ -x "$SYNAPSE_VENV/bin/python" ]] || "$MATRIX_PYTHON" -m venv "$SYNAPSE_VENV"
  "$SYNAPSE_VENV/bin/pip" install -q --upgrade pip
  "$SYNAPSE_VENV/bin/pip" install -q "matrix-synapse==$SYNAPSE_VERSION"
fi

if [[ ! -f "$SYNAPSE_DIR/homeserver.yaml" ]]; then
  say "Generating the homeserver's config and signing key for $MATRIX_SERVER_NAME"
  (cd "$SYNAPSE_DIR" && "$SYNAPSE_VENV/bin/python" -m synapse.app.homeserver \
    --server-name "$MATRIX_SERVER_NAME" --config-path homeserver.yaml \
    --data-directory "$SYNAPSE_DIR" --generate-config --report-stats=no >/dev/null)
  chmod 600 "$SYNAPSE_DIR/homeserver.yaml"
fi
grep -q "^server_name: \"$MATRIX_SERVER_NAME\"$" "$SYNAPSE_DIR/homeserver.yaml" \
  || die "MATRIX_SERVER_NAME is $MATRIX_SERVER_NAME but the homeserver was made as $(awk '/^server_name:/ {print $2}' "$SYNAPSE_DIR/homeserver.yaml"). It's in every Matrix id, so it can't change; put it back."

# Double puppeting lets the bridges act as @hearth, so what you send from your phone
# shows as you and what you read there marks the room read. No url: it receives nothing.
# https://docs.mau.fi/bridges/general/double-puppeting.html
dp="$SYNAPSE_DIR/doublepuppet.yaml"
if [[ ! -f "$dp" ]]; then
  say "Generating the double-puppeting registration"
  domain_regex="$(printf '%s' "$MATRIX_SERVER_NAME" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  (umask 077 && cat > "$dp" <<EOF
id: doublepuppet
url:
as_token: $(openssl rand -hex 32)
hs_token: $(openssl rand -hex 32)
sender_localpart: $(openssl rand -hex 16)
rate_limited: false
namespaces:
  users:
    - regex: '@.*:$domain_regex'
      exclusive: false
EOF
  )
fi
dp_token="$(awk '/^as_token:/ {print $2}' "$dp")"

cat > "$SYNAPSE_DIR/log.yaml" <<'EOF'
# Written by deploy/bridges/build.sh. Logs go to stdout, which launchd writes to
# logs/matrix.log; the watchdog rotates it with the relay's.
version: 1
formatters:
  plain:
    format: '%(asctime)s %(levelname)s %(name)s: %(message)s'
handlers:
  console:
    class: logging.StreamHandler
    formatter: plain
    stream: ext://sys.stdout
loggers:
  synapse.storage.SQL:
    level: WARNING
root:
  level: INFO
  handlers: [console]
disable_existing_loggers: false
EOF

# --- Bridges ---------------------------------------------------------------

# bridge_config <network>: what Hearth needs from a bridge. On first start the bridge
# fills in every other setting with its default and saves the full, commented file.
bridge_config() {
  local net="$1" port
  port="$(bridge_port "$net")"
  cat <<EOF
homeserver:
  address: $MATRIX_URL
  domain: $MATRIX_SERVER_NAME
appservice:
  address: http://127.0.0.1:$port
  hostname: 127.0.0.1
  port: $port
database:
  type: sqlite3-fk-wal
  uri: file:$(bridge_dir "$net")/$net.db?_txlock=immediate
bridge:
  permissions:
    "$MATRIX_USER": admin
matrix:
  federate_rooms: false
provisioning:
  allow_matrix_auth: true
backfill:
  enabled: true
  max_initial_messages: 50
  max_catchup_messages: 500
double_puppet:
  servers: {}
  allow_discovery: false
  secrets:
    $MATRIX_SERVER_NAME: as_token:$dp_token
encryption:
  allow: false
logging:
  min_level: info
  writers:
    - type: stdout
      format: pretty
EOF
}

registrations=("$dp")
for net in $BRIDGES; do
  repo="$(bridge_repo "$net")"
  binary="$(bridge_binary "$net")"
  version="$(bridge_version "$net")"
  bin="$(bridge_bin "$net")"
  src="$MATRIX_DIR/src/$repo"
  dir="$(bridge_dir "$net")"

  built="$(cat "$bin.version" 2>/dev/null || true)"
  if [[ -x "$bin" && "$built" == "$version" ]]; then
    say "$binary $version is built"
  else
    say "Building $binary $version${built:+ (was $built)}"
    rm -rf "$src"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$version" "https://github.com/mautrix/$repo" "$src"
    # goolm: the pure-Go Olm, so there's no libolm to install (Hearth's rooms aren't encrypted anyway).
    (cd "$src" && "./$(bridge_build_script "$net")" -tags goolm)
    cp "$src/$binary" "$bin.new"
    mv -f "$bin.new" "$bin"
    echo "$version" > "$bin.version"
  fi

  install -d -m 700 "$dir"
  if [[ ! -f "$dir/config.yaml" ]]; then
    say "Writing $net's config"
    (umask 077 && bridge_config "$net" > "$dir/config.yaml")
  fi
  grep -q "^ *address: $MATRIX_URL\$" "$dir/config.yaml" \
    || die "$dir/config.yaml doesn't point at $MATRIX_URL (did MATRIX_PORT change?). Set homeserver.address there to $MATRIX_URL, or put MATRIX_PORT back."
  if [[ ! -f "$dir/registration.yaml" ]]; then
    # Once only: -g makes new tokens each time, and Synapse must have the same ones.
    say "Generating $net's appservice registration"
    (cd "$dir" && "$bin" -c config.yaml -r registration.yaml -g >/dev/null)
  fi
  registrations+=("$dir/registration.yaml")
done

{
  cat <<EOF
# Written by deploy/bridges/build.sh on every run: edit that script, not this file.
# Synapse reads it after homeserver.yaml, so these settings win.

# Only this Mac reaches the homeserver, and only its client API: no federation
# listener, no federation going out, no key servers.
listeners:
  - port: $MATRIX_PORT
    bind_addresses: ['127.0.0.1']
    type: http
    tls: false
    x_forwarded: false
    resources:
      - names: [client]
        compress: false
federation_domain_whitelist: []
trusted_key_servers: []
suppress_key_server_warning: true

# Nobody signs up. The bridges' account is made with the registration secret.
enable_registration: false
report_stats: false
presence:
  enabled: false
url_preview_enabled: false

# Bridged photos and videos nobody has opened for 90 days are deleted.
media_retention:
  local_media_lifetime: 90d

log_config: "$SYNAPSE_DIR/log.yaml"

# The bridges, and double puppeting for them.
app_service_config_files:
EOF
  for reg in "${registrations[@]}"; do printf '  - "%s"\n' "$reg"; done
} > "$SYNAPSE_DIR/hearth.yaml"

say "Built: Synapse $SYNAPSE_VERSION, bridges: $BRIDGES"
[[ -f "/Library/LaunchDaemons/$MATRIX_LABEL.plist" ]] \
  || say "Next: sudo deploy/bridges/install.sh, then deploy/bridges/login.sh <network>"
