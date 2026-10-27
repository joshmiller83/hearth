# Running the relay on a Mac

The relay is one native binary and one SQLite file. It runs as a launchd system
daemon (it starts at boot without anyone logging in), starts gmailkit as its
child, and is published through an existing Cloudflare Tunnel, so nothing
listens on the open internet.

```
iPhone ──https──▶ Cloudflare ──tunnel──▶ cloudflared ──▶ 127.0.0.1:8791 ──▶ relay ──stdio──▶ gmailkit
```

## First time

1. **gmailkit.** Clone it next to this repo and give it a venv:
   ```bash
   git clone https://github.com/<you>/gmail ~/Developer/gh/gmail
   cd ~/Developer/gh/gmail && python3 -m venv .venv && .venv/bin/pip install -e .
   ```
   gmailkit finds its master key in `$GMAIL_MASTER_KEY`, the login Keychain, or
   a private gist through `gh`. A launchd daemon has no unlocked Keychain, so on
   the relay's Mac it uses the gist: make sure `gh auth status` works for the
   service user.
2. **Settings.** Copy `deploy/config.env.example` to `deploy/config.env`, and
   `deploy/household.example.json` to `~/HearthRelay/household.json`. Fill both
   in. Neither is in git.
3. **Build** (no sudo). This runs the relay's tests first.
   ```bash
   deploy/build.sh
   ```
4. **Install the daemons**: the relay, a 3:25 AM backup and a watchdog. Needs sudo.
   ```bash
   sudo deploy/install-services.sh
   ```
5. **Publish it** through your tunnel. This adds the ingress rule above the 404
   rule and the DNS record, then prints the sudo command that restarts
   cloudflared (which blips every hostname on that tunnel for a moment).
   ```bash
   deploy/tunnel-add-hostname.sh
   ```
6. **Make a key for the phone** and paste it into Hearth's Sources screen:
   ```bash
   ~/HearthRelay/bin/Run issue-key --label iPhone
   ```
7. **Check it** end to end:
   ```bash
   HEARTH_KEY=hrk_… deploy/smoke.sh
   ```
8. **Optional: the morning brief and push.**
   - The relay's own Anthropic key (not the phone's; give it a monthly spend
     limit in the Console), in a file only the service user can read, named by
     `ANTHROPIC_KEY_FILE`. Without it there's no 6:30 brief, and mail the rules
     can't place waits in "Needs you" unsorted.
   - An APNs auth key: developer.apple.com → Keys → +, tick Apple Push
     Notifications service, and download the `.p8` (you can only download it
     once). Save it as `~/HearthRelay/secrets/apns.p8` (mode 600), and set
     `APNS_KEY_FILE`, `APNS_KEY_ID` (shown beside the key) and `APNS_TEAM_ID`.

   Rerun `sudo deploy/install-services.sh` so the daemon picks them up, allow
   notifications in Hearth's Sources screen, then:
   ```bash
   deploy/run.sh push-test
   deploy/run.sh brief
   ```

9. **Optional: texts (iMessage and SMS).** Messages must be signed in on this
   Mac (and Text Message Forwarding on for SMS). As yourself, no sudo:
   ```bash
   deploy/install-messages.sh
   ```
   It builds `hearth-messages`, signs it with your Developer ID (the first time,
   macOS may ask to let codesign use the key: Always Allow), and runs it every
   two minutes as a LaunchAgent. Then grant it Full Disk Access once: System
   Settings › Privacy & Security › Full Disk Access › +, press ⌘⇧G, enter
   `~/HearthRelay/bin/hearth-messages`, and switch it on. Within two minutes
   Sources shows "Reading". It only reads; the export stays in
   `~/HearthRelay/data` and isn't backed up. Rerun the script after changes to
   `Relay/Sources/ChatReader` or `MessagesExport`; `--remove` takes it out.

## Every update

```bash
deploy/update.sh
```

It tests, builds, swaps the binary and restarts the relay. No sudo.

## Day to day

- `make status`: daemons, local and public health, the deployed commit vs `main`.
- Logs: `~/HearthRelay/logs/` (relay, backup, watchdog), rotated at 20 MB.
- Backups: `~/HearthRelay/backups/`, nightly, newest 30 kept.
- Keys: `deploy/run.sh list-keys`, `deploy/run.sh revoke-key --id <uuid>`.
- Run a job now: `deploy/run.sh run-job calendar` (or `mail`, `brief`).

## Notes

- **The home router caches DNS misses.** Check a new hostname with DNS over HTTPS
  (the tunnel script prints the command), not `dig`.
- **FileVault.** After a power cut the Mac waits at the unlock screen; nothing
  starts until someone logs in.
