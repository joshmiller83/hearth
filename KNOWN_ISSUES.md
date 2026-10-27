# Known issues and deferred work

What each milestone left for later. Newest first.

## Leaving mail out, and the queue button

- Leaving a message out is remembered on the phone and sent to the relay with
  the phone's context, so the brief skips it. The relay's sweep still sorts it
  into its queue; the phone keeps it out. A left-out message is forgotten once
  it leaves the inbox.
- Calendar invitation emails go to Reply by rule. Their RSVP happens in Plans,
  so the email can linger after you answer. Leave it out, or Archive them.
- Around town: "Not for us" is on the featured card. On the list it's a long
  press (or a VoiceOver action). Hidden events come back with Show them.

## M8 Around town, event feeds & Facebook

- Calendar feeds are fetched every 6 hours. Pages and weekly emails without a
  feed are read by the relay's Claude on Mondays, so they need the relay's
  Anthropic key. Each feed keeps events by the skip words Claude suggested when
  it was added.
- The relay fetches only public https addresses: no names on your network, no
  bare IP addresses, no ports other than 443.
- The feed chat uses Claude's own web search and fetch, which cost a little on
  top of the model.
- Repeats: daily, weekly (by weekday) and monthly (same date) are expanded;
  other repeats show their first date, and exceptions (EXDATE) aren't removed.
- "For you two" means an evening after 5 or a weekend with nothing on anyone's
  calendar then (your partner's as busy only). The featured card is this
  weekend's first event that fits.
- Facebook comes in through its notification emails, shares and screenshots,
  and feeds. Your rules keep emails by phrases in their subjects and archive
  the rest. Add to Family reads an email the way Capture reads a note, and
  there's no Open in Facebook yet.

## M7 People & the partner planner

- The inner circle lives on the phone. Add people by searching Contacts; remove
  them with a long press. Birthdays and anniversaries come from each contact
  card, plus anything on the Birthdays calendar.
- Ideas ask Claude once a day (a few cents), from one mail search across the
  circle's addresses over the last 45 days and your free time. Pull to refresh
  asks again.
- The planner holds the evening on your main account. With the surprise guard
  on, the hold is private and carries Hearth's surprise marker, so StandBy shows
  it as "Private". Your partner's calendars are never written.
- Flowers and the card are ticked by hand; Hearth doesn't order anything yet.
- "Things they love" is only what you add: contact notes need an entitlement
  Apple grants case by case.
- "A little thing this week" shows when your partner has three or more things on
  one day.
- Life events like "started a new job" appear only as Claude's ideas, not as
  their own Coming up rows.

## M6 Signals

- Signals come from the mail sweep: GitHub notification emails (so "via home"),
  Planning Center's scheduling emails, Facebook, carriers and family. There are
  no GitHub or Planning Center API tokens yet, so Planning Center's Accept and
  Decline happen in its email or app, and Mark read archives GitHub's emails
  rather than touching GitHub itself.
- Family means mail Claude tagged Family, or from Mom, Dad and the like, or
  from your partner by name. Church means a sender with "church" in the address,
  or Planning Center.
- The relay checks the National Weather Service every 30 minutes, for alerts
  and the coming night's low. Severe and extreme alerts push once, even in
  quiet hours. Home's point is rounded to about a kilometer.
- Facebook events get Read, not the design's Add to Family; reading events
  comes with M8.
- "Nothing late" for shipping means no delay words in the subject.

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
