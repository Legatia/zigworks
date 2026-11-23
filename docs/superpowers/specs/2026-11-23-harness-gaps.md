# harness: what is not built yet (2026-11-23)

Everything specced through 2026-11-23 is built and green in CI on Linux,
macOS and Windows (dcc2742): the platform gaps, the "close ones", the
butler's Parts 1–9. The butler's duties (emergencies, the diary, people)
and email are built and merged on harness-logins (2026-11-23), not yet
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
| The door | **specced 2026-11-23 (household spec)** | doorbell: who is there, announced, one tap to answer; deliveries |
| Away and travel | **specced 2026-11-23 (household spec)** | away mode (lived-in lights, stricter watch, daily summary); itinerary, flight status, check-in, packing list |
| Errands | **specced 2026-11-23 (household spec)** | shopping list and pantry, reorders within caps, delivery tracking; pay-per-call services (pay.sh, x402) |
| Habits | **specced 2026-11-23 (household spec)** | suggesting a routine from a seen pattern (never turned on unasked) |
| House upkeep | **specced 2026-11-23 (household spec)** | service dates (boiler, filters, car), manuals and warranties remembered |
| Health | **specced 2026-11-23 (household spec)** | medication reminders, sleep nudges, wearable data (optional) |
| Manner | **specced 2026-11-23 (household spec)** | a butler persona preset, an evening wrap-up |
| The car | partly | warming it (Tesla Fleet API or BMW CarData; Smartcar has no climate); an in-car box (research only) |
| Phone calls | not specced | calling on the owner's behalf |

## Platform pieces not finished

- **Apps (gap 8)**: the app server serves approved apps; their API (reads,
  acts, runs as `app:NAME`), `app_draft`/`app_save` and the review page,
  versions and forks, and the question bar are the Windows session's next
  item.
- **Hermes differentiators** (from the comparison): prompt-injection checks
  in the smoke script and a demo of the gate holding; import of a Hermes
  setup and agentskills.io skills; the gate as an MCP proxy for other
  agents.
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

- calmcp ignores tool fields it doesn't know (a routine sending `location` for `place` lost the place silently until the stand-in refused it); calmcp itself should refuse unknown fields, as homemcp does.
- **Security (from a review, 2026-11-23): harness's own jobs share the `schedule:NAME` principal with user tasks, briefs and schedules.** `schedule:people` (people's daily pass, merged), `schedule:away`/`schedule:trips` (away), `schedule:warm-car` (car heating) and any other internal job: a user task named the same gets the rules written for harness's job. Fix after the household merges: a who kind `harness:NAME` no settings file can produce, used by every internal job and the shipped rules.
