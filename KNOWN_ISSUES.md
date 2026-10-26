# Known issues and deferred work

What each milestone left for later. Newest first.

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
