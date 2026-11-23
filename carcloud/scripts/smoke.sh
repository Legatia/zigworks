#!/bin/sh
# carcloud end to end over MCP, against carcloud-sim (a stand-in for
# Smartcar's v3 API). Needs python3. Usage: smoke.sh CARCLOUD CARCLOUD_SIM
set -u
B=$1
S=$2
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
# native Windows binaries need C:/... paths, not MSYS's /tmp/...
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) T=$(cd "$T" && pwd -W) ;; esac
PIDS=""
cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
n=0
fail=0
check() {
	n=$((n + 1))
	if eval "$2"; then echo "ok $n - $1"; else
		echo "not ok $n - $1"
		fail=1
	fi
}
if ! command -v python3 >/dev/null; then
	echo "# python3 missing: skipped"
	exit 0
fi
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$S" "$PORT" smoke-secret >"$T/sim.out" 2>&1 &
PIDS="$PIDS $!"
python3 -c '
import socket, sys, time
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close(); sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)' "$PORT"
# awk, not sed: BSD sed (macOS) has no \n in replacements
awk -v port="$PORT" -v logf="$T/actions.jsonl" '
{ gsub(/8740/, port) }
/^min_seconds_between = 60/ { print "min_seconds_between = 0"; print "log = " logf; next }
/^commands_per_day = 10/ { print "commands_per_day = 5"; next }
{ print }' examples/sim.ini >"$T/car.ini"
sed -e "s|allow = charge_start, charge_stop, charge_limit, lock|allow = unlock|" "$T/car.ini" >"$T/unlock.ini"
export SMARTCAR_CLIENT_SECRET=smoke-secret

check "version" '"$B" version | grep -q "^carcloud "'
printf '[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = open_trunk\n' >"$T/bad.ini"
check "a command that does not exist is named" '! "$B" check "$T/bad.ini" 2>"$T/err" && grep -q "no command called open_trunk" "$T/err"'
check "no secret, no start" '! env -u SMARTCAR_CLIENT_SECRET "$B" check "$T/car.ini" 2>"$T/err" && grep -q SMARTCAR_CLIENT_SECRET "$T/err"'
check "a wrong secret is named" '! SMARTCAR_CLIENT_SECRET=wrong "$B" check "$T/car.ini" 2>"$T/err" && grep -q "Smartcar refused the credentials" "$T/err"'
check "check shows the car, and how old its data is" '"$B" check "$T/car.ini" >"$T/c" && grep -q "battery: 64%" "$T/c" && grep -q "data: from 30 minutes ago" "$T/c"'
sed -e "s|^log = .*|log = nowhere/actions.jsonl|" "$T/car.ini" >"$T/badlog.ini"
check "a log that can't be opened is named" '! "$B" check "$T/badlog.ini" 2>"$T/err" && grep -q "can.t open the log .*nowhere" "$T/err"'

cat >"$T/mcp.py" <<'EOF'
import json, os, queue, subprocess, sys, threading, time, urllib.request

binary, car, unlock_car, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
n = 0
failed = False

