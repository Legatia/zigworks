# harness: what is not built yet (2026-11-23)

Everything specced through 2026-11-23 is built and green in CI on Linux,
macOS and Windows (dcc2742): the platform gaps, the "close ones", the
butler's Parts 1–9. The butler's duties (emergencies, the diary, people)
and email are built and merged on harness-logins (2026-11-23), and so
are the household duties (away and travel, the door, errands, upkeep,
health, habits, the car's heating, the evening; 2026-11-24), not yet
pushed. This file lists what is not, in one place, with what each waits
on. Update it when something lands.

## Waiting on the owner's answers

| Gap | Question | Built meanwhile |
|---|---|---|
| Email | answered 2026-11-23: A (its own address) and C (your mailbox read-only + drafts, opt-in) | **built**: mailmcp, conversation `email`, `/setup mail`, `/setup mail mine` |
| Money from automation | Q2: may runs started by triggers, workflows, apps move money | built off: `[money] triggers/workflows/apps = off`; tool steps asked every time |
| Default environment for unattended runs | Q3: host or sandbox | host |
| Apps opened from the phone | Q4: a TLS front (tailscale serve) or loopback only | loopback only |
| Hosted version | five questions in the hosted design (VMs, EU, one balance, support access, home connector) | design only |
| Messages to other people (WhatsApp, Signal, SMS) | Q5: which channel (WhatsApp has no personal API; Signal through signal-cli; SMS through a provider) | email only |
| Releases | tag one | release.yml for harness, homemcp, carcloud; nothing tagged |

## The butler, against a real one (Alfred)

| Duty | Status | Gap |
|---|---|---|
| Acting when the owner can't be reached | **built 2026-11-23** | — (escalation, the opt-in safe-direction fallback, smoke and CO watched) |
| Diary | **built 2026-11-23** | — (calmcp; agenda, leave-by, meeting preparation with what harness knows of the people, busy means quiet, changes asked) |
| People and occasions | **built 2026-11-23** | — (state/people, the people tool, occasions, keeping in touch, vCard import, calendar attendees) |
| Post and messages | email built (A and C) | messages to others on the owner's behalf through other channels (asked every time) |
| The door | **built 2026-11-24** | — (homemcp's doorbells, the Doorbell routine: who is there, the parcel the deliveries expect, urgent while away, [Unlock the door] only for a lock you let unlock) |
| Away and travel | **built 2026-11-24** | — (away mode: lived-in lights, doors urgent, the 20:00 line, the heating; trips from the calendar and travel mail, check-in, the airport's leave-by, the evening before, flight status only from a source) |
| Errands | **built 2026-11-24** | pay-per-call services (pay.sh, x402); a shop's website with a login (lists, reorders on the owner's tap, deliveries built) |
| Habits | **built 2026-11-24** | — (one suggestion a week from the owner's own home_set calls, written only on Yes) |
| House upkeep | **built 2026-11-24** | manuals remembered (service dates by time and the car's distance, documents and warranties built) |
| Health | **built 2026-11-24** | wearable data (medication reminders with Taken, bedtime built) |
| Manner | **built 2026-11-24** | — (the butler preset, the evening message) |
| The car | partly | BMW CarData; an in-car box (research only); warming a Tesla built (carcloud through tesla-http-proxy, the warm-car routine) |
| Phone calls | not specced | calling on the owner's behalf |

## Platform pieces not finished

- **Apps (gap 8)**: the app server serves approved apps; their API (reads,
  acts, runs as `app:NAME`), `app_draft`/`app_save` and the review page,
  versions and forks, and the question bar are the Windows session's next
  item.
- **Hermes differentiators** (from the comparison): prompt-injection checks
  in the smoke script and a demo of the gate holding (built 2026-11-24:
  spec 2026-11-24-harness-injection-checks-design.md, plan
  2026-11-24-injection-checks.md); import of a Hermes setup and
  agentskills.io skills (built, below); the gate as an MCP proxy for
  other agents (open).
- ~~Import of a Hermes setup and agentskills.io skills~~ **built
  (2026-11-24, platform/hermes-import)**: `harness import hermes` (memory,
  SOUL.md, skills, cron jobs, MCP servers, deny rules, the model; a plan
  first, no key copied) and `harness skill add|list|show|update|rm`
  (folders, GitHub repos, SKILL.md links). Plan
  `docs/superpowers/plans/2026-11-24-hermes-import.md`.
- **`utc_offset` doesn't follow daylight saving** (found by the Hermes
  import, 2026-11-24): harness keeps one fixed offset for every time it
  says or schedules; a 07:00 task moves an hour against the wall clock
  twice a year until `utc_offset` is changed by hand. The import converts
  a job's time at its zone's offset on the import day and says so.
- **Private conversations on a local model** (from the fifteen-features
  list).

## Left out by builders (small)

Spoken replies; members' voice notes; the morning summary inside the
digest; announcing on Echo or Nest; asking back in a room; sign-in from
chat and OAuth device or client-credential flows; OpenAI's Responses API,
Bedrock, Vertex, streaming, images; embeddings or an index for memory and
the log; trigger webhooks and websockets; snapshots around workflow tool
steps; `say` with files; Smartcar Connect in chat; routine times following
a later `/quiet`; listing the Keychain for `harness report`; a custom
Home Assistant integration; MCP sessions resumed after a dropped stream.

Emergencies: `/setup` offering escalation (`[butler] escalate` is written
by hand); a member reached in a group; members told what the fallback
did; a typed message without a reply as an acknowledgement; [I'm on it]
beside Undo; the fallback for a valve on a plain switch; `/alerts`.

Mail: `email` in `/conversations` and its own `/private`; files in the
email answer; OAuth sign-in and token refresh for Gmail and Outlook (a
token from the environment); a doctor line and report entry for mail.ini;
a harness smoke check against the real mailmcp; away mode beyond the
Leaving routine; a flight's times go to the calendar as the owner's (an
arrival in another zone is off by the difference); real servers' quirks
(Gmail labels as folders, no SPECIAL-USE or IDLE) untested.

Calendar: Microsoft 365 (no CalDAV); a Google refresh token through
setup (by hand); new recurring events, moving a whole series, adding
attendees; past years' zone rules; the gate's question as a sentence; a
real maps server (a stand-in's travel time only).

People: the day's pass at the owner's own time (09:00 fixed); removing a
fact by the tool; importing while `harness run` runs; reminders for other
dates (name days kept, not reminded); a birthday missed while harness was
down; an [In touch] button; vCard 2.1's quoted-printable and `NOTE`,
`ADR`, `ORG`; people in the morning summary.

Away and travel, the door: a flight-status page as a source (an MCP
tool only); a calendar trip beyond tomorrow (calmcp's `cal://upcoming`);
lights at sunset (fixed evening minutes); away mode per person (the
house is empty or not); a delivery mail with no tracking number gives
the doorbell no hint (the hint is the deliveries', which keep only
parcels with a number).

Errands and upkeep: ordering through a shop's website with a login; a
room's speech adding to lists (it goes to the model, which has no list
tool); a list tool for the model; carriers' pages that need a browser
(DHL, UPS, Poczta Polska, FedEx give no status); a smoke check of a
carrier's page; with a Tesla, the daily odometer read (and the evening's
car line) get nothing while the car sleeps (`car_status` wakes it only
when asked).

Health, habits and the evening: reminders in the terminal's chat (main
only); a medication's history (by design); habits from tools other than
homemcp's `home_set`, across midnight, or of Home Assistant's own voice;
a weather MCP server (search and one model call instead); the evening's
leave-by from a maps server (`[butler] travel` only); `/setup` status
lines for the evening and the manner; the preset in topics (main only).

The car's heating: signing Tesla's commands in Zig (tesla-http-proxy
does it); Tesla over BLE, Fleet Telemetry, `vehicle_data_cached`,
scheduled departure; `/setup car` for a Tesla (the car file and
`carcloud login` by hand); a harness smoke check of warm-car against the
real carcloud (unit tests with harness-fake's Tesla stand-in).

## Not tested in the world

Nothing has run against a real model provider (omnigate included),
Telegram bot, Home Assistant, Zigbee2MQTT, Smartcar, transcription
service, speaker, MCP server, authorization server, mail server (IMAP,
SMTP), CalDAV server or website: stand-ins only. `harness/TESTERS.md` is
for the people who will.

## Infrastructure

GitHub cancels macOS jobs that wait about 15 minutes for a runner (most
pushes lose one or two); they pass when rerun. A paid plan or fewer macOS
jobs would end it.

Windows runners sometimes drop mid-job ("The hosted runner lost
communication with the server"): 2 of 5 harness runs on 2026-11-24,
with no log kept and nothing on githubstatus.com. Linux and macOS passed
the same code at the same time, and the rerun passed in the usual time
(Debug 8 min, ReleaseSafe 11). If it keeps happening, look for a Windows
test that starves the machine.

- ~~calmcp ignores tool fields it doesn't know~~ **done (2026-11-24, carheat)**: a field a tool doesn't take is refused, nothing read or written.
- ~~**Security (from a review, 2026-11-23): harness's own jobs share the `schedule:NAME` principal with user tasks, briefs and schedules.**~~ **Fixed (2026-11-24)**: harness's own jobs run as `harness:NAME` (`harness:people`, `harness:away`, `harness:trips`, `harness:warm-car`, `harness:habits`, `harness:evening`, `harness:lists`, `harness:reorder`, `harness:deliveries`, `harness:upkeep`), a who kind no settings file produces: rules sections `[harness:NAME]`, nobody to ask in them (as schedules), and only harness's own workflow of that name may name it in its start line. The shipped rules say `[harness:away]`; a task named `away` or `people` gets none of their lines (tests a_task_named_away_gets_none_of_harnesss_away_lines, a_task_named_people_gets_none_of_harnesss_people_lines).
