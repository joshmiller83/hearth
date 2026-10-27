#!/bin/bash
# The networks the bridge kit knows. Sourced, not run, and free of side effects, so
# the watchdog (which runs from a copy in /Library/Application Support) can use it too.
# Each name is the bridge's own network id: its bot is @<name>bot, its ghosts @<name>_….

KNOWN_BRIDGES="whatsapp facebook"

# The repo under github.com/mautrix, its build script, the binary it makes, and the
# port the bridge listens on (127.0.0.1 only; the mautrix defaults).
bridge_repo() {
  case "$1" in whatsapp) echo whatsapp ;; facebook) echo meta ;; *) return 1 ;; esac
}
bridge_build_script() {
  case "$1" in whatsapp) echo build.sh ;; facebook) echo build-fb.sh ;; *) return 1 ;; esac
}
bridge_binary() {
  case "$1" in whatsapp) echo mautrix-whatsapp ;; facebook) echo mautrix-meta ;; *) return 1 ;; esac
}
bridge_port() {
  case "$1" in whatsapp) echo 29318 ;; facebook) echo 29319 ;; *) return 1 ;; esac
}
