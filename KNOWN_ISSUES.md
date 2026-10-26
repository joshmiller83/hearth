# Known issues and deferred work

What each milestone left for later. Newest first.

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
