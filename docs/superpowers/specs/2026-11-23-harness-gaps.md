# harness: what is not built yet (2026-11-23)

Everything specced through 2026-11-23 is built and green in CI on Linux,
macOS and Windows (dcc2742): the platform gaps, the "close ones", the
butler's Parts 1–9. This file lists what is not, in one place, with what
each waits on. Update it when something lands.

## Waiting on the owner's answers

| Gap | Question | Built meanwhile |
|---|---|---|
| Email | **answered 2026-11-23: A (its own address) and C (your mailbox read-only + drafts, opt-in); specced, being built** | — |
| Money from automation | Q2: may runs started by triggers, workflows, apps move money | built off: `[money] triggers/workflows/apps = off`; tool steps asked every time |
| Default environment for unattended runs | Q3: host or sandbox | host |
| Apps opened from the phone | Q4: a TLS front (tailscale serve) or loopback only | loopback only |
| Hosted version | five questions in the hosted design (VMs, EU, one balance, support access, home connector) | design only |
| Releases | tag one | release.yml for harness, homemcp, carcloud; nothing tagged |

## The butler, against a real one (Alfred)

| Duty | Status | Gap |
|---|---|---|
| Acting when the owner can't be reached | **specced 2026-11-23** | escalation to a household member; safe-direction fallback (close, lock, arm) after no answer, opt-in per routine; smoke and CO alerts (read only) |
| Diary | **specced 2026-11-23** | calendar (agenda, conflicts, changes asked), leave-by alerts, preparing for a meeting, no interruptions in meetings |
| People and occasions | **specced 2026-11-23** | who's who, birthdays, preferences, keeping in touch, gift ideas |
| Post and messages | email specced and being built (A and C) | messages to others on the owner's behalf through other channels (asked every time) |
| The door | not specced | doorbell: who is there, announced, one tap to answer; deliveries |
| Away and travel | not specced | away mode (lived-in lights, stricter watch, daily summary); itinerary, flight status, check-in, packing list |
| Errands | not specced | shopping list and pantry, reorders within caps, delivery tracking; pay-per-call services (pay.sh, x402) |
| Habits | not specced | suggesting a routine from a seen pattern (never turned on unasked) |
| House upkeep | not specced | service dates (boiler, filters, car), manuals and warranties remembered |
| Health | not specced | medication reminders, sleep nudges, wearable data (optional) |
| Manner | not specced | a butler persona preset, an evening wrap-up |
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

## Not tested in the world

Nothing has run against a real model provider (omnigate included),
Telegram bot, Home Assistant, Zigbee2MQTT, Smartcar, transcription
service, speaker, MCP server, authorization server or website: stand-ins
only. `harness/TESTERS.md` is for the people who will.

## Infrastructure

GitHub cancels macOS jobs that wait about 15 minutes for a runner (most
pushes lose one or two); they pass when rerun. A paid plan or fewer macOS
jobs would end it.
