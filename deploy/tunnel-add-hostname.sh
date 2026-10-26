#!/bin/bash
# Point $PUBLIC_HOSTNAME at the relay through an existing Cloudflare Tunnel. No sudo.
# (If the tunnel is shared with other services, never rerun the script that first
# created it: such scripts rewrite config.yml and drop every rule they didn't write.)
# - adds an ingress rule to $CF_CONFIG just above the catch-all rule (skipped if present)
# - validates the config
# - creates the DNS record with `cloudflared tunnel route dns` (needs ~/.cloudflared/cert.pem)
# The tunnel daemon only reads its config at start, so the script prints the one
# sudo command that restarts it.
source "$(dirname "$0")/lib.sh"

[[ -x "$CLOUDFLARED_BIN" ]] || die "cloudflared not found at $CLOUDFLARED_BIN"
[[ -f "$CF_CONFIG" ]] || die "tunnel config not found: $CF_CONFIG"

if grep -qE "hostname:[[:space:]]*$PUBLIC_HOSTNAME([[:space:]]|$)" "$CF_CONFIG"; then
  say "$PUBLIC_HOSTNAME is already in $CF_CONFIG"
else
  grep -qE '^[[:space:]]*-[[:space:]]*service:[[:space:]]*http_status:404' "$CF_CONFIG" \
    || die "no catch-all 'service: http_status:404' rule in $CF_CONFIG; add the rule by hand"
  cp "$CF_CONFIG" "$CF_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  awk -v host="$PUBLIC_HOSTNAME" -v svc="http://$HOST:$PORT" '
    !done && /^[[:space:]]*-[[:space:]]*service:[[:space:]]*http_status:404/ {
      match($0, /^[[:space:]]*/); pad = substr($0, 1, RLENGTH)
      printf "%s- hostname: %s           # hearth relay\n%s  service: %s\n", pad, host, pad, svc
      done = 1
    }
    { print }
  ' "$CF_CONFIG" > "$tmp"
  mv "$tmp" "$CF_CONFIG"
  say "Added $PUBLIC_HOSTNAME → http://$HOST:$PORT to $CF_CONFIG"
fi

"$CLOUDFLARED_BIN" tunnel --config "$CF_CONFIG" ingress validate
"$CLOUDFLARED_BIN" tunnel --config "$CF_CONFIG" ingress rule "https://$PUBLIC_HOSTNAME/v1/health"

say "Creating the DNS record"
"$CLOUDFLARED_BIN" tunnel route dns "$CF_TUNNEL" "$PUBLIC_HOSTNAME" || warn "route dns failed (it may already exist)"

say "Now restart the tunnel so it reads the new rule:"
echo "    sudo launchctl kickstart -k system/$CF_LABEL"
say "Public DNS can take a minute. Check with DNS over HTTPS (the home router caches misses):"
echo "    curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=$PUBLIC_HOSTNAME&type=CNAME' | jq ."
