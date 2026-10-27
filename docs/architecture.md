# Architecture

## What lives where

**The relay (a Mac at home)** does only what a phone can't do reliably:

1. **Google custody.** gmailkit runs as the relay's child process and the relay
   talks MCP to it over stdio. The refresh tokens stay in gmailkit's encrypted
   bundle; gmailkit never listens on a port. Calls are serialized (gmailkit's
   Google clients aren't thread-safe) and allowlisted (`GmailkitTools`).
2. **The clock.** iOS background refresh is opportunistic, so timed work runs
   here: a 15-minute calendar cache and mail sweep (rules first, Haiku only for
   leftovers), the 6:30 AM brief, signal polling, feed fetches.
3. **Push** through APNs, with quiet hours (family and urgent get through).
4. **The executor** for approved actions, including scheduled sends: Gmail's
   API can't schedule a send, so the relay holds the action until `notBefore`.
5. **Texts.** iOS lets no app read Messages, but the Mac has them. A separate
   helper, `hearth-messages`, runs every two minutes as a LaunchAgent, opens the
   Messages database read-only (the only Hearth process with Full Disk Access)
   and leaves an export the relay serves. Nothing sends a text.

**The phone** does everything else: every screen with an offline cache, EventKit
(iCloud Family, Birthdays) and Contacts, every interactive Claude feature
(capture, drafts, Ask, ideas), the rules editor, approvals with undo, local
notifications, the share extension and the StandBy widgets.

## Trust rules

| Rule | Where it's enforced |
|---|---|
| Ask before acting | `Jobs` can't reach `Executor` (separate modules, `DependencyGraphTests`); `POST /v1/actions` needs `approvedAt` and an idempotency key (`ApprovalPolicy`) |
| Trash, never permanent delete; no file paths | `GmailkitTools` allowlist and forbidden arguments in `GmailkitBridge` |
| Surprise guard | `SurpriseGuard`: surprise plans only on the owner's own accounts |
| Busy-only partner calendar | `BusyOnly.redact`, applied on the relay before events leave it |
| Quiet hours | `QuietHours` |
| Texts are read only, and only the helper opens Messages | `ChatDatabase` opens with `mode=ro`; no route or job imports `ChatReader` (`DependencyGraphTests`); the relay's Claude never gets texts |
| No secrets in git | keys in the iOS Keychain and `~/HearthRelay/secrets`; household details in `~/HearthRelay/household.json` |

## Relay API

All JSON, dates as RFC 3339. Every route needs `Authorization: Bearer <relay key>`
except `GET /v1/health`, which without the key answers only `{"status":"ok"}`.

| Route | Milestone | What |
|---|---|---|
| `GET /v1/health` | M0 | gmailkit state, accounts, household, job runs |
| `GET /v1/calendar/events?from&to[&refresh=1]` | M1 | Every Google calendar from the 15-minute cache |
| `POST /v1/actions`, `GET /v1/actions?ids=`, `DELETE /v1/actions/:id` | M1 | Approved actions (RSVPs, holds, mail changes, replies), their status, cancel |
| `POST /v1/context` | M1 | The phone's switches and Apple calendars, for the jobs |
| `GET /v1/mail/snapshot`, `GET /v1/mail/threads/:account/:id` | M3 | Triage queues, a thread |
| `GET /v1/brief`, `POST /v1/devices` | M4 | The morning brief; the APNs token |
| `POST /v1/tools/gmail_search` | M5 | Ask's mail search, read-only (any other tool name is a 404) |
| `GET /v1/signals[?refresh=1]` | M6 | The weather the relay watches (NWS alerts, the night's low); the phone adds mail-derived signals |
| `GET|POST /v1/feeds`, `DELETE /v1/feeds/:id`, `POST /v1/feeds/preview` | M8 | Event feeds and their kept events; a feed read once for the chat (public https only) |
| `GET /v1/chats`, `GET /v1/chats/thread?id=`, `POST /v1/tools/chats_search` | Texts | Recent conversations and what's waiting on the owner; one conversation; Ask's text search. All from `hearth-messages`' export |

## Claude

Raw HTTPS (`ClaudeClient`), API version 2026-10-21. Opus 5.5 plans, writes and
reads photos; Haiku 5.5 sorts. Structured output via `output_config.format`,
streaming SSE (`ClaudeStreamAccumulator`), an append-only tool loop (`ToolLoop`),
cached system prompts. Transcripts are kept as order-preserving `JSONValue`s so
history goes back exactly as it came (preserved thinking).
