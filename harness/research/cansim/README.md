# CAN simulators for a desk without a car

For the research's Stage 0. `setup.sh` (as root, in a Linux with Zig 0.17.1 and Python 3.12; tested on Ubuntu 24.04 under WSL 2, whose kernel has virtual CAN) puts everything into `/opt/cansim`, downloading about 15 MB:

| What | Where it comes from | Run (as root) |
|---|---|---|
| One minute of real CAN traffic from a Hyundai Ioniq 5: 3 buses, about 5,000 frames a second, 83% of them CAN FD | [commaCarSegments](https://huggingface.co/datasets/commaai/commaCarSegments), comma.ai, MIT | `/opt/cansim/bin/replay /opt/cansim/data/ioniq5.log` |
| One minute from a Tesla Model 3: 2 buses, about 3,300 frames a second | the same | `/opt/cansim/bin/replay /opt/cansim/data/model3.log` |
| A dashboard and its controls: speed, indicators, doors | [ICSim](https://github.com/zombieCraig/ICSim), GPL-3.0 | `/opt/cansim/bin/icsim-demo` |
| A diagnostic ECU, set up as a made-up battery on 0x7E4/0x7EC | [uds-server-simulator](https://github.com/Honinb0n/uds-server-simulator), GPL-2.0 | `/opt/cansim/bin/uds-ecu` |
| `candump`, `cansend`, `canplayer`, `cangen`, `isotpsend`, `isotprecv` | can-utils, from Ubuntu | |
| DBC files for the two cars, in `/opt/cansim/dbc`: what the bytes on those buses mean (canmcp's profiles use them) | [opendbc](https://github.com/commaai/opendbc), MIT, at a fixed commit, checked against sha256 | `canmcp check ../../../canmcp/profiles/tesla_model3.ini` |

`replay` puts bus N of a log on `vcanN` in real time, again and again (`replay LOG 1` plays it once). Watch with `candump vcan1`, or with cantap: `cantap --fd vcan1` (the Ioniq 5's buses are mostly CAN FD; without `--fd` cantap sees only the classic frames).

**What the recordings are.** They are the buses openpilot's harness connects to, behind the windscreen camera, not what a tap at the OBD port would see. opendbc's DBC files name their signals. `/opt/cansim/data/*/segment` says which minute each is. For other cars or minutes, the dataset's `database.json` (9.4 MB) lists 230 platforms, including Kia EV6, Bolt EUV, Rivian R1, Model Y, Niro EV, Leaf, Mach-E and F-150 Lightning, and `rlog2candump.py SCHEMA PYLIB RLOG.zst OUT.log` converts any of them.

**The ECU simulator.** It answers only frames padded to 8 bytes (cantap's poller: `.pad = 0xaa`; can-utils: `-p AA`). Its identifiers are in `/opt/cansim/uds/config.json`, made up. It is built without optimisation and started with `-e BMS`, because its C has undefined behaviour: built optimised it answers every request with "service 0x00 not supported", and without `-e` it reads an uninitialised name. With cantap's poller, `zig build test-uds-sim` in `../cantap` checks it, with `uds-ecu` running.

**ICSim** shows its two windows through WSLg on Windows 11, or any X11 or Wayland display.

## What was checked, 22 Nov 2026

On WSL 2 (Linux 6.18.58, Ubuntu 24.04, Zig 0.17.1):

- **The two minutes** converted without loss:
  - Ioniq 5: 302,892 frames, 250,927 of them CAN FD;
  - Model 3: 199,376 frames.
- **Replayed** onto `vcan0`–`vcan2`, candump and cantap counted the same frames on the Ioniq 5's bus 1, about 2,800 a second. A cantap filter on the Tesla's `257` got its 50 a second.
- **ICSim**, on a headdesk desktop: its controls sent frames on 36 ids, and accelerating changed the speed frame `244`. Its dashboard drew. It was not tried on the WSLg display.
- **The ECU simulator:**
  - `isotpsend`/`isotprecv` and cantap's poller read its identifiers, including a 51-byte answer over eight frames;
  - it refused `19 02 FF` with `7F 19 11`;
  - it ignored unpadded requests.

- **The DBC files:** `setup.sh`, run again with them removed, fetched all three and they matched their sha256.

Not checked: running `setup.sh` on a fresh distro (it was run where the parts had been set up by hand), and other architectures than x86_64.
