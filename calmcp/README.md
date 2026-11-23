# calmcp

Your calendars as a few named tools for an AI agent, over MCP on stdio. It
reads CalDAV calendars (iCloud, Fastmail, Nextcloud, and Google with an
OAuth token) and, only in the calendars its file allows, creates, moves and
cancels events and answers invitations. Each change has to name the event as
the calendar has it, is sent only if the event hasn't changed meanwhile, and
is read back.

```
agent ──MCP, stdio──▶ calmcp ──https, CalDAV──▶ iCloud · Fastmail · Nextcloud · Google
          calendars it may change, the event named, ETags, read back, log
```

macOS, Linux and Windows. One binary, nothing beyond the Zig standard
library (and libc on macOS). Microsoft 365 has no CalDAV and isn't covered.

**State: 0.1.0, written from the CalDAV, iCalendar and scheduling RFCs
(4791, 5545, 6638) and tested only against `calmcp-sim`, a stand-in built
from the same RFCs.** It has never talked to iCloud, Fastmail, Nextcloud or
Google. The tests pass on macOS; CI runs them on Linux and Windows. See
[Limits](#limits).

## Quick start, without an account

`calmcp-sim` is built alongside calmcp. It plays a CalDAV server with a
made-up owner's calendars: a dentist at 10:30, a weekly team call, a call in
New York's time, a monthly review, a birthday.

```
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/calmcp-sim 8742 owner not-a-real-password &
$ CALDAV_PASSWORD=not-a-real-password ./zig-out/bin/calmcp check examples/sim.ini
The calendars of owner at http://127.0.0.1:8742, times in Europe/Warsaw:
Personal: calmcp may change it
Work: calmcp may change it
Birthdays: read only
Next: Mon 23 Nov 2026 10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków
Changes calmcp may make, each asked about first: cal_create, cal_move, cal_cancel, cal_reply.
```

`calmcp examples/sim.ini` then serves MCP on stdin and stdout, the way an
agent starts it.

## Tools

| Tool | What it does |
|---|---|
| `cal_agenda` | The events from `from` to `to` (default: today), every calendar or one, in your time zone, recurring events expanded. Each line ends with the event's id. At most 62 days. Only reads. |
| `cal_free` | Free time of at least `minutes` between two times. Events shown as free, declined or cancelled don't count. Only reads. |
| `cal_event` | One event in full: when (and in its own time zone), where, the organizer, the people and their answers, links, notes, how it repeats, and whether calmcp may change it. Only reads. |
| `cal_create` | A new event in a calendar calmcp may change. |
| `cal_move` | One of your own events (or one time of a recurring one) to a new start. |
| `cal_cancel` | One of your own events, or one time of a recurring one; never a whole series. |
| `cal_reply` | Your answer to an invitation: accepted, declined or tentative. |

The four changes exist only when some calendar has `change = yes`. Each
carries `_meta["anthropic/requiresUserInteraction"]: true`, so clients that
honour it ask a person every time.

```
> cal_agenda {}
Mon 23 Nov 2026 (Europe/Warsaw):
09:00–09:30 Team call; Video call; with Piotr Nowak and Ewa Lis; every week on Monday [work/team-call@calmcp-sim#20261123T080000Z]
10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków [personal/dentist-1@calmcp-sim]
13:00–14:00 Focus time (shown as free) [personal/focus@calmcp-sim]
15:00–16:00 Call with the New York office (09:00–10:00 New York time); with Sam Lee; Sam Lee's invitation, not answered [work/ny-call@calmcp-sim]
> cal_move {"id": "personal/dentist-1@calmcp-sim", "title": "Dentist", "from": "2026-11-23 10:30", "to": "2026-11-27"}
Moved: Dentist is now Fri 27 Nov 2026 10:30–11:30 (was Mon 23 Nov 10:30). Read back from the calendar.
> cal_move {"id": "personal/dentist-1@calmcp-sim", "title": "Dentist appointment", "from": "2026-11-27 10:30", "to": "2026-11-30"}
Not changed: personal/dentist-1@calmcp-sim is "Dentist", not "Dentist appointment". Read it with cal_event first.
```

Times are written in your time zone (`2026-11-23 10:30`), or with an offset
(`…+01:00`, `…Z`); `today` and `tomorrow` work too. A move to a date alone
keeps the time of day.

The resource `cal://upcoming` is today's and tomorrow's events as JSON (when,
busy or free, place, people, links), for programs such as harness. Like the
tool texts, it is marked as data, not instructions.

## The calendar file

An INI file. `calmcp discover` writes one (below). Relative paths are
relative to it.

```ini
[account]
url = https://caldav.fastmail.com    ; the server
user = anna@fastmail.com
auth = password                      ; CALDAV_PASSWORD: an app password
zone = Europe/Warsaw                 ; your time zone
email = anna@fastmail.com            ; your address in invitations (cal_reply)
writes_per_day = 20                  ; at most this many changes in any 24 hours
log = calmcp.jsonl                   ; optional: one line per change

[calendar personal]
url = /dav/calendars/user/anna@fastmail.com/Default/
name = Personal
change = yes                         ; calmcp may change it (default: no, read only)

[calendar holidays]
url = /dav/calendars/user/anna@fastmail.com/holidays/
name = Holidays
```

For Google: `auth = token` with `CALDAV_TOKEN` (an OAuth access token), or,
so calmcp renews it itself, `token_url = https://oauth2.googleapis.com/token`,
`client_id = …`, and `CALDAV_REFRESH_TOKEN` and `CALDAV_CLIENT_SECRET` in
the environment.

`calmcp check` names a zone it doesn't know, a password or token the server
refuses, a calendar address that isn't a calendar, and a calendar marked
`change = yes` that the server doesn't let this account write.

### calmcp discover

```
$ CALDAV_PASSWORD=APP-PASSWORD calmcp discover https://caldav.fastmail.com anna@fastmail.com > calendar.ini
Found 3 calendars: Personal (may change), Work, Holidays (read only).
```

It follows the server's own directions (`/.well-known/caldav`, your
principal, your calendar home) and lists every calendar of events. The
server's calendar for new events gets `change = yes`; the others, and any
the server won't let you write, are read only. Task lists are left out.