class Mcp:
    def __init__(self, path):
        self.p = subprocess.Popen([binary, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.lines = queue.Queue()
        threading.Thread(target=self.read_lines, daemon=True).start()
        self.i = 0
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
        self.recv(0)
    def read_lines(self):  # a thread, not select(): Windows can't select on pipes
        for line in iter(self.p.stdout.readline, b""):
            self.lines.put(line)
        self.lines.put(None)
    def send(self, o):
        self.p.stdin.write((json.dumps(o) + "\n").encode())
        self.p.stdin.flush()
    def recv(self, want, timeout=60.0):
        end = time.time() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.0, end - time.time()))
            except queue.Empty:
                return None
            if line is None:
                self.lines.put(None)
                return None
            m = json.loads(line)
            if m.get("id") == want:
                return m
    def tools(self):
        self.i += 1
        self.send({"jsonrpc": "2.0", "id": self.i, "method": "tools/list"})
        return self.recv(self.i)["result"]["tools"]
    def call(self, name, args=None):
        self.i += 1
        self.send({"jsonrpc": "2.0", "id": self.i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
        m = self.recv(self.i)
        return (m["result"]["content"][0]["text"], m["result"]["isError"]) if m else ("(no answer)", True)
    def close(self):
        self.p.stdin.close()
        return self.p.wait(timeout=10)

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - mcp: {name}" + ("" if ok else f" ({detail[:400]})"))
    failed = failed or not ok

def sim(**state):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/sim/state", data=json.dumps(state).encode(), method="POST", headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5).read()

m = Mcp(car)
names = [t["name"] for t in m.tools()]
check("tools: status and command, no unlock", names == ["car_status", "car_command"], str(names))
text, err = m.call("car_status")
check("status", not err and "battery: 64%" in text and "plugged in: yes" in text and "locked: yes" in text and "location" not in text, text)
text, err = m.call("car_command", {"command": "charge_limit", "percent": 95})
check("a charge limit outside the owner's range is refused", err and "from 60 to 90" in text, text)
text, err = m.call("car_command", {"command": "charge_limit", "percent": 85})
check("the charge limit set", not err and text == "done: charge limit 85%, confirmed by the car", text)
text, err = m.call("car_command", {"command": "charge_start"})
check("charging started", not err and "done: charge_start" in text, text)
time.sleep(2.5)
text, err = m.call("car_status")
check("the status shows it charging, and a fresh report", "charging: yes" in text and "charge limit: 85%" in text and "from the last minutes" in text, text)
sim(plugged=False)
text, err = m.call("car_command", {"command": "charge_start"})
check("the car's own refusal, said plainly", err and "the car can't do it now" in text and "CHARGING_PLUG_NOT_CONNECTED" in text, text)
sim(locked=False)
t0 = time.time()
text, err = m.call("car_command", {"command": "lock"})
check("a lock is waited out to its end (202, then polled)", not err and text == "done: lock, confirmed by the car" and time.time() - t0 >= 2, text)
text, err = m.call("car_command", {"command": "unlock"})
check("unlocking is not a car_command", err and "not done through car_command" in text, text)
text, err = m.call("car_unlock")
check("no car_unlock tool unless allowed", err and "no tool called car_unlock" in text, text)
sim(asleep=True)
text, err = m.call("car_command", {"command": "charge_stop"})
check("an asleep car", err and "ASLEEP" in text, text)
sim(asleep=False)
text, err = m.call("car_command", {"command": "charge_stop"})
check("the sixth command in a day is refused by carcloud itself", err and "5 commands in the last 24 hours is the limit" in text, text)
check("exits when stdin closes", m.close() == 0)

u = Mcp(unlock_car)
tools = u.tools()
names = [t["name"] for t in tools]
unlock = next((t for t in tools if t["name"] == "car_unlock"), {})
check("with unlock allowed: its own tool, asking for a person", names == ["car_status", "car_unlock"] and unlock.get("_meta", {}).get("anthropic/requiresUserInteraction") is True, str(tools)[:300])
sim(commands_left=0)
text, err = u.call("car_unlock")
check("the plan's limit, said plainly", err and "the Smartcar plan does not allow it" in text and "VEHICLE_REQUEST_LIMIT" in text, text)
sim(commands_left=100)
text, err = u.call("car_unlock")
check("unlocked", not err and text == "done: unlock, confirmed by the car", text)
u.close()
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/mcp.py" "$B" "$T/car.ini" "$T/unlock.ini" "$PORT" || fail=1
check "the log: one line per command, refusals too" '[ "$(grep -c "\"result\":\"done\"" "$T/actions.jsonl")" = 4 ] && grep -q "\"result\":\"refused\"" "$T/actions.jsonl" && grep -q "\"result\":\"failed\"" "$T/actions.jsonl"'
check "... the agent's attempts too: a limit out of range, an unlock" 'grep -q "\"command\":\"charge_limit\",\"percent\":95,\"result\":\"refused\"" "$T/actions.jsonl" && grep -q "\"command\":\"unlock\",\"percent\":null,\"result\":\"refused\",\"message\":\"unlocking is not done through car_command\"" "$T/actions.jsonl"'

# ---- a Tesla, through carcloud-sim's stand-ins for Tesla's sign-in, its
# Fleet API and tesla-http-proxy (TLS, its own CA) ----
"$S" tesla "$T/tesla" tesla-secret >"$T/tesla-sim.out" 2>&1 &
PIDS="$PIDS $!"
i=0
while [ ! -s "$T/tesla/ports" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
awk -v logf="$T/tesla.jsonl" '
/^min_seconds_between = 60/ { print "min_seconds_between = 0"; print "log = " logf; next }
/^commands_per_day = 10/ { print "commands_per_day = 6"; next }
/^wakes_per_day = 3/ { print "wakes_per_day = 2"; next }
{ print }' "$T/tesla/car.ini" >"$T/tesla/smoke.ini"
TC="$T/tesla/smoke.ini"
unset SMARTCAR_CLIENT_SECRET
printf '[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = climate\n' >"$T/climate.ini"
grep -v "^command_api" "$TC" >"$T/noproxy.ini"
check "tesla: not signed in yet, said plainly" '! "$B" check "$TC" 2>"$T/err" && grep -q "not signed in to Tesla yet: run carcloud login" "$T/err"'
check "tesla: login needs the application's secret" '! env -u TESLA_CLIENT_SECRET "$B" login "$TC" </dev/null >"$T/out" 2>"$T/err" && grep -q "TESLA_CLIENT_SECRET is not set" "$T/err"'
check "tesla: no climate in a Smartcar car file" '! "$B" check "$T/climate.ini" 2>"$T/err" && grep -q "climate: Smartcar.s v3 has no climate or seat heating" "$T/err"'
check "tesla: commands without the signing proxy are refused when the file is read" '! "$B" check "$T/noproxy.ini" 2>"$T/err" && grep -q "Tesla takes them only signed: run tesla-http-proxy" "$T/err"'

cat >"$T/tesla.py" <<'EOF2'
import json, os, queue, stat, subprocess, sys, threading, time, urllib.request, urllib.error

binary, car, tdir = sys.argv[1], sys.argv[2], sys.argv[3]
api, proxy = [int(x) for x in open(os.path.join(tdir, "ports")).read().split()]
token_file = car + ".token"
n = 0
failed = False
said = []  # everything carcloud said, to look for secrets in

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - tesla: {name}" + ("" if ok else f" ({str(detail)[:400]})"))
    failed = failed or not ok

def sim(**state):
    req = urllib.request.Request(f"http://127.0.0.1:{api}/sim/state", data=json.dumps(state).encode(), method="POST", headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5).read()

def counters():
    return json.loads(urllib.request.urlopen(f"http://127.0.0.1:{api}/sim/state", timeout=5).read())

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None

def login(paste=None):
    env = dict(os.environ, TESLA_CLIENT_SECRET="tesla-secret")
    p = subprocess.Popen([binary, "login", car], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    out = b""
    while b"Then paste here" not in out:
        line = p.stdout.readline()
        if not line:
            break
        out += line
    link = next((l for l in out.decode().splitlines() if l.startswith("http")), "")
    where = ""
    try:
        urllib.request.build_opener(NoRedirect).open(link, timeout=5)
    except urllib.error.HTTPError as e:
        where = e.headers.get("location", "")
    rest, err = p.communicate((paste(where) if paste else where).encode() + b"\n", timeout=30)
    text = (out + rest).decode() + err.decode()
    said.append(text)
    return p.returncode, text, link

code, text, link = login(lambda w: w.replace("state=", "state=x"))
check("a pasted address from another sign-in is refused", code == 1 and "from another sign-in" in text and not os.path.exists(token_file), text)
code, text, link = login()
check("login: the link asks for reading and commands, not location", "scope=openid%20offline_access%20vehicle_device_data%20vehicle_cmds%20vehicle_charging_cmds&" in link, link)
check("login: signed in, the car listed", code == 0 and "Signed in." in text and "5YJ3SIM0000000001  The made-up Tesla  (asleep)" in text and "The car file's vin is among them." in text, text)
mode = stat.S_IMODE(os.stat(token_file).st_mode) if os.path.exists(token_file) else -1
check("login: the sign-in kept in a file only the owner reads", mode == 0o600 or os.name == "nt", oct(mode))
first_refresh = json.load(open(token_file))["refresh_token"] if os.path.exists(token_file) else "?"

def run_check(path):
    p = subprocess.run([binary, "check", path], capture_output=True, timeout=60)
    t = p.stdout.decode() + p.stderr.decode()
    said.append(t)
    return p.returncode, t

code, text = run_check(car)
check("check: asleep, not woken; the key paired; the proxy's certificate accepted", code == 0 and "asleep: yes; reading it would wake it" in text and "virtual key: paired with the car" in text and "its certificate accepted" in text and counters()["wakes"] == 0, text)
noca = os.path.join(tdir, "noca.ini")
open(noca, "w").write("".join(l for l in open(car) if not l.startswith("command_ca")).replace("\ntoken", "\ntoken"))
open(noca, "a").write("token = smoke.ini.token\n")
code, text = run_check(noca)
check("check: without the proxy's CA its certificate is refused", code == 1 and "its certificate was not accepted" in text, text)

class Mcp:
    def __init__(self, path):
        self.p = subprocess.Popen([binary, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.lines = queue.Queue()
        threading.Thread(target=self.read_lines, daemon=True).start()
        self.i = 0
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
        self.recv(0)
    def read_lines(self):
        for line in iter(self.p.stdout.readline, b""):
            self.lines.put(line)
        self.lines.put(None)
    def send(self, o):
        self.p.stdin.write((json.dumps(o) + "\n").encode())
        self.p.stdin.flush()
    def recv(self, want, timeout=120.0):
        end = time.time() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.0, end - time.time()))
            except queue.Empty:
                return None
            if line is None:
                self.lines.put(None)
                return None
            said.append(line.decode())
            m = json.loads(line)
            if m.get("id") == want:
                return m
    def tools(self):
        self.i += 1
        self.send({"jsonrpc": "2.0", "id": self.i, "method": "tools/list"})
        return self.recv(self.i)["result"]["tools"]
    def call(self, name, args=None):
        self.i += 1
        self.send({"jsonrpc": "2.0", "id": self.i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
        m = self.recv(self.i)
        return (m["result"]["content"][0]["text"], m["result"]["isError"]) if m else ("(no answer)", True)
    def close(self):
        self.p.stdin.close()
        return self.p.wait(timeout=10)

m = Mcp(car)
names = [t["name"] for t in m.tools()]
check("tools: only what the car file allows", names == ["car_status", "car_command", "car_climate", "car_seat_heat"], names)
text, err = m.call("car_status")
check("status: a sleeping car isn't woken unasked", not err and "asleep: yes" in text and "2 of 2 wakes left" in text and counters()["wakes"] == 0, text)
text, err = m.call("car_status", {"wake": True})
check("status: woken when asked, read live", not err and "outside: -3 °C" in text and "climate: off, set to 21 °C" in text and "battery: 64%" in text and "woken for this read (1 of 2 wakes left" in text and counters()["wakes"] == 1, text)
before = counters()["commands"]
text, err = m.call("car_climate", {"state": "on", "temp": 30})
check("climate: an unknown field is refused, nothing sent", err and "car_climate has no field temp" in text and counters()["commands"] == before, text)
text, err = m.call("car_climate", {"state": "on", "temperature": 30})
check("climate: a temperature outside the owner's range is refused", err and "from 18 to 24 °C" in text and counters()["commands"] == before, text)
text, err = m.call("car_climate", {"state": "on", "temperature": 21.5})
check("climate: on at 21.5 °C, signed, read back", not err and text == "Climate on, set to 21.5 °C; inside 4.5 °C, outside -3 °C." and counters()["climate_on"] is True and counters()["set_temp"] == 21.5, text)
text, err = m.call("car_seat_heat", {"seat": "driver", "level": 3})
check("seat: a seat Tesla doesn't name is refused", err and "seat is front_left, front_right" in text, text)
text, err = m.call("car_seat_heat", {"seat": "front_left", "level": 3})
check("seat: front left at 3, read back", not err and text == "Front left seat heating at 3 of 3." and counters()["seat_left"] == 3, text)
text, err = m.call("car_command", {"command": "charge_limit", "percent": 85})
check("charge limit: signed, read back", not err and text == "done: charge limit 85%, confirmed by the car (it reads 85%)", text)
sim(asleep=True)
w = counters()["wakes"]
text, err = m.call("car_climate", {"state": "off"})
check("a command wakes a sleeping car first", not err and text == "Climate off; inside 4.5 °C, outside -3 °C." and counters()["wakes"] == w + 1, text)
sim(key_paired=False)
text, err = m.call("car_climate", {"state": "on"})
check("a car that doesn't know the key, said plainly", err and "pair the virtual key once in the Tesla app" in text, text)
sim(key_paired=True, expire_tokens=True)
text, err = m.call("car_climate", {"state": "on"})
rotated = json.load(open(token_file))["refresh_token"]
check("an expired access token is renewed; the refresh token Tesla rotates is kept", not err and text.startswith("Climate on") and rotated != first_refresh, text)
text, err = m.call("car_climate", {"state": "off"})
check("the day's cap: the seventh command is refused by carcloud itself", err and "6 commands in the last 24 hours is the limit" in text, text)
sim(asleep=True)
text, err = m.call("car_status", {"wake": True})
check("the second wake of the day", not err and "woken for this read (0 of 2 wakes left" in text, text)
sim(asleep=True)
text, err = m.call("car_status", {"wake": True})
check("a third wake is refused (wakes_per_day)", err and "2 wakes in the last 24 hours is the limit" in text, text)
check("no command ever reached the Fleet API unsigned", counters()["unsigned"] == 0, counters())
check("exits when stdin closes", m.close() == 0)
tokens = [first_refresh, rotated]
check("no token in anything carcloud said", not any(tok in t for tok in tokens for t in said) and first_refresh != "?", "a token was said")
sys.exit(1 if failed else 0)
EOF2
python3 -I "$T/tesla.py" "$B" "$TC" "$T/tesla" || fail=1
check "tesla: the log names each command, refusals and wakes too" 'grep -q "\"command\":\"climate\",\"percent\":null,\"result\":\"done\",\"message\":\"Climate on, set to 21.5 °C; inside 4.5 °C, outside -3 °C.\",\"state\":\"on\",\"temperature\":21.5" "$T/tesla.jsonl" && grep -q "\"command\":\"climate\",\"percent\":null,\"result\":\"refused\",\"message\":\"car_climate has no field temp" "$T/tesla.jsonl" && grep -q "\"command\":\"wake\",\"percent\":null,\"result\":\"refused\"" "$T/tesla.jsonl" && grep -q "\"vehicle\":\"5YJ3SIM0000000001\"" "$T/tesla.jsonl"'


if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	exit 1
fi
