# Let the agent see the whole house and touch a short list

*Written 22 Nov 2026 for [homemcp](../../homemcp/), from web reading only.
[S] marks a point that rests on a secondary source or a search excerpt, and
[I] marks an inference of ours. Engineering information, not legal advice.*

An agent can run a smart home today without any cloud of its own, through
the two open hubs most enthusiasts already have: **Zigbee2MQTT**, which puts
Zigbee devices on an MQTT broker as JSON, and **Home Assistant**, which has a
REST API and a WebSocket API behind one long-lived token. Both are easy to
drive, and that is the problem. Either one lets a client switch anything,
including the front door's lock. The large assistants have each settled on
the same answer for locks, alarms and garage doors: they won't act on them
without something extra, a PIN, a voice code or an unlocked phone. Home
Assistant's own assistant documents no such step. So an agent integration has
to bring its own rules. The design that follows from the research: **the
agent sees every device, acts only from a per-device allowlist, reaches
locks, alarms and valves only through a separate tool that a person approves
every time, hears "done" only after the device confirms, and leaves a log
line for every attempt, refused ones included.** That is what homemcp does.

## The two hubs speak simple, documented protocols

**Zigbee2MQTT** publishes each device's state as JSON on
`zigbee2mqtt/<friendly name>`, and takes commands on `.../set`, such as
`{"state": "ON"}` or `{"brightness": 200}`. Covers take `OPEN`, `CLOSE`,
`STOP` and a `position` from 0 to 100. Locks take `LOCK` and `UNLOCK` and
report `lock_state`. Thermostats take a heating setpoint and a `system_mode`
([MQTT topics](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html)).
Each device describes what it can do in `exposes`, with an `access` bit for
"can be set" ([exposes](https://www.zigbee2mqtt.io/guide/usage/exposes.html)).
Two details matter for safety:

- **Availability is off by default.** When it is on, each device's
  `.../availability` topic says `online` or `offline`, and mains devices
  count as offline after 10 minutes without an answer
  ([availability](https://www.zigbee2mqtt.io/guide/configuration/device-availability.html)).
  Without it, a client can't tell a dead lock from a quiet one.
- **The bridge says whether it is up**, on the retained `bridge/state`
  topic, and lists every device on `bridge/devices`.

**Home Assistant** answers `GET /api/states` with every entity's state, and
runs an action with `POST /api/services/<domain>/<service>`, such as
`light/turn_on` with an `entity_id`
([REST API](https://contributors.home-assistant.io/core/internals/rest-api/)).
One trap: `POST /api/states/<entity_id>` only changes what Home Assistant
shows, and doesn't talk to the device. A client that uses it for control
reports success while nothing happens. The WebSocket API adds
`subscribe_entities` for changes as they happen, and `call_service` with a
`context` id for the audit trail
([WebSocket API](https://contributors.home-assistant.io/core/internals/websocket-api/)).

**Home Assistant already ships an MCP server.** Its "device control" endpoint
sees only the entities exposed to its voice assistant. The full endpoint
needs an admin by default, and neither sends notifications
([MCP server](https://www.home-assistant.io/integrations/mcp_server/)). It
offers Home Assistant's own tools, so it has none of the rules below.

## How the big assistants guard locks, alarms and garage doors

| Device | Google | Alexa | Apple | Home Assistant Assist |
|---|---|---|---|---|
| Unlock a door | PIN required to certify; the Gemini app won't do it | off by default; with Ring locks, a voice code | the phone must be unlocked first | no confirmation documented; locks unexposed by default |
| Disarm an alarm | PIN required | opt-in, with a voice code | not checked | unexposed by default; a wrong code fails silently |
| Open a garage door or gate | PIN required | asks first; a voice code [S] | not checked | exposed by default, as a cover |
| Valves, boilers, heaters on plugs | nothing found | nothing found | nothing found | plugs and heating exposed by default |

Sources: Google's
[secondary user verification](https://developers.home.google.com/cloud-to-cloud/enhancements/secondary-user-verification)
and [Gemini help](https://support.google.com/gemini/answer/15335456). Amazon's
[LockController](https://developer.amazon.com/en-US/docs/alexa/device-apis/alexa-lockcontroller.html),
[SecurityPanelController](https://developer.amazon.com/en-US/docs/alexa/device-apis/alexa-securitypanelcontroller.html)
and [Ring's help](https://ring.com/support/articles/od8uw/Operate-Your-Works-with-Ring-Smart-Locks-with-Alexa).
[Apple's HomeKit help](https://support.apple.com/en-us/105027). Home
Assistant's
[exposing devices](https://www.home-assistant.io/voice_control/voice_remote_expose_devices/)
and [alarm panel](https://www.home-assistant.io/integrations/alarm_control_panel/)
pages.

Two more points from the same pages:

- **Google calls home controls a convenience, not a safety or security
  function.**
- **Home Assistant's built-in AI tool set can reach every entity**, exposed
  or not, through its LLM API
  ([LLM API](https://contributors.home-assistant.io/core/internals/llm-api/)).
  "Unexposed" protects against the voice assistant, not against every agent.

Nobody publishes rules for water valves, boilers, ovens, or heaters on smart
plugs. homemcp puts valves in the always-guarded tier with locks and alarms
[I]. Its example home allows a kettle plug to be switched off but never on,
and keeps smoke detectors and cameras out entirely.

## The law: insurance, cameras, product rules (Poland and the EU)

- **A software unlock may not count as burglary.** A typical Polish home
  policy defines burglary as entry after the thief removed the existing
  security. Force and tools count only if they left traces. An original key
  counts only if it was stolen in a burglary or robbery
  ([LINK4](https://www.link4.pl/blog/kradziez-z-wlamaniem-jak-sie-zabezpieczyc)).
  An unlock by a bug, a stolen token or an injected prompt leaves no traces,
  so an insurer may treat it as an unlocked door [I]. Under Civil Code art.
  827 § 1, gross negligence voids the payout unless the contract says
  otherwise ([art. 827](https://arslege.pl/kodeks-cywilny/k9/a6341/)). This
  is the strongest reason never to let an agent unlock on its own.
- **Indoor cameras:** GDPR's household exemption is narrow. A camera that
  covers even part of a public space falls outside it (CJEU, Ryneš, C-212/13)
  [S]. A cloud service that processes the frames is in scope either way
  ([recital 18](https://gdpr-info.eu/recitals/no-18/)). homemcp has no camera
  support, and that is deliberate.
- **Product rules apply to products, not to a home project.** The Cyber
  Resilience Act lists smart-home assistants and smart-home security products
  (locks, cameras, alarms) in its Class I [S]. It has applied to manufacturers'
  vulnerability reporting since 11 Sep 2026, and in full from 11 Dec 2027.
  Open source that isn't monetised is outside it
  ([CRA](https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act);
  [open source](https://digital-strategy.ec.europa.eu/en/policies/cra-open-source)).
  A paid version of homemcp could arguably fall into Class I [I].

## Matter: through Home Assistant for now

python-matter-server was archived on 23 Jun 2026. Its successor,
matterjs-server, runs on Node.js, serves a WebSocket on port 5580, binds to
every network interface by default and documents no authentication. Anyone
running it should pass `--listen-address 127.0.0.1`
([matterjs-server](https://github.com/matter-js/matterjs-server)). Home
Assistant's Matter add-on is built on it
([HA blog](https://home-assistant.io/blog/2026/06/23/the-matter-upgrade-youve-been-waiting-for)).
Matter also needs IPv6 and mDNS on the network, a Thread border router for
Thread devices, and a phone or Bluetooth to commission devices. homemcp
therefore reaches Matter devices through Home Assistant. A direct client is
possible later.

## MCP can push now, but clients barely listen

The MCP specification of 2026-07-28 is stateless. Its only channel for
unprompted messages is `subscriptions/listen`, and a server may send only
what the client asked for. Logging moved inside requests, and server-to-client
questions became a return value, `input_required`
([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).
An Events extension (beta) adds polling, streams and signed webhooks, and
says that receiving an event never authorises the agent to act
([events](https://modelcontextprotocol.io/extensions/events/overview.md)).
Few clients act on any of it yet. ChatGPT takes events by webhook only, and
Claude Code re-reads tool lists when they change. Claude Code does honour
`_meta["anthropic/requiresUserInteraction"]: true` on a tool, which forces a
prompt on every call ([Claude Code MCP](https://code.claude.com/docs/en/mcp.md)).
homemcp speaks the 2025-06-18 handshake that harness uses, marks its guarded
tool that way, and offers `home_wait` instead of pushing.

## What homemcp does with this

| Finding | In homemcp |
|---|---|
| Either hub lets a client switch anything | Per-device `allow` lists. No generic publish or `call_service`. Sensors are only seen. |
| Assistants guard locks, alarms and garage doors | `home_guarded`, a tool of its own, marked `requiresUserInteraction`. Locks, alarms and valves are always guarded, and `guarded = yes` adds others. In harness, a money tool: asked every time, never given to helpers, never run from schedules. |
| A software unlock leaves no traces | The examples don't allow unlocking at all. homemcp refuses whatever isn't allowed, whether or not a person was asked. |
| Zigbee2MQTT availability, bridge state | Refuses to act on an offline device. `check` reports the bridge. |
| Home Assistant's `POST /api/states` doesn't reach the device | Never used. Actions go through `/api/services`. |
| Commands can fail silently (alarms with a wrong code) | Reads the device back for 5 seconds after every action. "done" only when it reports the new state. |
| Insurance and forensics | One JSON line per call, refusals included. |
| Values an agent could get wrong | `[limits]` for temperature, brightness and position, and `modes` for climate. |

**Not done yet:** a confirmation that homemcp enforces itself (an MCP
`input_required` question with a signed, short-lived request state); pushing
changes over `subscriptions/listen`; Home Assistant's WebSocket API; colours,
fans and scenes. And above all, a test with a real hub and real devices:
everything so far ran against `homemcp-sim`.

## Red lines

| Never | Why |
|---|---|
| Unlock, open a garage door or disarm from an event, a schedule or an unattended run | No traces for the insurer, and an injected prompt in a message or page must never reach a lock |
| Offer a generic publish or `call_service` tool | An allowlist is the only control that holds when the model is wrong |
| Use Home Assistant's `POST /api/states` for control | It reports success without reaching the device |
| Act on smoke or CO detectors or cameras | Safety devices and personal data; read-only at most |
| Expose the MQTT broker or matterjs-server beyond localhost without credentials | Both accept anyone who can connect |
| Treat sensor data or pushed events as instructions | They are data; acting needs the owner's request |
