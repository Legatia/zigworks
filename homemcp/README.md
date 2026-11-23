# homemcp

A smart home as a few named, allowlisted tools for an AI agent, over MCP on
stdio, through Zigbee2MQTT or Home Assistant. A home file lists the devices
the agent may see and, for each one, what it may do. Locks, alarms and
valves go through a separate tool that the client asks a person about every
time. After every action homemcp reads the device back and says whether it
took.

```
agent ──MCP, stdio──▶ homemcp ──MQTT──▶ Zigbee2MQTT ──▶ devices
                        │     └─REST──▶ Home Assistant ──▶ devices
       allowlist, limits, read-back, one log line per call
```

macOS, Linux and Windows. One binary, nothing beyond the Zig standard
library (and libc on macOS). Secrets come from the environment, never from
the home file.

**State: 0.1.0, tested against its own stand-in, `homemcp-sim`, and never
with a real hub or device.** The tests cover Home Assistant's REST API and
Zigbee2MQTT through a real Mosquitto broker. They pass on Linux and on
Windows (on Windows, against a broker running in WSL). The macOS build
compiles but hasn't been run. homemcp has also been run under
[harness](../harness/) with a real model (see [With harness](#with-harness)).
See [Limits](#limits).

## Quick start, without a home

`homemcp-sim` is built alongside homemcp. It plays a flat of eight made-up
devices, as Zigbee2MQTT behind an MQTT broker, or as Home Assistant:

```
$ zig build -Doptimize=ReleaseSafe
$ mosquitto -p 1883 &
$ ./zig-out/bin/homemcp-sim z2m 127.0.0.1:1883 &
$ ./zig-out/bin/homemcp check examples/z2m.ini
The flat (made up by homemcp-sim): 8 devices. Zigbee2MQTT through the broker at 127.0.0.1:1883: connected, bridge online.
living_room_light (Living room light, light): off; may: on, off, brightness
kettle (Kettle plug, plug): off, 0 W; may: off
thermostat (Hall thermostat, climate): 19.5 °C, set to 20 °C, mode heat, heating; may: temperature, mode
front_door (Front door, lock, guarded): locked; may: lock
garage_door (Garage door, cover, guarded): closed; may: close
water_main (Water main, valve, guarded): open; may: close
hall_motion (Hall motion, sensor): nobody there; may: nothing (only seen)
back_door (Back door, sensor): closed; may: nothing (only seen)
```

Without a broker, play Home Assistant instead:

```sh
./zig-out/bin/homemcp-sim ha 8123 not-a-real-token &
HA_TOKEN=not-a-real-token ./zig-out/bin/homemcp check examples/ha.ini
```

`homemcp examples/z2m.ini` then serves MCP on stdin and stdout, the way an
agent starts it. The simulator's sensors change when told to: publish JSON
to `homesim/<friendly name>`, or POST it to `/homesim/<entity id>`, with any
of `occupancy`, `contact`, `available` and `temperature`.

## Tools

| Tool | What it does |
|---|---|
| `home_state` | Every device (or one): its state now, and what may be done with it. Only reads. |
| `home_set` | One action on an ordinary device: a light, switch, plug, thermostat, cover. |
| `home_guarded` | One action on a guarded device: locks, alarms, valves, and anything else marked `guarded = yes`. It carries `_meta["anthropic/requiresUserInteraction"]: true` and `destructiveHint`, so clients that honour them ask a person every time. |
| `home_wait` | Waits until a device's property changes or meets a condition (`open == yes`, `temperature > 21`, `lock == unlocked`), for at most `timeout_s` seconds (default 60, at most 300). Only reads. |

What the agent sees, and what it gets when it asks for more:

```
> home_state
The flat (made up by homemcp-sim). Home Assistant at http://127.0.0.1:8123.
living_room_light (light.living_room, light): off. May: on, off, brightness 1-100%.
kettle (switch.kettle, plug): off, 0 W. May: off. it may switch the kettle off, never on: a kettle switched on unattended is a fire risk.
front_door (lock.front_door, lock): locked. May: lock (guarded: home_guarded). it may lock the door; unlocking is not on the list at all.
hall_motion (binary_sensor.hall_motion, sensor): nobody there. Only seen, never acted on.
...
> home_set {"device":"living_room_light","action":"brightness","value":"30"}
done: living_room_light is on, 29.8% bright
> home_set {"device":"kettle","action":"on"}
kettle may not on; it may: off
> home_guarded {"device":"front_door","action":"unlock"}
front_door may not unlock; it may: lock
> home_set {"device":"thermostat","action":"temperature","value":"28"}
temperature must be from 16 to 24
```

## The home file

An INI file. Relative paths are relative to it.

```ini
[home]
name = The flat
hub = zigbee2mqtt              ; or homeassistant
mqtt = 127.0.0.1:1883          ; zigbee2mqtt: the broker
base = zigbee2mqtt             ; zigbee2mqtt: its base topic
url = http://127.0.0.1:8123    ; homeassistant: its address (http or https)
log = actions.jsonl            ; optional: one line per call

[limits]                       ; the values the agent may choose
temperature = 16 24            ; °C
brightness = 1 100             ; %
position = 0 100               ; %

[device hall_light]
id = Hall light                ; the Zigbee2MQTT friendly name, or the Home Assistant entity id
kind = light
allow = on, off, brightness    ; what the agent may do; seeing it is always allowed
guarded = no                   ; yes: only through home_guarded
modes = off, heat              ; climate: the modes it may choose
note = the one by the stairs   ; shown to the agent
```

| Kind | Actions it can be allowed |
|---|---|
| `light` | `on`, `off`, `brightness` |
| `switch`, `plug` | `on`, `off` |
| `climate` | `temperature`, `mode` |
| `cover` | `open`, `close`, `stop`, `position` |
| `lock` (always guarded) | `lock`, `unlock` |
| `alarm` (always guarded) | `arm_home`, `arm_away`, `disarm` |
| `valve` (always guarded) | `open`, `close` |
| `sensor` | none: only seen |

`homemcp check` names a kind that can't take an action ("a light can't
unlock"), an unknown key, and the line it was on.

Secrets: `HA_TOKEN`, a Home Assistant long-lived access token (Profile,
Security), and `MQTT_USER` and `MQTT_PASSWORD` for the broker.

## What the agent can't do

- **Anything not on a device's `allow` list.** There is no generic "publish
  to a topic" or "call a service" tool. The examples allow the kettle `off`
  and never `on`, the front door `lock` and never `unlock`, the water main
  `close` only.
- **Reach a guarded device through `home_set`.** Locks, alarms and valves are
  always guarded, and `guarded = yes` adds any other device (the examples'
  garage door). They answer only to `home_guarded`.
- **Choose a value outside `[limits]`**, or a climate mode not in `modes`.
- **Act on an offline device.** When Zigbee2MQTT says a device is offline,
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
The research behind these rules, including how Google, Amazon, Apple and
Home Assistant's own assistant treat locks and alarms, is in
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

On 22 Nov 2026 this ran in WSL with harness, a real model through omnigate,
and `homemcp-sim` as Zigbee2MQTT behind Mosquitto:

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
python3, and runs under Git Bash on Windows.

## Limits

- Tested only against `homemcp-sim`. No real Home Assistant, Zigbee2MQTT or
  device has been used yet.
- The MQTT connection is plain TCP, without TLS: keep the broker on this
  machine or a trusted network.
- Home Assistant is asked over REST when needed, not followed over its
  WebSocket API. `home_wait` checks it twice a second.
- Nothing is pushed to the agent. It finds changes with `home_state` or
  `home_wait`.
- Matter devices only through Home Assistant.
- No colours, colour temperature, fans, media players or scenes yet.

## License

MIT, see [LICENSE](LICENSE).