| Service | Address | Password |
|---|---|---|
| iCloud | `https://caldav.icloud.com` | an app-specific password (Apple ID, Sign-In and Security) |
| Fastmail | `https://caldav.fastmail.com` | an app password with calendar access |
| Nextcloud | `https://HOST/remote.php/dav` | an app password (Settings, Security) |
| Google | `https://apidata.googleusercontent.com/caldav/v2/` | an OAuth token (see above), `auth = token` |

## What the agent can't do

- **Change a calendar the file doesn't allow.** Only `change = yes`
  calendars take changes; the write tools don't exist when none does.
- **Change an event it hasn't named exactly.** `cal_move` and `cal_cancel`
  name the event's id, its title and its start now; `cal_reply` its id and
  title. calmcp compares them with the calendar before writing anything. The
  person who is asked sees what will change in plain fields.
- **Overwrite a change made meanwhile.** Every change is sent with the
  event's ETag (`If-Match`); a new event only if it is new
  (`If-None-Match: *`). If someone changed it in between, nothing is
  written.
- **Move or cancel someone else's invitation.** Only the organizer can. The
  owner answers it with `cal_reply`, and the server sends the organizer the
  answer.
- **Cancel a whole series.** A change to a recurring event touches one time
  of it: a move adds an exception (`RECURRENCE-ID`), a cancel an `EXDATE`.
- **Make more than `writes_per_day` changes in 24 hours.**
- **Act off the record.** With `log =`, every change is one JSON line, the
  refused ones too:

  ```json
  {"time":"20261123T070000Z","tool":"cal_move","calendar":"personal","id":"personal/dentist-1@calmcp-sim","title":"Dentist appointment","result":"refused","message":"Not changed: personal/dentist-1@calmcp-sim is \"Dentist\", not \"Dentist appointment\". Read it with cal_event first."}
  ```

## Time zones and repeats

- An event's time is read in its own zone: the `VTIMEZONE` in the event
  first, then calmcp's table of current rules for about 110 IANA zones and
  the Windows names Outlook writes. A zone it knows neither way is read as
  yours, and the event says so.
- Times are shown in your zone, with the event's own time beside them when
  it differs ("15:00–16:00 (09:00–10:00 New York time)").
- Repeats are expanded in the event's own wall clock, so a weekly 09:00
  stays 09:00 when summer time starts or ends: DAILY, WEEKLY, MONTHLY and
  YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (also "the second Tuesday",
  "the last Friday"), BYMONTHDAY, BYMONTH, RDATE, EXDATE and exceptions.
  Rarer rules (BYSETPOS, BYWEEKNO, BYYEARDAY, BYHOUR, hourly) show their
  first time only, marked "repeats in a way calmcp doesn't expand".
- A moved event keeps its zone (`DTSTART;TZID=…`); a new one is written in
  UTC.

## With harness

`/setup calendar` in harness writes the file and this section of `mcp.ini`,
with the changes as money tools: asked every time, never granted for a day,
never given to helpers, never run from a schedule.

```ini
[calendar]
command = /usr/local/bin/calmcp /path/to/calendar.ini
; stored with `harness secret add caldav`
secret = CALDAV_PASSWORD:caldav
money = cal_create, cal_move, cal_cancel, cal_reply
amount = cal_create:none, cal_move:none, cal_cancel:none, cal_reply:none
```

In Claude Code: `claude mcp add --env CALDAV_PASSWORD=... calendar -- calmcp
/path/to/calendar.ini`. That stores the password in Claude Code's settings.

## Building and testing

Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/calmcp and calmcp-sim
zig build test                       # unit tests, then scripts/smoke.sh
```

The unit tests run the CalDAV client against `calmcp-sim` in the same
process: discovery, ETags, a read-only calendar, a token renewed. 
`scripts/smoke.sh` runs the binary over MCP against `calmcp-sim`: the day in
your zone, a weekly call across the October change, free time, a refused
change that writes nothing, a move read back, an invitation answered, one
time of a series cancelled, a bearer token renewed, the log. It needs
python3, and runs under Git Bash on Windows.

## Limits

- Tested only against `calmcp-sim`, which follows the RFCs and could share
  calmcp's reading of them.
- One account per calendar file; a second account is a second calmcp.
- Zones: the current rules only. An event in a past year whose rules differed
  (before 2007 in the US, say) can be an hour off unless its `VTIMEZONE` says
  otherwise.
- No new recurring events, no moving a whole series, no attendees added.
- A Google refresh token is obtained once by hand (an OAuth client of your
  own, scope `https://www.googleapis.com/auth/calendar`).
- `cal_reply` changes your copy; a server without CalDAV scheduling (RFC
  6638) doesn't send the organizer anything.
- Microsoft 365 (no CalDAV).

## License

MIT, see [LICENSE](LICENSE).
