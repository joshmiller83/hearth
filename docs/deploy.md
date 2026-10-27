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

## WhatsApp and Messenger (optional)

WhatsApp and Facebook Messenger have no API for a personal account, so the Mac
runs the open-source bridges Beeper maintains ([mautrix](https://github.com/mautrix)),
which sign in as a linked device, and a private Matrix homeserver
([Synapse](https://github.com/element-hq/synapse)) for them to talk to. Each chat
becomes a room there. Every two minutes the relay reads the rooms (read only,
like texts) and serves them with the texts, so they show up in Texts, Today's
"Needs you" and Ask. Everything listens on 127.0.0.1 only, the homeserver
doesn't federate, and the rooms aren't encrypted. iMessage and SMS come in
through texts (step 9 above), not a bridge.

```
WhatsApp ◀──▶ mautrix-whatsapp 127.0.0.1:29318 ──┐
Messenger ◀──▶ mautrix-meta    127.0.0.1:29319 ──┴──▶ Synapse 127.0.0.1:8008 ◀──/sync── relay ──▶ Texts
```

### First time

1. **Tools**: `brew install go rust python@3.13`. Go builds the bridges; Synapse
   has no macOS wheels, so pip compiles its Rust parts.
2. **Settings**: in `deploy/config.env`, set `BRIDGES="whatsapp facebook"` (either
   or both) and check `MATRIX_PYTHON`. `MATRIX_SERVER_NAME` can't change later.
3. **Build** (no sudo; the first run compiles everything, so give it a while):
   ```bash
   deploy/bridges/build.sh
   ```
4. **Install the daemons**: Synapse, one per bridge, and a 3:35 AM backup. It
   also restarts the relay so it reads them. Needs sudo.
   ```bash
   sudo deploy/bridges/install.sh
   ```
5. **Log in**, once per network (no sudo):
   ```bash
   deploy/bridges/login.sh whatsapp   # QR code, or a pairing code typed into Linked devices
   deploy/bridges/login.sh facebook   # e.g. cookies copied from messenger.com
   ```
   The first run makes `@hearth:<server name>`, the account the bridges work for,
   and saves its password and the relay's token in `~/HearthRelay/secrets`.
6. **Check it**: within two minutes Sources on the phone shows each network as
   "Reading" and Texts has its chats. `make status` lists each bridge and its login.

### Keeping them current

The bridges release monthly, mid-month ([mau.fi/blog](https://mau.fi/blog)), and
are pinned in `deploy/bridges/versions.env` along with Synapse. Read the release
post, bump the version in a commit, then on the Mac:

```bash
make bridges        # deploy/bridges/update.sh: build, restart, check
```

Don't skip a month: some releases migrate data the next one expects. Bump Synapse
in the same pass, or sooner for a security release.

### When a bridge stops

- **Signed out.** WhatsApp unlinks devices after the phone has been off for 14
  days, and Meta signs sessions out now and then. Sources shows "Sign in" with
  the command, that network's chats leave Texts, and `make status` shows
  `BAD_CREDENTIALS` or `LOGGED_OUT`. Run `deploy/bridges/login.sh <network>` again.
- **Broken by the network.** Meta changes break mautrix-meta a few times a year.
  The fix arrives upstream; bump the version and `make bridges`.
- **Logs**: `~/HearthRelay/logs/matrix.log` and `bridge-<network>.log`, rotated
  with the relay's. The relay logs each read as `bridges:` in `relay.log`.
- **Backups**: `~/HearthRelay/backups/matrix-*.tar.gz`, nightly, newest 30, mode
  600. They hold the databases, the homeserver's signing key and the bridges'
  sessions, but not media.
- **Looking at the rooms**: sign in to any Matrix client on the Mac at
  `http://127.0.0.1:8008` as `@hearth`, with the password in
  `~/HearthRelay/secrets/matrix-password`.
- **Dropping a network**: take it out of `BRIDGES`, then rerun `build.sh` and
  `sudo deploy/bridges/install.sh`. With `BRIDGES` empty, `install.sh` alone
  removes Synapse and every bridge daemon, and the relay stops reading them. The
  data stays in `~/HearthRelay/matrix`.

## Notes

- **The home router caches DNS misses.** Check a new hostname with DNS over HTTPS
  (the tunnel script prints the command), not `dig`.
- **FileVault.** After a power cut the Mac waits at the unlock screen; nothing
  starts until someone logs in.
