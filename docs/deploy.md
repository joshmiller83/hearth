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

## Every update

```bash
deploy/update.sh
```

It tests, builds, swaps the binary and restarts the relay. No sudo.

## Day to day

- `make status`: daemons, local and public health, the deployed commit vs `main`.
- Logs: `~/HearthRelay/logs/` (relay, backup, watchdog), rotated at 20 MB.
- Backups: `~/HearthRelay/backups/`, nightly, newest 30 kept.
- Keys: `bin/Run list-keys`, `bin/Run revoke-key --id <uuid>`.
- Run a job now: `bin/Run run-job calendar`.

## Notes

- **The home router caches DNS misses.** Check a new hostname with DNS over HTTPS
  (the tunnel script prints the command), not `dig`.
- **FileVault.** After a power cut the Mac waits at the unlock screen; nothing
  starts until someone logs in.
