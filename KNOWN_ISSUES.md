# Known issues and deferred work

What each milestone left for later. Newest first.

## M5 Ask Hearth

- Ask needs the phone's Claude key (Sources). A question costs a few cents at
  Opus's high effort; follow-ups resend the conversation, mostly from cache.
- The conversation lives in memory and clears when Hearth quits.
- Ask can propose reminders, private holds, Family events, replies (held 30
  seconds so Undo can stop them), notes to copy, and https links. It can't
  RSVP, archive, label or start new emails yet.
- People come from Contacts: name, birthday, anniversary, city and email.
  Contact notes aren't read, because that needs an entitlement Apple grants case
  by case. "Mom" works when a card's Related Names says who that is.
- The trace shows each tool and what it found; Claude's thinking isn't shown.
- Dictation is the keyboard's own microphone.

## M4 Today, brief & push

- The 6:30 brief needs the relay's own Claude key (`ANTHROPIC_KEY_FILE`). Until
  then Today keeps its layout, with needs-you in time order and no kind idea.
- Push needs an APNs auth key (`APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`;
  docs/deploy.md step 8) and "Allow notifications" in Sources. `/v1/health`
  reports `push: false` until both are there.
- Quiet hours (9 PM to 7 AM) hold everything except family and urgent pushes.
  Urgent pushes ask for time-sensitive delivery, but the app doesn't have that
  entitlement yet, so they arrive as ordinary alerts.
- Pushes use the APNs development environment (installs from Xcode). TestFlight
  needs `APNS_ENV=production` and a production `aps-environment`.
- Background refresh is up to iOS. Today catches up when the app opens or a push
  wakes it; the StandBy widgets also fetch events and the brief from the relay
  every 30 minutes on their own.
- "Plan it quietly" opens People, which arrives with M7.

## M3 Mail triage

- Sorting what no rule places needs the relay's own Claude key
  (`ANTHROPIC_KEY_FILE` in deploy/config.env). Until then that mail stays in the
  inbox, marked "Needs a look". The first sort costs about 2¢; after that only
  new mail is sorted.
- Each sweep reads the newest 250 inbox messages per account, plus unopened
  promos older than 90 days.
- Drafts are written when you open a thread; overnight pre-drafting is a later run.
- Holds for offered times stay until you remove them; Hearth doesn't yet clear
  the others when someone picks a time.
- Filing Job hunt adds the account's "job hunt" label (where it has one) and
  archives; the routines repo's daily scan keeps the GitHub issues up to date.
- Rules can be switched on and off in Sources; editing their conditions comes later.
- The design's search and compose buttons aren't there yet.

## M2 Capture

- The share extension only saves what's shared; Hearth reads it with Claude the
  next time it opens (Capture lists it under "Shared with Hearth").
- The mic button opens the keyboard; dictation is the keyboard's own microphone.
- A scanned paper calendar sends its first page.
- "Already on a calendar" matches by day and title words against the merged
  agenda. Planning Center and event feeds join the comparison with M6 and M8.
- `make eval` (live prompt checks on synthetic flyers and notes) needs an
  Anthropic key; it hasn't been run yet.

## M1 Plans

- An RSVP waits 5 seconds (Undo), then goes to the relay as an approved action.
  The relay's cache shows the answer at once; Google sends the organizer's email.
- Organizers show as their address's first part ("office"), because gmailkit
  returns the organizer's email but not their display name.
- The StandBy widgets refresh from the relay every 30 minutes on their own;
  pushes that refresh them come with M4.

## M0 Foundation

- "Ask before acting" is shown as a switch in Sources, but it is always on: the
  relay only runs actions the phone sends after a tap.
- The relay serves Google Calendar only so far; mail arrives with M3.
- Pushes (APNs) arrive with M4; `/v1/health` reports `push: false` until then.
