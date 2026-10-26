#!/bin/bash
# Runs a relay command by hand with the daemon's settings. No sudo. For example:
#   deploy/run.sh brief          write today's brief now; the relay pushes it
#   deploy/run.sh push-test      a test push to every registered phone
#   deploy/run.sh run-job mail   a mail sweep now
#   deploy/run.sh list-keys
source "$(dirname "$0")/lib.sh"

[[ $# -gt 0 ]] || die "usage: deploy/run.sh <command> [options]  (brief, push-test, run-job <name>, list-keys, …)"
[[ -x "$BIN" ]] || die "$BIN missing; run deploy/build.sh first"
relay_env
cd "$DATA_DIR"
exec "$BIN" "$@"
