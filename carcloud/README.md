# carcloud

A car, through the carmaker's cloud, as a few named tools for an AI agent,
over MCP on stdio. It reads battery, range, charging and locks through
[Smartcar](https://smartcar.com)'s API, which covers many brands, Tesla and
VW Group included. It sends only the commands the owner allows (charging,
charge limit, lock), within limits on how many and how often. Unlocking is
a tool of its own, and only if the owner turns it on.

```
agent ──MCP, stdio──▶ carcloud ──https──▶ Smartcar v3 ──▶ the carmaker ──▶ the car
            allowlist, charge-limit range, daily cap, log
```

macOS, Linux and Windows. One binary, nothing beyond the Zig standard
library (and libc on macOS). Nothing is wired into the car: commands go
through the carmaker's own authenticated path, the one its app uses.

**State: 0.1.0, written from Smartcar's documentation (November 2026) and
tested only against `carcloud-sim`, a stand-in built from the same
documentation.** It has never talked to Smartcar or a car. The tests pass on
Linux and Windows. The macOS build compiles but hasn't been run. carcloud
has also been run under [harness](../harness/) with a real model (see
[With harness](#with-harness)). See [Limits](#limits).

## Quick start, without a car

`carcloud-sim` is built alongside carcloud. It plays Smartcar's v3 API with
one made-up electric car:

```
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/carcloud-sim 8740 not-a-real-secret &
$ SMARTCAR_CLIENT_SECRET=not-a-real-secret ./zig-out/bin/carcloud check examples/sim.ini
The made-up car:
battery: 64%
range: 294.4 km
charging: no
plugged in: yes
charge limit: 80%
locked: yes
odometer: 18234.6 km
inside: 14.5 °C
data: from 30 minutes ago
commands the owner allowed: charge_start, charge_stop, charge_limit, lock
```

`carcloud examples/sim.ini` then serves MCP on stdin and stdout, the way an
agent starts it.

## Tools

| Tool | What it does |
|---|---|
| `car_status` | Battery, range, charging, plugged in, charge limit, locks, odometer, cabin temperature, and location if the car file allows it. Says how old the data is. Only reads. |
| `car_command` | One of the commands the car file allows: `charge_start`, `charge_stop`, `charge_limit` (with `percent`), `lock`. Waits for the car to confirm. |
| `car_unlock` | Only when the car file lists `unlock`. Carries `_meta["anthropic/requiresUserInteraction"]: true` and `destructiveHint`, so clients that honour them ask a person every time. |

```
> car_command {"command":"charge_limit","percent":95}
the charge limit must be from 60 to 90 %
> car_command {"command":"charge_limit","percent":85}
done: charge limit 85%, confirmed by the car
> car_command {"command":"unlock"}
unlocking is not done through car_command
```

When the car or Smartcar refuses, the agent gets the reason in plain words,
with Smartcar's code. For example: "the car can't do it now ...
CHARGING_PLUG_NOT_CONNECTED", "ASLEEP", or "the Smartcar plan does not allow
it ... VEHICLE_REQUEST_LIMIT".

## The car file

An INI file. Relative paths are relative to it.

```ini
[car]
name = The Model 3
vehicle_id = 0d3a...          ; from Smartcar's Dashboard, after Connect
user_id = 5a2b...             ; the Smartcar user who connected the car
client_id = ...               ; the application's id; its secret is SMARTCAR_CLIENT_SECRET
allow = charge_start, charge_stop, charge_limit, lock   ; unlock only if listed
charge_limit = 60 90          ; the limits the agent may set, %
commands_per_day = 10         ; at most this many commands in any 24 hours
min_seconds_between = 60      ; and at least this long between two
location = no                 ; yes: car_status shows where the car is
log = carcloud.jsonl          ; optional: one line per call
```

`carcloud check` names an unknown command ("no command called open_trunk"),
a missing secret, and credentials Smartcar refuses.

## What the agent can't do

- **Send a command the car file doesn't allow.** There is no generic
  pass-through to Smartcar.
- **Unlock through `car_command`.** Unlocking exists only as `car_unlock`,
  only if `allow` lists it, and is marked to ask a person every time. The
  example car file doesn't list it.
- **Set a charge limit outside `charge_limit`.**
- **Send more than `commands_per_day` in 24 hours, or two within
  `min_seconds_between`.** carcloud refuses these itself, before Smartcar's
  own limits.
- **Find the car.** Location is off unless `location = yes`.
- **Act off the record.** With `log =`, every `car_command` and `car_unlock`
  call is one JSON line: what was asked, and whether it was done, refused,
  failed, still pending or of unknown outcome. Refusals are logged too:

  ```json
  {"time":"2026-11-22T11:21:27Z","vehicle":"0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11","command":"unlock","percent":null,"result":"refused","message":"unlocking is not done through car_command"}
  ```

A command counts as done only when Smartcar reports `SUCCESS`. carcloud asks
it to wait up to 60 seconds (`Prefer: wait=60`), then polls the command for
up to about 90 seconds in all. If Smartcar gives up (`EXPIRED`), the agent is
told that whether it happened is unknown.

## With harness

`mcp.ini` in harness's home. The application's secret comes from harness's
secret store, and commands are asked about each time (no rule allows them):

```ini
[cloud]
command = /usr/local/bin/carcloud /etc/carcloud/car.ini
; stored with `harness secret add smartcar`
secret = SMARTCAR_CLIENT_SECRET:smartcar
```

```
allow mcp cloud/car_status *
```

With `unlock` allowed, also mark it as harness's money tool, so it is asked
about every time, never given to helpers and never run from a schedule:
`money = car_unlock` and `amount = car_unlock:none`.

On 22 Nov 2026 this ran in WSL with harness, a real model through omnigate,
and `carcloud-sim`. Asked for the battery level and to set the charge limit
to 80%, the model read `car_status` without asking. harness asked about
`car_command`, and the model answered: "The car's battery is at 64%. That
reading is 31 minutes old. The charge limit is now 80%, and the car
confirmed it."

In Claude Code: `claude mcp add --env SMARTCAR_CLIENT_SECRET=... cloud --
carcloud /path/to/car.ini`. That stores the secret in Claude Code's
settings.

## With a real car

Not tried yet. What Smartcar's documentation says (November 2026):

- **Connect the car once** through Smartcar Connect, with the scopes
  `read_battery read_charge read_security read_odometer read_thermometer
  control_charge control_security`, plus `read_location` for `location =
  yes`. Then put its vehicle and user ids into the car file, and drop
  `api` and `token_url`, which point the example at `carcloud-sim`.
- **`control_security` grants unlocking as well as locking.** That's why
  carcloud keeps unlocking out of `car_command`.
- **Smartcar's free plan allows reading one real car, but no commands.**
  Its paid plans start at $1.99 per vehicle per month, with 100 commands a
  month across all vehicles.
- **The data can be a day old.** Without webhooks, Smartcar collects a car's
  data roughly once a day. `car_status` always says how old it is.
- **Brands differ.** In Europe, Tesla supports all of carcloud's commands,
  once the owner has installed Smartcar's virtual key in the Tesla app. VW
  Group cars support only starting and stopping charging: no lock status, no
  location, no charge limit.
- **Smartcar's v2.0 API is retired on 1 Dec 2026.** carcloud uses v3 only.

## Building and testing

Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/carcloud and carcloud-sim
zig build test                       # unit tests, then scripts/smoke.sh
```

`scripts/smoke.sh` runs the binary over MCP against `carcloud-sim`. That
covers charging, a lock that Smartcar finishes later (202, then polled), an
asleep car, a plug that isn't connected, the plan's command limit, the daily
cap, and unlocking when allowed. It needs python3, and runs under Git Bash on
Windows.

## Limits

- Tested only against `carcloud-sim`, which follows Smartcar's documentation
  and could share its mistakes or gaps.
- Smartcar only. No Tesla Fleet API, BMW CarData or local Bluetooth yet.
- No climate or preconditioning: Smartcar's v3 has no such command.
- The token is fetched with client credentials and kept until a minute
  before it expires. A Smartcar outage is reported to the agent, not
  retried.

## License

MIT, see [LICENSE](LICENSE). Smartcar is a trademark of Smartcar, Inc.;
carcloud is not made or endorsed by Smartcar.
