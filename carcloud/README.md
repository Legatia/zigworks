# carcloud

A car, through the carmaker's cloud, as a few named tools for an AI agent,
over MCP on stdio. It reads battery, range, charging and locks through
[Smartcar](https://smartcar.com)'s API, which covers many brands, Tesla and
VW Group included, or a Tesla straight through Tesla's Fleet API, which
also warms it (climate and seat heating). It sends only the commands the
owner allows (charging, charge limit, lock; with a Tesla, climate and
seat heating), within limits on how many and how often. Unlocking is a
tool of its own, and only if the owner turns it on.

```
agent ──MCP, stdio──▶ carcloud ──https──▶ Smartcar v3 ──▶ the carmaker ──▶ the car
            allowlist, ranges, daily cap, log
                     carcloud ──https──▶ Tesla's Fleet API ─────────────▶ the car   (reading)
                              ──https──▶ tesla-http-proxy (signs) ──▶ Fleet API ──▶ the car   (commands)
```

macOS, Linux and Windows. One binary, nothing beyond the Zig standard
library (and libc on macOS). Nothing is wired into the car: commands go
through the carmaker's own authenticated path, the one its app uses.

**State: 0.1.0, written from Smartcar's and Tesla's documentation
(November 2026) and tested only against `carcloud-sim`, stand-ins built
from the same documentation.** It has never talked to Smartcar, Tesla or a
car. On macOS: 27 unit tests (the stand-ins' own among them) and a smoke
script of 53 checks (24 Smartcar, 29 Tesla), Debug and ReleaseSafe; Linux
and Windows ran the Smartcar part before. The Smartcar part has also been
run under [harness](../harness/) with a real model (see
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

A made-up Tesla, asleep at first, behind stand-ins for Tesla's sign-in, the
Fleet API and tesla-http-proxy (TLS with a CA it makes; it writes the CA
and a car file for itself into the folder):

```
$ ./zig-out/bin/carcloud-sim tesla /tmp/tesla not-a-real-secret &
$ TESLA_CLIENT_SECRET=not-a-real-secret ./zig-out/bin/carcloud login /tmp/tesla/car.ini
Open this link, sign in to Tesla and allow the application:

http://127.0.0.1:52811/oauth2/v3/authorize?response_type=code&client_id=sim-tesla-client&…

Then paste here the address your browser ended on (it starts with https://example.com/carcloud-callback):
https://example.com/carcloud-callback?locale=en-US&code=NA_code-…&state=…
Signed in. The sign-in is kept in /tmp/tesla/car.ini.token (readable by you only; carcloud renews it).
The account's cars:
  5YJ3SIM0000000001  The made-up Tesla  (asleep)
The car file's vin is among them.
$ ./zig-out/bin/carcloud check /tmp/tesla/car.ini
The made-up Tesla:
asleep: yes; reading it would wake it (car_status with wake true wakes it; 3 of 3 wakes left in 24 hours)
commands the owner allowed: charge_start, charge_stop, charge_limit, climate, seat_heat
sign-in: kept in /tmp/tesla/car.ini.token
virtual key: paired with the car
commands: signed through tesla-http-proxy at https://localhost:52812 (its certificate accepted)
```

(The stand-in's sign-in page signs in at once and redirects: in another
terminal, `curl -s -o /dev/null -w '%{redirect_url}\n' 'LINK'` prints the
address to paste.)

## Tools

| Tool | What it does |
|---|---|
| `car_status` | Battery, range, charging, plugged in, charge limit, locks, odometer, cabin temperature, and location if the car file allows it. Says how old the data is. Only reads. |
| `car_command` | One of the commands the car file allows: `charge_start`, `charge_stop`, `charge_limit` (with `percent`), `lock`. Waits for the car to confirm. |
| `car_unlock` | Only when the car file lists `unlock`. Carries `_meta["anthropic/requiresUserInteraction"]: true` and `destructiveHint`, so clients that honour them ask a person every time. |
| `car_climate` | A Tesla, only when the car file lists `climate`: `{"state": "on"}`, `"off"`, a `temperature` (°C, within `climate_temp`), or both. Wakes the car first if it sleeps; answers with what the car reads back. |
| `car_seat_heat` | A Tesla, only when the car file lists `seat_heat`: `{"seat": "front_left", "level": 3}` (front_left, front_right, rear_left, rear_center, rear_right; 0 is off). Read back. |

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

With a Tesla, `car_status` reads live, and a sleeping car isn't woken to be
read: it answers that it sleeps, unless asked with `{"wake": true}`, at
most `wakes_per_day` times (3) in 24 hours, as each wake costs.

```
> car_climate {"state":"on","temperature":30}
the temperature must be from 18 to 24 °C
> car_climate {"state":"on","temp":21}
car_climate has no field temp: it takes state (on or off) and temperature (°C)
> car_climate {"state":"on","temperature":21.5}
Climate on, set to 21.5 °C; inside 4.5 °C, outside -3 °C.
> car_seat_heat {"seat":"front_left","level":3}
Front left seat heating at 3 of 3.
```

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

A Tesla's car file (examples/tesla.ini):

```ini
[car]
backend = tesla
name = The Model 3
vin = 5YJ3E7EB0KF000000           ; carcloud login lists your cars
client_id = 0a1b2c3d-...          ; your developer application's
redirect_uri = https://example.com/callback   ; one your application lists
region = eu                       ; eu, na (North America, Asia-Pacific) or cn
command_api = https://localhost:4443          ; tesla-http-proxy, which signs commands
command_ca = proxy-cert.pem       ; its certificate
token = car.ini.token             ; the sign-in (the default: the car file's name + .token)
allow = climate, seat_heat, charge_start, charge_stop, charge_limit
climate_temp = 18 24              ; the temperatures the agent may set, °C (Tesla's: 15 to 28)
charge_limit = 60 90
commands_per_day = 10             ; every command counts, climate and seats too
min_seconds_between = 60
wakes_per_day = 3                 ; car_status may wake the car this often
location = no
log = carcloud.jsonl
```

A car file that allows commands without `command_api` is refused when it
is read: Tesla takes commands only signed. `climate` or `seat_heat` in a
Smartcar file is refused too (Smartcar's v3 has no climate).

## What the agent can't do

- **Send a command the car file doesn't allow.** There is no generic
  pass-through to Smartcar.
- **Unlock through `car_command`.** Unlocking exists only as `car_unlock`,
  only if `allow` lists it, and is marked to ask a person every time. The
  example car file doesn't list it.
- **Set a charge limit outside `charge_limit`, or a temperature outside
  `climate_temp`.**
- **Send a field a Tesla tool doesn't take.** `car_climate` and
  `car_seat_heat` refuse an unknown field (a misspelt one would otherwise
  be lost), and nothing is sent.
- **Wake a Tesla more than `wakes_per_day` times** to read it.
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

A Tesla's log lines carry the tool's fields after the message
(`"state":"on","temperature":21.5`, `"seat":"front_left","level":3`), and
wakes for reading are lines of their own (`"command":"wake"`).

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

A Tesla needs no secret once `carcloud login` has run: mcp.ini's section
is the command alone. harness offers its **warm-car** routine when the car
server is called `car` and has `car_climate`: 30 minutes before a morning
leave-by in the calendar, when the car reads below `[butler] warm_below`
outside, "Warm the car for 8:10?" [Warm it] (harness's README).

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

## With a Tesla

Not tried with a real car yet. What Tesla's documentation and the research
notes ([agent-beside-the-car.md](../harness/research/agent-beside-the-car.md))
say (November 2026):

- **Your own developer application** on developer.tesla.com: its client id
  goes in the car file, its secret in `TESLA_CLIENT_SECRET` for `carcloud
  login` (a running carcloud doesn't need it: Tesla's refresh takes the id
  alone). Register a redirect URI; any page will do, since you paste the
  address the browser ends on. The application must be registered for your
  region once (Tesla's partner registration, with a public key on your
  domain at `/.well-known/appspecific/com.tesla.3p.public-key.pem`).
- **Commands are signed end to end.** Tesla's vehicle command protocol has
  one official implementation, Tesla's Go
  [vehicle-command](https://github.com/teslamotors/vehicle-command). carcloud
  doesn't reimplement it: run its `tesla-http-proxy` beside carcloud, with
  the application's private key, and point `command_api` at it. The proxy
  serves HTTPS with its own certificate; give carcloud that certificate as
  `command_ca` (checked, host name included; there is no way to turn the
  check off). One that names `localhost`:

  ```
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 \
    -subj '/CN=localhost' -addext 'subjectAltName = DNS:localhost' \
    -keyout proxy-key.pem -out proxy-cert.pem -sha256 -days 3650
  tesla-http-proxy -tls-key proxy-key.pem -cert proxy-cert.pem \
    -key-file fleet-key.pem -port 4443
  ```

- **The virtual key.** The car takes the application's commands once its
  owner has paired the key: open `https://tesla.com/_ak/YOUR-DOMAIN` on the
  phone with the Tesla app. `carcloud check` says whether Tesla has it as
  paired; until then commands come back "the car doesn't know the
  application's key yet".
- **Sleep and cost.** A sleeping car answers no `vehicle_data`; waking it
  costs a wake and some battery, so `car_status` wakes it only when asked.
  A command wakes it first (up to 60 s), as part of that command. Tesla
  bills reads, commands and wakes per car beyond a monthly credit for
  individual developers; its limits per car are about 60 reads, 30
  commands and 3 wakes a minute.
- **Seats** are named as Tesla's are: front_left is the driver's in a
  left-hand-drive car, front_right in a right-hand-drive one.

## Building and testing

Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/carcloud and carcloud-sim
zig build test                       # unit tests, then scripts/smoke.sh
```

`scripts/smoke.sh` runs the binary over MCP against `carcloud-sim`. With
Smartcar that covers charging, a lock that Smartcar finishes later (202,
then polled), an asleep car, a plug that isn't connected, the plan's
command limit, the daily cap, and unlocking when allowed. With a Tesla:
`carcloud login` (a pasted address from another sign-in refused, the
token file owner-only), `check` (asleep, not woken; the key; the proxy's
certificate accepted, and refused without its CA), status asleep and
woken, climate and seat heating signed and read back, a temperature out
of range and an unknown field refused before anything is sent, a command
waking the car first, an unpaired key, an expired access token renewed
and the rotated refresh token kept, the daily cap, the wake cap, no
command ever reaching the Fleet API unsigned, and no token in anything
carcloud said. It needs python3, and runs under Git Bash on Windows.

## Limits

- Tested only against `carcloud-sim`, which follows Smartcar's and Tesla's
  documentation and could share their mistakes or gaps (Tesla's command
  and field names among them: `set_temps` with `driver_temp`,
  `remote_seat_heater_request` with `heater` and `level`).
- Tesla's commands need tesla-http-proxy running beside carcloud: the
  signing isn't done in carcloud itself. No BLE (`tesla-control`), no Fleet
  Telemetry streaming, no scheduled departure.
- No BMW CarData or other makes' own APIs yet. No climate through
  Smartcar: its v3 has no such command.
- Smartcar's token is fetched with client credentials and kept until a
  minute before it expires; Tesla's access token likewise, renewed with the
  kept refresh token. Two carcloud processes renewing at the same moment
  can leave one with a refresh token Tesla has already replaced: `carcloud
  login` again. An outage is reported to the agent, not retried.
- The daily caps count from carcloud's start: a restart begins them anew.

## License

MIT, see [LICENSE](LICENSE). Smartcar is a trademark of Smartcar, Inc.;
Tesla is a trademark of Tesla, Inc.; carcloud is not made or endorsed by
either.
