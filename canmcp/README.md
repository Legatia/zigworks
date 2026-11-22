# canmcp

A car's CAN bus as a few named, read-only tools for an AI agent, over MCP
on stdio. A profile says which SocketCAN interfaces to read, which DBC files
say what the bytes mean, and which signals the agent sees under which names.
The agent asks for `car_readings` and gets "speed: 44.8 km/h, gear:
DI_GEAR_D". It never sees raw frames and has no tool that sends any.

```
car bus ──▶ CAN adapter, listen-only ──SocketCAN──▶ canmcp ──MCP, stdio──▶ agent
                                        DBC decoding, named readings, waits
```

Linux only (SocketCAN). One static binary, nothing beyond the Zig standard
library, no libc.

**State: 0.1.0, tested on recorded traffic and simulators, never on a car.**
It decodes one minute each of a real Tesla Model 3 and a real Hyundai Ioniq
5, from comma.ai's commaCarSegments, consistently (`zig build recordings`).
It has served them over MCP, replayed onto virtual CAN. It has also been
tried on ICSim, a simulated dashboard, and on a simulated diagnostic ECU.
canmcp has also been run under [harness](../harness/) with a real model (see
[With harness](#with-harness)). See [Limits](#limits).

## Quick start, without a car

1. Set up the simulators once, as root, in a Linux with Zig 0.17.1. On
   Windows, WSL 2 works. This puts recordings, DBC files, ICSim and an ECU
   simulator into `/opt/cansim`:

   ```sh
   sudo ../harness/research/cansim/setup.sh
   ```

2. Build and look at a profile:

   ```
   $ zig build -Doptimize=ReleaseSafe
   $ ./zig-out/bin/canmcp check profiles/tesla_model3.ini
   Tesla Model 3 (party bus): 2 buses, 13 readings
   bus party: vcan0 (in logs: can0), tesla_model3_party.dbc: 23 messages, 264 signals
   bus autopilot: vcan2 (in logs: can2), tesla_model3_party.dbc: 23 messages, 264 signals
   reading speed: party DI_speed.DI_vehicleSpeed in km/h (named values)
   reading gear: party DI_systemStatus.DI_gear (named values)
   ...
   diagnostic reads: none in this build (it cannot transmit)
   ```

3. Read a recording without any bus. Here the readings come every 20 seconds
   of the Model 3's minute:

   ```
   $ ./zig-out/bin/canmcp decode profiles/tesla_model3.ini /opt/cansim/data/model3.log 20
   t=20.0 speed=15.68 km/h, gear=DI_GEAR_D, accelerator=22.8 %, brake=Not_Applied, ...
   t=40.0 speed=37.12 km/h, gear=DI_GEAR_D, accelerator=14.4 %, ...
   end: speed=-3.12 km/h, gear=DI_GEAR_R, ...
   199376 frames on the profile's buses, 0 on other interfaces
   ```

4. Or play it onto virtual CAN in real time and start the server the way an
   agent would. `/opt/cansim/bin/replay /opt/cansim/data/model3.log` loops it
   onto `vcan0` and `vcan2`. Then `canmcp profiles/tesla_model3.ini` serves MCP
   on stdin and stdout.

## Tools

| Tool | What it does |
|---|---|
| `car_readings` | The profile's readings as decoded just now, and whether each bus is awake. |
| `bus_status` | For each bus: frames a second, ids seen, time since the last frame (a silent bus means the car is asleep), and error counts. |
| `car_signals` | Searches every signal in the DBC files by part of its name (`door`, `speed`, `temp`) and gives the current value of each one seen on the bus. |
| `car_wait` | Waits until a reading changes or meets a condition (`speed > 30`, `gear == DI_GEAR_P`), for at most `timeout_s` seconds (default 60, at most 300). Other calls are answered during a wait. |
| `car_diag` | Only in builds with diagnostic reads (`-Ddiag=...`): one named read-only request from a fixed table. |

What the agent sees, with the Model 3's recording playing:

```
Tesla Model 3 (party bus):
speed: 44.8 km/h
gear: DI_GEAR_D
accelerator: 23.2 %
brake: Not_Applied
door_open: CLOSED
right_blinker: off
blind_spot_left: WARNING_LEVEL_1
...
bus party (vcan0): awake, 2900 frames a second, 73 ids
bus autopilot (vcan2): awake, 455 frames a second, 17 ids
```

## Profiles

An INI file. Relative paths are relative to the profile.

```ini
[car]
name = Tesla Model 3 (party bus)
silent_seconds = 5            ; a bus quiet this long counts as asleep (default 5)

[bus party]
interface = vcan0             ; the SocketCAN interface
log = can0                    ; its name in candump logs (default: the interface)
dbc = /opt/cansim/dbc/tesla_model3_party.dbc
fd = off                      ; on: read CAN FD frames too

[reading speed]
signal = party DI_speed.DI_vehicleSpeed   ; BUS MESSAGE.SIGNAL
unit = km/h                   ; shown instead of the DBC's unit
note = from the drive inverter
```

`canmcp check` names a missing DBC file, an unknown message or signal, and
the line it was on.

Three profiles come with it:

| Profile | Car | Buses |
|---|---|---|
| [`tesla_model3.ini`](profiles/tesla_model3.ini) | Tesla Model 3/Y: speed, gear, pedals, doors, blinkers, seatbelt, cruise, steering angle, blind spots | the party bus and the autopilot side, from opendbc's `tesla_model3_party.dbc` |
| [`ioniq5.ini`](profiles/ioniq5.ini) | Hyundai Ioniq 5: four wheel speeds, gear, accelerator, doors, seatbelt, blinkers, steering angle, braking | one CAN FD bus, from opendbc's `hyundai_canfd.dbc` |
| [`icsim.ini`](profiles/icsim.ini) | ICSim's simulated dashboard: speed, indicators, four door locks | `vcan0`, with its own small [`dbc/icsim.dbc`](dbc/icsim.dbc) |

The DBC reader covers what opendbc's files use: messages and signals, Intel
and Motorola byte order, signed values, simple multiplexing, value tables
(`VAL_`), and opendbc's `CM_ "IMPORT other.dbc";`. It skips the other lines
(comments, attributes, nodes).

## What it can't do to the car

- **The default build cannot transmit.** Diagnostic reads are compiled in
  only with `zig build -Ddiag=NAME`. Without it, nothing imports the ISO-TP
  code and the binary contains no code that puts a frame on a bus.
- **A diagnostic build sends only what its table names.** Every entry must
  be a read-only service, which is checked at compile time. The agent picks a
  request by name, and none of its arguments reach the bus. The one table so
  far, `sim`, is for the made-up battery ECU of
  [cansim](../harness/research/cansim/): ECU date, battery and trouble codes
  on 0x7E4/0x7EC.
- **The agent gets readings, not frames.** No tool takes or returns raw CAN
  data.

These rules come from the research in
[`agent-beside-the-car.md`](../harness/research/agent-beside-the-car.md):
read freely, write never, and leave anything that moves the car to the
manufacturer's own command path. For commands through a manufacturer's cloud
(charging, locking), see [carcloud](../carcloud/).

## With harness

`mcp.ini` in harness's home:

```ini
[car]
command = /usr/local/bin/canmcp /etc/canmcp/tesla_model3.ini
```

Every tool only reads, so the rules can allow them all without asking:

```
allow mcp car/car_readings *
allow mcp car/bus_status *
allow mcp car/car_signals *
allow mcp car/car_wait *
```

On 22 Nov 2026 this ran in WSL with harness, a real model through omnigate,
and the Model 3's recording looping on virtual CAN. Asked for the car's
speed, gear and doors, the model called `car_readings` and answered "45.3
km/h, in Drive (D), and no door is open". Asked to wait until the speed was
above 40 km/h, it called `car_wait` and reported "after 6.4 s. I saw 40.08
km/h." Other MCP clients start it the same way. In Claude Code:
`claude mcp add car -- canmcp /path/to/profile.ini`.

## On a real car

Not tried yet. What the research says to do:

- **Use an adapter with a SocketCAN driver.** Put it in listen-only mode, so
  it doesn't even acknowledge frames:
  `ip link set can0 type can bitrate 500000 listen-only on`. A
  hardware-silent interface is better still, because software can't turn it
  into a transmitter.
- **Tesla Model 3/Y:** Tesla documents a third-party CAN interface on
  connector X181, at 500 kbps (service bulletin CD-20-17-001). The Model 3
  profile is for that bus.
- **Most other brands** put a security gateway between the OBD port and the
  internal buses. At the OBD port, expect little broadcast data.
- **Sleep.** A bus with no frames for `silent_seconds` is reported as
  asleep. canmcp itself never wakes the car.

## Building and testing

Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/canmcp
zig build test                       # unit tests, then scripts/smoke.sh
zig build recordings                 # the readings on two real cars' recordings
zig build -Ddiag=sim                 # with the simulated ECU's diagnostic reads
```

The unit tests decode made-up frames: Intel and Motorola byte order, signed
values, multiplexed messages, CAN FD and 29-bit ids in candump logs.
`scripts/smoke.sh` runs the binary end to end, over MCP too. Its bus checks
need `vcan0`, and are skipped without it. As root: `modprobe vcan; ip link add
dev vcan0 type vcan; ip link set up vcan0`.

`zig build recordings` checks the readings on cansim's two recordings
against each other. It needs `/opt/cansim` (or `CANSIM=dir`), and is skipped
without it:

- **Tesla:** the drive inverter's speed and the ABS's speed, from two
  different ECUs, agree within 1.5 km/h every second of the minute. The
  largest gap is 1.04 km/h, at about 47 km/h.
- **Ioniq 5:** the driver's door opens and closes, the seatbelt is latched,
  then the car goes into reverse, in that order. While it moves, the four
  wheel speeds stay within 1.5 km/h of each other. The largest spread is
  0.97 km/h.

## Limits

- Linux only. macOS and Windows have no SocketCAN.
- Tested on recordings and simulators only, never connected to a car.
- Extended (29-bit) ids work, but J1939 isn't understood. Ids are matched
  whole, so the same message from another source address counts as another
  message.
- A DBC file with a signal longer than 64 bits is refused. Extended
  multiplexing (`SG_MUL_VAL_`) isn't read.
- The ISO-TP and diagnostic code has been tested against the simulated ECU
  only. No table for a real car's ECUs exists yet.
- Readings are what the DBC files say. opendbc's files are reverse-engineered
  and can be wrong for a given model year.

## License

MIT, see [LICENSE](LICENSE). The DBC files the profiles use come from
[opendbc](https://github.com/commaai/opendbc) (MIT) through cansim's
`setup.sh`, and aren't in this repository.
