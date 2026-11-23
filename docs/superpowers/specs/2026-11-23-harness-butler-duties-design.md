# harness butler: emergencies, the diary, people

2026-11-23. The owner, after comparing harness with a real butler: "Go"
for the first three missing duties. The butler spec
(`2026-11-23-harness-butler-design.md`: UX rules, red lines) and the
platform overview bind. The full list of gaps is
`2026-11-23-harness-gaps.md`.

## 1. Emergencies: acting when the owner can't be reached

Today an urgent alert asks with one tap, and no answer means nothing
happens. A butler doesn't let the kitchen flood because the owner is
asleep.

**Acknowledging.** Any tap on an urgent alert's buttons, or a reply to it,
acknowledges it. Unacknowledged alerts escalate and may fall back.

**Escalation.** `[butler] escalate = 5m anna, 15m piotr` (household
members, Part 6): if the owner hasn't acknowledged an urgent alert after
5 minutes, Anna gets it in her chat with the bot ("Nobody has answered
this yet: Water under the kitchen sink." [I'm on it]); after 15, Piotr;
the house speakers say it again at each step. A member's "I'm on it"
acknowledges it for everyone (the owner is told who). Members still
can't approve anything guarded. A trigger or workflow may set its own
`escalate`; `escalate = no` turns it off.

**Safe-direction fallback.** An `approve` step with `yes` may say
`fallback 5m`: if its trigger or workflow is urgent and nobody has
acknowledged after 5 minutes, harness makes the step's call itself, once,
and says so ("No one answered in 5 minutes: I closed the water main. It
reports closed."). Only safe directions: lock, close, arm (homemcp's
`home_guarded` with those actions; the step's input is fixed, as for
`yes`); a fallback on anything else is a bad line when the file is read.
Opt-in per routine; the setup offers it for the leak routine
("…and if nobody answers in 5 minutes, I close it myself" [Turn on]
[Not now]). Logged as the owner's absence, with the alert, the times and
the call. The red lines hold: never unlock, open or disarm unattended.

**Smoke and CO.** homemcp keeps smoke and CO detectors as watched only:
discover lists them (today it leaves them out), they push their state,
and no tool acts on them (a home file line that tries is refused). A
routine `smoke` (urgent): the alert, the announcement in every room,
escalation; no fallback (nothing to close). Cameras stay out.

## 2. The diary: a calendar

**calmcp**, a new MCP server beside homemcp and carcloud (Zig, std only,
macOS/Linux/Windows, its own stand-in `calmcp-sim`): CalDAV (iCloud,
Fastmail, Nextcloud, and Google through CalDAV with an OAuth token) with a
calendar file listing which calendars it reads and which it may change.
Tools: `cal_agenda` (from, to), `cal_free` (a slot of a length between
two times), `cal_event` (one, with attendees and place); writes as their
own tools — `cal_create`, `cal_move`, `cal_cancel`, `cal_reply` (RSVP) —
each asked every time in harness (setup marks them so), never from a
schedule. Times in the owner's zone; recurring events expanded; read back
after a write. Microsoft 365 (no CalDAV) comes later.

**In harness**, with the calendar connected (`/setup calendar`):
- the morning summary lists today's events;
- **leave-by**: for an event with a place, a line at the time to leave
  (`[butler] travel = 30m` by default; a maps MCP server's travel time
  when one is set);
- **before a meeting** (30 minutes, events with people): who, where, what
  was said with them last (long memory, `history`), links in the event;
- **busy means quiet**: during an event marked busy, posts wait as in
  quiet hours (urgent ones don't);
- asked by the owner ("move the dentist to Friday"), harness proposes
  the change and the gate asks before it is made.

## 3. People

`state/people/` holds a short file per person the owner deals with: name
and how the owner calls them, relation, birthday and other dates,
preferences ("allergic to nuts", "likes Polish poetry"), how to reach
them, and when the owner last mentioned being in touch. Filled from what
the owner says (the memory writer recognises people), from the calendar's
attendees, and from a contacts file (`harness people import FILE.vcf`).
A `people` tool (find, show, note) in the owner's own conversations only;
members and speech never see it; private conversations add nothing.

- **Occasions**: a week before a birthday or anniversary, a line with a
  gift idea from the person's preferences (search, not bought); on the
  day, a reminder.
- **Keeping in touch**: `keep in touch = 3 months` on a person: a gentle
  line when that much time has passed since the owner last mentioned them
  (no inbox or phone is read for it).
- `/people`, `/person NAME`, `harness people list|show|import`.

## Tests

- Emergencies: escalation in order with acknowledgement stopping it; a
  member's "I'm on it"; the fallback making a safe call once after the
  time and saying so; a fallback on unlock refused when read; smoke
  watched and never acted on; nothing escalates for non-urgent alerts.
- calmcp: agenda across a recurrence and a time zone; a write read back;
  writes asked in harness; calmcp-sim playing CalDAV.
- Diary: leave-by and meeting preparation at the right minute (fake
  clock); a busy event holding a post; a move proposed and asked.
- People: facts recognised from conversation; vCard import; a birthday's
  two lines; keep-in-touch; members can't see people.

## Calls I made (the owner can change them)

- Escalation and fallback are opt-in; fallback only for close, lock, arm.
- Calendar writes are always asked; harness never accepts or declines an
  invitation on its own.
- People are filled from what the owner says, the calendar and a contacts
  file; nothing reads the owner's mail or phone for it (email is Q1).
