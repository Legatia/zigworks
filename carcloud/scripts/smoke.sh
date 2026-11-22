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

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	exit 1
fi
