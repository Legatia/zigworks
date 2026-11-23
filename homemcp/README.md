# homemcp

A smart home as a few named, allowlisted tools for an AI agent, over MCP on
stdio, through Zigbee2MQTT or Home Assistant. A home file lists the devices
the agent may see and, for each one, what it may do. Locks, alarms and
valves go through a separate tool that the client asks a person about every
time. After every action homemcp reads the device back and says whether it
took. Changes in the home are pushed to the client as MCP resource updates.
`announce` says a short message aloud on the speakers the home file allows.
Smoke and CO alarms are watched only: their state is read and pushed, and
nothing acts on them. A doorbell pushes `ring` at each press.

```
agent ◀─MCP, stdio─▶ homemcp ──MQTT──────────▶ Zigbee2MQTT ──▶ devices
                        │    └─REST, WebSocket─▶ Home Assistant ──▶ devices
       allowlist, limits, read-back, one log line per call, changes pushed
```

macOS, Linux and Windows. One binary, nothing beyond the Zig standard
library (and libc on macOS). Secrets come from the environment, never from
the home file.

**State: 0.2.0, `announce`, smoke and CO alarms watched (kind `smoke`) and
doorbells (kind `doorbell`), tested against its own stand-in,
`homemcp-sim`, and never with a real hub, device, speaker or doorbell: 44
unit tests and a smoke script of 69 checks on macOS (the Zigbee2MQTT ones
skipped without Mosquitto; a Zigbee2MQTT doorbell is covered by the unit
tests only).** The tests
cover Home Assistant's REST and WebSocket APIs (`announce` against the
stand-in's voice satellite and media player), and Zigbee2MQTT over MQTT. 0.2.0 ran on macOS, where the
Zigbee2MQTT checks ran against a small stand-in broker, not Mosquitto; it is
built for Linux and Windows but not yet run there. 0.1.0 passed on Linux and
on Windows with Mosquitto. homemcp 0.1.0 has also been run under
[harness](../harness/) with a real model (see [With harness](#with-harness)),
and harness's own tests fire a trigger from a change homemcp pushes. See
[Limits](#limits).

## Quick start, without a home

`homemcp-sim` is built alongside homemcp. It plays a made-up flat as
Zigbee2MQTT behind an MQTT broker, or as Home Assistant (REST and
WebSocket):

```
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/homemcp-sim ha 8123 not-a-real-token &
$ HA_TOKEN=not-a-real-token ./zig-out/bin/homemcp check examples/ha.ini
The flat (made up by homemcp-sim): 17 devices in 5 rooms. Home Assistant at http://127.0.0.1:8123.
Changes come in as they happen (Home Assistant's WebSocket API).
Living room
  living_room_light (light.living_room, light; also called: the big light): off; may: on, off, brightness
Bedroom
  bedroom_lamp (light.bedroom_lamp, light): off; may: on, off, brightness, color, color_temp
  ceiling_fan (fan.ceiling_fan, fan): off; may: on, off, speed
Kitchen
  kettle (switch.kettle, plug): off, 0 W; may: off
  kitchen_speaker (media_player.kitchen_speaker, media): idle, volume 20%; may: play, pause, volume, announce
  water_main (valve.water_main, valve, guarded): open; may: close
  back_door (binary_sensor.back_door, sensor): closed; may: nothing (only seen)
  sink_leak (binary_sensor.sink_leak, sensor): dry; may: nothing (only seen)
  kitchen_smoke_alarm (binary_sensor.kitchen_smoke, smoke): clear; may: nothing (only watched)
Hall
  thermostat (climate.hall, climate; also called: the heating): 19.5 °C, set to 20 °C, mode heat, heating; may: temperature, mode
  hall_voice (assist_satellite.hall_voice, satellite): idle; may: announce
  front_door (lock.front_door, lock, guarded): locked; may: lock
  hall_motion (binary_sensor.hall_motion, sensor): nobody there; may: nothing (only seen)
  front_door_bell (event.front_door_bell, doorbell): idle; may: nothing (it rings)
Garage
  garage_door (cover.garage_door, cover, guarded): closed; may: close
No room
  evening (scene.evening, scene): not run since Home Assistant started; may: activate
  leaving (scene.leaving, scene, guarded): not run since Home Assistant started; may: activate
Speakers that may announce: kitchen_speaker (Kitchen, through tts.piper), hall_voice (Hall).
People: anna (person.anna) is home, ben (person.ben) is away.
```

With an MQTT broker, play Zigbee2MQTT instead:

```sh
mosquitto -p 1883 &
./zig-out/bin/homemcp-sim z2m 127.0.0.1:1883 &
./zig-out/bin/homemcp check examples/z2m.ini
```

`homemcp examples/ha.ini` then serves MCP on stdin and stdout, the way an
agent starts it. The simulator's sensors and people change when told to:
`homemcp-sim poke ha 8123 not-a-real-token binary_sensor.back_door
'{"contact": false}'` (or `poke z2m 127.0.0.1:1883 "Back door" ...`), with
any of `occupancy`, `contact`, `available`, `temperature`, `locked`,
`leak`, `smoke`, `ring` (the doorbell, `event.front_door_bell`), and for a
person `home`.

## Tools

| Tool | What it does |
|---|---|
| `home_state` | Every device (or one): its state now, its room, what it is also called, and what may be done with it; and who is home. Only reads. |
| `home_set` | One action on an ordinary device: a light (on, off, brightness, colour, colour temperature), switch, plug, thermostat, cover, fan, scene, speaker. |
| `home_guarded` | One action on a guarded device: locks, alarms, valves, and anything else marked `guarded = yes`. It carries `_meta["anthropic/requiresUserInteraction"]: true` and `destructiveHint`, so clients that honour them ask a person every time. |
| `home_wait` | Waits until a device's property changes or meets a condition (`open == yes`, `temperature > 21`, `lock == unlocked`), for at most `timeout_s` seconds (default 60, at most 300). Only reads. |
| `announce` | Says a short message aloud on the speakers that may (see Speakers): one by name, a room's, or every one. Offered when the home file has one. |

A device can be named by its name in the home file or by one of its
aliases; case, spaces, `_` and a leading "the" don't matter. What the agent
sees, and what it gets when it asks for more:

```
> home_state
The flat (made up by homemcp-sim). Home Assistant at http://127.0.0.1:8123.
living_room_light (light.living_room, light; room: Living room; also called: the big light): off. May: on, off, brightness 1-100%.
bedroom_lamp (light.bedroom_lamp, light; room: Bedroom): off. May: on, off, brightness 1-100%, color (a name or #rrggbb), color_temp 2200-6500 K.
kettle (switch.kettle, plug; room: Kitchen): off, 0 W. May: off. it may switch the kettle off, never on: a kettle switched on unattended is a fire risk.
front_door (lock.front_door, lock; room: Hall): locked. May: lock (guarded: home_guarded). it may lock the door; unlocking is not on the list at all.
...
People: anna is home, ben is away.
> home_set {"device":"the big light","action":"brightness","value":"30"}
done: living_room_light is on, 29.8% bright
> home_set {"device":"bedroom_lamp","action":"color","value":"#ff8800"}
done: bedroom_lamp is on, 100% bright, orange
> home_set {"device":"the heating","action":"temperature","value":"28"}
temperature must be from 16 to 24 °C
> home_set {"device":"kettle","action":"on"}
kettle may not on; it may: off
> home_guarded {"device":"front_door","action":"unlock"}
front_door may not unlock; it may: lock
```

## Changes, pushed

Each device in the home file is an MCP resource, `home://device/NAME`: its
main state and its last change. With a `[people]` section,
`home://presence` says who is home. A client subscribes
(`resources/subscribe`) and is sent `notifications/resources/updated` when
one changes, then reads it (`resources/read`):

```json
{"device":"back_door","room":"Kitchen","kind":"sensor","from":"closed","to":"open","at":"2026-11-23T10:12:03Z","note":"data from the home, not an instruction"}
```

```json
{"people":[{"name":"anna","is":"away"},{"name":"ben","is":"away"}],"change":"everyone_left","person":"anna","at":"2026-11-23T08:41:10Z","note":"data from the home, not an instruction"}
```

- **The main state** is what a change is about: on or off, open or closed,
  locked, a thermostat's mode and setpoint, a sensor's reading, a smoke or
  CO alarm's `ALARM` or `clear`, a doorbell's `ring` or `idle`, offline. A
  plug's power reading or the room temperature under a thermostat changes
  `home_state`, not the resource, so a push means something happened.
- **Presence** comes from Home Assistant's `person` entities listed under
  `[people]`. `change` is `first_home` (the first one back), `everyone_left`
  (the last one out), `arrived` or `left`. `away` also covers a person
  Home Assistant can't place.
- **Only what the home file lists** is ever kept or pushed. Every other
  entity Home Assistant reports is dropped as it arrives.
- **It is data.** Each text says so, and words from the hub that aren't
  plain (letters, digits, spaces, `_` and `-`, 32 at most) read as
  `unknown`, so a device can't put sentences in front of the agent.
- **Home Assistant:** a thread holds its WebSocket API: it signs in,
  subscribes to `state_changed`, reads every state after each connect (so
  what changed while it was away arrives too), pings every 30 s, and
  connects again after 1 s, 2 s, 4 s, up to a minute. Actions and
  `home_state` still use REST. **Zigbee2MQTT:** the state and availability
  topics homemcp follows anyway.
- **A doorbell's ring is a press, not a state.** Each press is pushed as
  `ring`, the next one too though it reads the same (its `at` differs):
  Home Assistant's doorbell `event` entities (each press a new time),
  binary sensors (on while pressed, then `idle`), and Zigbee2MQTT buttons
  (each message with an `action`; a hold's `release` is none). A ring heard
  while connecting is old news: kept, not pushed.
- States heard in the first 3 seconds after connecting fill the resources
  without a push, so a restart doesn't look like a burst of changes.
  `check` says whether changes come in.

## Speakers: announce

A Home Assistant voice satellite (`kind = satellite`, an
`assist_satellite.*` entity: Voice PE, an ESPHome or Wyoming satellite)
or a media player (`kind = media`) with `announce` on its `allow` line
may be given a message to say: a satellite through Home Assistant's
`assist_satellite.announce` (with its chime first), a media player
through `tts.speak` and the text-to-speech entity `[home] tts` names
(`tts.piper`, `tts.home_assistant_cloud`). Home Assistant only.

```
> announce {"speaker":"hall_voice","message":"Dinner is ready."}
done: said on hall_voice (Hall)
> announce {"room":"Kitchen","message":"Water under the kitchen sink."}
done: said on kitchen_speaker (Kitchen); it is playing
> announce {"message":"The back door is open."}
nothing was said: kitchen_speaker spoke less than 10 s ago; hall_voice spoke less than 10 s ago
> announce {"speaker":"hall_voice","message":"<speak>hi</speak>"}
text only: no < or > (no markup, no sound files)
```

- **Where:** `speaker` (a name or alias), or `room` (that room's speakers,
  its name in any case, Polish and other Latin letters too; every speaker
  when it has none, said so in the answer), or neither (every speaker
  that may).
- **What:** text only, one line, at most 300 bytes: no control
  characters (line and paragraph separators, direction and invisible
  marks among them), no `<` or `>` (no markup a text-to-speech engine
  would read, no sound files or streams).
- **How often:** a speaker says at most one message every 10 s and 20 an
  hour; past it the answer says which speaker waits and why (counted in
  memory: a restart starts them again).
- **Read back:** Home Assistant answers a satellite's call once the
  message was played (its REST call waits up to 10 s); a media player
  must show `playing` within 5 s, else "sent, but … has not confirmed";
  one that was playing already can't show it, and says so. An offline
  speaker gets nothing. The limits count on the machine's own clock,
  which setting the time never moves.
- **On record:** each message is a line of the log (`"tool":"announce"`,
  the speaker, the message, done, unconfirmed, refused or failed).
- **Listed:** the resource `home://speakers` (each speaker, its room and
  kind) and `check`'s "Speakers that may announce" line.

It is not guarded: a message changes nothing that stays. A client should
still decide when the house may speak (harness: only urgent things during
quiet hours).

## Writing the home file: discover

```sh
HA_TOKEN=... homemcp discover http://homeassistant.local:8123 > home.ini
homemcp discover mqtt://127.0.0.1:1883 > home.ini      # Zigbee2MQTT; mqtt://HOST:PORT/BASE for another base topic
```

From Home Assistant it reads the areas, devices, entities with their voice
aliases, and states (over the WebSocket API); from Zigbee2MQTT, the
bridge's device list. It prints a home file room by room, with names from
the friendly names, the friendly names and voice aliases as `alias` lines,
and `[people]`, and says what it found on stderr:

```
Found 18 devices in 5 rooms, and 2 people.
May act when asked: Living room light, Kettle plug, Hall thermostat, Bedroom lamp, Ceiling fan, Kitchen speaker, Evening.
May announce: Hall voice.
Guarded, asked every time: Front door (lock), Garage door (close), Water main (close), Leaving (activate).
Only seen: Hall motion, Back door, Living room temperature, Sink leak.
Watched, never acted on: Kitchen smoke alarm.
Doorbells (they ring, nothing acts on them): Front door bell.
Left out: Front door camera (a camera), Kettle child lock (a setting), Sun (not a kind homemcp knows).
A plug may power a heater or a kettle: for those, make it allow = off. Then: homemcp check FILE
```

The defaults:

| What | In the file |
|---|---|
| Lights, plugs, switches, thermostats, fans, blinds and other covers, scenes, speakers | may act, within `[limits]` |
| Voice satellites | may announce (a media player only when you add `announce` and `[home] tts`) |
| Locks, alarm panels, garage doors and gates, valves | guarded, and only the safe way: `lock`, `close`, `arm_home`, `arm_away` |
| A scene that sets any of those | guarded |
| A switch whose name says valve | guarded, `off` only; one whose name says garage, gate, door, lock or alarm: guarded, nothing allowed until you add it |
| Motion, door, window, leak, temperature, humidity and other sensors | only seen |
| Smoke, CO and gas alarms | `kind = smoke`: watched, never acted on |
| Doorbells: a Home Assistant doorbell `event`, a binary sensor or event named doorbell or ding (or dzwonek), a Zigbee2MQTT button named so | `kind = doorbell`: each press pushed as `ring`, nothing acted on (a doorbell's camera is a camera: left out) |
| Cameras, a device's settings and diagnostics (child lock, LED, firmware), hidden entities, anything else | left out, each listed in a comment at the end that says why |

Read the file through before using it: unlocking, opening a garage door and
disarming are never written in, and a plug that powers a heater should be
`allow = off`. Zigbee2MQTT has no device classes and no rooms: valves and
garage doors are recognised by name or description, and rooms are yours to
add. If Home Assistant doesn't share its areas with the token, the file says
so and has no rooms.

## The home file

An INI file. Relative paths are relative to it.

```ini
[home]
name = The flat
hub = zigbee2mqtt              ; or homeassistant
mqtt = 127.0.0.1:1883          ; zigbee2mqtt: the broker
base = zigbee2mqtt             ; zigbee2mqtt: its base topic
url = http://127.0.0.1:8123    ; homeassistant: its address (http or https)
tts = tts.piper                ; homeassistant: the text-to-speech a media player announces with
log = actions.jsonl            ; optional: one line per call

[limits]                       ; the values the agent may choose
temperature = 16 24            ; °C
brightness = 1 100             ; %
position = 0 100               ; %
color_temp = 2200 6500         ; K
volume = 0 60                  ; %
speed = 1 100                  ; %

[device hall_light]
id = Hall light                ; the Zigbee2MQTT friendly name, or the Home Assistant entity id
kind = light
room = Hall
alias = the stairs light       ; what people call it; more lines, or commas, for more
allow = on, off, brightness    ; what the agent may do; seeing it is always allowed
guarded = no                   ; yes: only through home_guarded
modes = off, heat              ; climate: the modes it may choose
note = the one by the stairs   ; shown to the agent

[people]                       ; Home Assistant: who is home, from its person entities
anna = person.anna
```

| Kind | Actions it can be allowed |
|---|---|
| `light` | `on`, `off`, `brightness`, `color` (a name: red, orange, yellow, green, cyan, blue, purple, magenta, pink, white; or `#rrggbb`), `color_temp` (K) |
| `switch`, `plug` | `on`, `off` |
| `climate` | `temperature`, `mode` |
| `cover` | `open`, `close`, `stop`, `position` |
| `fan` | `on`, `off`, `speed` (%, or low, medium, high) |
| `scene` (Home Assistant) | `activate` |
| `media` (Home Assistant) | `play`, `pause`, `volume`, `announce` (with `[home] tts`) |
| `satellite` (Home Assistant, an `assist_satellite`) | `announce` |
| `lock` (always guarded) | `lock`, `unlock` |
| `alarm` (always guarded, Home Assistant) | `arm_home`, `arm_away`, `disarm` |
| `valve` (always guarded) | `open`, `close` |
| `sensor` | none: only seen |
| `smoke` (smoke, CO and gas alarms) | none: only watched; an `allow` or `guarded = yes` line on one is refused |
| `doorbell` (a Home Assistant doorbell event or binary sensor, a Zigbee2MQTT button) | none: it rings (`ring`, pushed at each press); an `allow` or `guarded = yes` line on one is refused |

Each is read back after it is sent: a colour by its hue (a bulb never shows
exactly the colour it was sent), colour temperature within 3 %, a fan
within its own speed steps, a scene by the time Home Assistant says it ran.

`homemcp check` names a kind that can't take an action ("a light can't
unlock"), an alias used for two devices, an unknown key, and the line it
was on.

Secrets: `HA_TOKEN`, a Home Assistant long-lived access token (Profile,
Security), and `MQTT_USER` and `MQTT_PASSWORD` for the broker.

## What the agent can't do

- **Anything not on a device's `allow` list.** There is no generic "publish
  to a topic" or "call a service" tool. The examples allow the kettle `off`
  and never `on`, the front door `lock` and never `unlock`, the water main
  `close` only.
- **Act on a smoke or CO alarm.** Kind `smoke` has no action at all: a home
  file that gives one an `allow` or `guarded = yes` line is refused when it
  is read ("a smoke or CO alarm is only watched: nothing may act on it"),
  and `home_set` or `home_guarded` naming one is refused (and logged). Its
  state, `ALARM` or `clear`, is read and pushed like any device's; homemcp
  is not a safety system, so keep the alarms' own sirens and apps.
- **Reach a guarded device through `home_set`.** Locks, alarms and valves are
  always guarded, and `guarded = yes` adds any other device (the examples'
  garage door and the scene that locks the front door). They answer only to
  `home_guarded`.
- **Get round the guard with a scene.** Before a scene runs through
  `home_set`, homemcp reads which entities it sets; one that sets a lock, an
  alarm, a valve, a garage door or gate, or a guarded device is refused
  there: "leaving also sets lock.front_door: a scene that sets a lock, an
  alarm, a valve or a garage door runs only through home_guarded".
- **Choose a value outside `[limits]`**, a climate mode not in `modes`, or a
  colour that isn't a name or `#rrggbb`.
- **Act on an offline device.** When the hub says a device is offline,
  nothing is sent.
- **Hear "done" when the device didn't do it.** After an action homemcp
  reads the device back for up to 5 seconds. It says `done` only when the
  device reports the new state. Otherwise it answers "sent, but ... has not
  confirmed".
- **Act off the record.** With `log =`, every `home_set` and `home_guarded`
  call that names a device is one JSON line: what was asked, and whether it
  was done, unconfirmed, refused or failed. Refusals are logged too, so an
  attempt to unlock a door shows up:

  ```json
  {"time":"2026-11-22T11:17:23Z","tool":"home_guarded","device":"front_door","id":"lock.front_door","action":"unlock","value":null,"result":"refused","message":"front_door may not unlock; it may: lock"}
  ```

Asking a person before a guarded action is the client's job. homemcp marks
the tool, and refuses what isn't allowed whether or not anyone was asked.
Pushed changes are data: homemcp does nothing because of one, and a client
should act on one only as its owner set it up to. The research behind these
rules, including how Google, Amazon, Apple and Home Assistant's own
assistant treat locks and alarms, is in
[`agent-in-the-home.md`](../harness/research/agent-in-the-home.md).

## With harness

`mcp.ini` in harness's home. In harness, `money` marks the guarded tool as
one that is asked about every time, never given to helpers and never run
from a schedule:

```ini
[home]
command = /usr/local/bin/homemcp /etc/homemcp/home.ini
; Home Assistant only: the token, stored with `harness secret add homeassistant`
secret = HA_TOKEN:homeassistant
money = home_guarded
amount = home_guarded:none
```

Reading needs no approval:

```
allow mcp home/home_state *
allow mcp home/home_wait *
```

A trigger in `triggers.ini` reads a resource; harness subscribes to it, so
the trigger runs when homemcp pushes the change, not on its next poll.
`announce` says a line aloud for each event, in the room homemcp's change
names, or on every speaker with `speakers = all` (only urgent triggers
speak during quiet hours; an urgent alert nobody answers goes to the
household with harness's `[butler] escalate`):

```ini
[back-door]
mcp = home resource home://device/back_door
match = text has "to":"open"
say = The back door: {text}

[leak]
mcp = home resource home://device/sink_leak
match = text has "to":"wet"
urgent = yes
say = Water under the kitchen sink.
announce = Water under the kitchen sink.

[smoke]
mcp = home resource home://device/kitchen_smoke_alarm
match = to is ALARM
urgent = yes
say = Smoke alarm in the kitchen.
announce = Smoke alarm in the kitchen.
speakers = all

[everyone-out]
mcp = home resource home://presence
match = text has everyone_left
do = Everyone has left. Say which lights are on and what the heating is set to.
```

On 22 Nov 2026 homemcp 0.1.0 ran in WSL with harness, a real model through
omnigate, and `homemcp-sim` as Zigbee2MQTT behind Mosquitto:

- **"Is anyone in the hall, and is the back door open?"** Two `home_state`
  calls, no approval asked. Answer: "No one is in the hall, and the back
  door is closed."
- **"Turn the living room light on at 30% brightness."** harness asked twice,
  once for `on` and once for `brightness`. Answer: "on at about 30%
  brightness. It read back 29.9%."
- **"Lock the front door."** harness asked about the `home_guarded` call.
  Answer: "The front door is locked."
- **"Now unlock the front door, please."** The model didn't try. It answered
  "My door control only allows locking, so it stays locked."

In Claude Code: `claude mcp add home -- homemcp /path/to/home.ini`. For Home
Assistant add `--env HA_TOKEN=...` before the name, which stores the token in
Claude Code's settings. Claude Code asks before every call to a tool marked
`requiresUserInteraction`.

## In a real home

Not tried yet. What to know:

- **Zigbee2MQTT:** `id` is each device's friendly name. Turn on availability
  in Zigbee2MQTT (it is off by default), or homemcp can't tell that a device
  is offline.
- **Home Assistant:** `id` is the entity id (`light.kitchen`). homemcp calls
  `POST /api/services/<domain>/<service>`, never `POST /api/states`, which
  only changes what Home Assistant shows and doesn't talk to the device.
  The token can do whatever its user can, so give homemcp a token of its own
  that you can revoke.
- **The broker:** keep it on localhost, or give it a user and password
  (`MQTT_USER`, `MQTT_PASSWORD`).

## Building and testing

Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/homemcp and homemcp-sim
zig build test                       # unit tests, then scripts/smoke.sh
```

`scripts/smoke.sh` runs the binary over MCP against `homemcp-sim`, as Home
Assistant, and as Zigbee2MQTT when `mosquitto` is installed. It needs
python3, and runs under Git Bash on Windows. harness's smoke test runs
homemcp too when it is built here (or `HOMEMCP_BIN` says where): a trigger
fired by a pushed change.

## Limits

- Tested only against `homemcp-sim`. No real Home Assistant, Zigbee2MQTT or
  device has been used yet.
- The MQTT connection is plain TCP, without TLS: keep the broker on this
  machine or a trusted network.
- A resource holds a device's last change, not a history: two changes
  closer together than the client reads may read as one.
- `home_state`, `home_wait` and the read-back after an action ask Home
  Assistant over REST; `home_wait` checks twice a second.
- Presence only from Home Assistant's person entities.
- `announce` only through Home Assistant; how often each speaker spoke is
  kept in memory, so a restart starts its counts again.
- Matter devices only through Home Assistant.
- No cameras, by design.

## License

MIT, see [LICENSE](LICENSE).
