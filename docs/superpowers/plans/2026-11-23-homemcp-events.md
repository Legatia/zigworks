# homemcp: events, presence, discover, wider kinds

2026-11-23. Parts 1 and 3 of `../specs/2026-11-23-harness-butler-design.md`,
homemcp only (plus one check in harness's smoke for Part 1's harness test).
Branch `platform/homemcp-events`. Tests first in each step; the whole suite
(unit tests, then `scripts/smoke.sh`) after each; one commit per step.

## Steps

1. **Wider kinds** (config, model, hub, sim). Kinds `fan` (on, off,
   speed), `scene` (activate; Home Assistant only), `media` (play, pause,
   volume; Home Assistant only); lights add `color` (a name or `#rrggbb`)
   and `color_temp` (K). `[limits]` add `color_temp` (2200 6500), `volume`
   (0 60), `speed` (1 100). Device keys `room` and `alias` (aliases match in
   every tool: case, spaces and a leading "the" don't matter; one used
   twice is refused). Read-back for each: colour by hue, colour temperature
   within 3 %, volume and speed within 2 points (a fan's own step), a
   scene by its new activation time. homemcp-sim gains a colour lamp, a
   fan, a speaker, two scenes (one sets the front door) and two people.
2. **WebSocket client** (`ws.zig`): the upgrade (key, accept), masked text
   frames out, frames in (fragments, ping, close), a poll before each read.
   homemcp-sim serves Home Assistant's WebSocket API with std's server side.
3. **Events and presence** (`events.zig`, hub, server). Per device the last
   change of its main state (`from`, `to`, `at`); `home://device/NAME` and
   `home://presence` as MCP resources, `resources/subscribe`,
   `notifications/resources/updated` for subscribed ones only. Home
   Assistant: a thread holds the WebSocket (auth, `subscribe_events`
   `state_changed`, `get_states` after each connect to catch what was missed,
   pings, reconnect with backoff 1 s doubling to 60 s); REST stays for
   actions and reads. Zigbee2MQTT: the state topics already followed.
   Tests: `ha_state_changes_arrive_as_resource_updates`,
   `z2m_state_topics_arrive_as_resource_updates`,
   `presence_says_everyone_left_and_first_home`; smoke over MCP.
4. **discover** (`discover.zig`, main). `homemcp discover http://HA:8123`
   (HA_TOKEN): areas, devices, entities (and their voice aliases), states,
   over the WebSocket; `homemcp discover mqtt://HOST:1883[/BASE]`: the
   bridge's device list. Prints a home file; a summary in plain words on
   stderr. Test: `discover_writes_safe_defaults`; smoke: discover the sim,
   then `check` the file it wrote.
5. **harness**: a smoke check, when homemcp is built next to it: a trigger
   on `home://device/back_door` says its line after homemcp-sim opens the
   door (pushed, not polled).
6. **README and examples**: events and presence, discover, the new kinds,
   the State line; version 0.2.0.

## Rulings (what – why – cost if wrong)

- A resource holds a device's **main state** and its last change (on/off,
  open/closed, locked, a mode and setpoint, a sensor's reading), not every
  attribute – so a push means a change people care about, not a power
  reading or a room temperature drifting under a thermostat – cost: a
  trigger on such a detail must use `home_wait` or `home_state`.
- **REST stays for reads and read-back** on Home Assistant; the WebSocket
  only feeds pushes – one tested path for "did it take" – cost: `home_wait`
  still asks twice a second.
- **Presence is opt-in**: a `[people]` section lists the person entities;
  `discover` writes it – only what the home file lists is ever pushed, and
  where people are is personal data – cost: a hand-written file needs the
  section for presence.
- **discover allows guarded devices only the safe direction** (lock, close,
  arm), never unlock, open or disarm – the red lines – cost: an owner who
  wants unlocking asked for adds `unlock` by hand.
- **A scene that sets a lock, alarm, valve or garage door is guarded**:
  checked when it runs, from the scene's entity list, refused through
  `home_set` – otherwise a scene is a way around the guard – cost: such a
  scene is asked about every time.
- **Settings and diagnostics entities are left out by discover** (a plug's
  child lock, a LED) – they are a device's settings, not something to switch
  – cost: an owner who wants one adds it.
- **States heard in the first 3 s after (re)connecting fill a resource
  silently**, and reads wait for that window – no burst of events at every
  restart – cost: a device unknown before that changes in those 3 s is seen
  as its state, not as a change.
- **Words from the hub are filtered** (a-z, digits, `_ -`, 32 chars, else
  "unknown") before they reach a result or a resource – pushed events are
  data and must not carry text into the agent – cost: an odd but real state
  shows as unknown.
- **Zigbee2MQTT has no device classes**: discover calls a device a valve or
  a garage door by its name or description ("valve", "garage", "gate") –
  cost: a valve named otherwise is offered as a plug; the summary says to
  check plugs.
- **Version 0.2.0** – new tools surface and file keys – cost: none.

Taken while building:

- **REST answers count too, but never undo a newer state**: what
  `home_state`, a read-back or a read asks Home Assistant feeds the
  resources; an answer older than what is known is ignored – a change the
  WebSocket hasn't brought yet isn't lost, and a slow answer can't roll one
  back – cost: none seen.
- **A Home Assistant switch named like a valve** is guarded and may only be
  switched off; **one named like a garage, gate, door, lock, alarm or
  siren** is guarded with nothing allowed – a relay can be any of these –
  cost: such a switch does nothing until the owner adds what to ask for.
- **The harness check lives in harness's smoke** and runs when homemcp is
  built next to it (or `HOMEMCP_BIN`) – it needs harness-fake's Telegram –
  cost: harness's CI job skips it until it builds homemcp first.
