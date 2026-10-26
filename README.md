# Hearth

A communication hub for one household, on one iPhone. Hearth sweeps every Gmail
inbox and calendar, merges Google and iCloud plans, turns flyers, paper
calendars and quick notes into events, sorts mail into queues that wait for your
OK, drafts replies with Claude, nudges you about the people you love, and
answers questions across all of it. It acts only after a tap.

Most of Hearth lives on the phone. A small relay on a Mac at home does the four
things a phone can't do reliably: hold the Google tokens (through
[gmailkit](https://github.com/joshmiller83/gmailkit), as a local child process),
keep time (15-minute sweeps, a 6:30 AM brief), send pushes, and run approved
actions, including scheduled sends.

```
iPhone · Hearth ──HTTPS + relay key──▶ Cloudflare Tunnel ──▶ Mac :8791 hearth-relay ──▶ gmailkit ──▶ Gmail, Google Calendar
   ├─▶ Claude API (capture, drafts, Ask)                         └─▶ Claude API (brief, sorting), APNs
   └─▶ EventKit, Contacts, Reminders, StandBy widgets
```

It's built for an audience of one, so there are no accounts, no App Store build
and no multi-user anything. It's public because there's nothing secret in it:
fixtures are fictional, and keys, tokens and real names stay on the devices.

## Layout

| Path | What |
|---|---|
| `Packages/HearthKit` | Shared Swift (Linux-safe): model, agenda merge, mail rules, policies, relay API, Claude client |
| `Relay` | The Mac relay: Vapor + SQLite, gmailkit bridge, jobs, approved-action executor |
| `iOS` | The app (XcodeGen `project.yml`), `HearthCore`, StandBy widgets, share extension |
| `deploy` | launchd daemons, tunnel hostname, smoke test |
| `docs` | Architecture, deploy notes, design map |

## Building

- Xcode 26.3 or newer, XcodeGen (`brew install xcodegen`).
- `cp iOS/Config/Local.xcconfig.example iOS/Config/Local.xcconfig`, set your team.
- `make test` for the packages, `make build` for the app, `make install-phone` to
  put it on your iPhone.
- The relay: see [docs/deploy.md](docs/deploy.md).

## License

MIT. Bricolage Grotesque and Figtree are under the SIL Open Font License; their
license files sit next to the fonts.
