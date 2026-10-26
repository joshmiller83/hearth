# Known issues and deferred work

What each milestone left for later. Newest first.

## M0 Foundation

- "Ask before acting" is shown as a switch in Sources, but it is always on: the
  relay only runs actions the phone sends after a tap.
- The relay serves Google Calendar only so far; mail arrives with M3.
- Pushes (APNs) arrive with M4; `/v1/health` reports `push: false` until then.
