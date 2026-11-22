#!/bin/sh
# canmcp end to end: the CLI, and MCP over stdio as an agent starts it.
# Needs python3. The bus parts use vcan0 and are skipped without it; to
# have one, as root: modprobe vcan; ip link add dev vcan0 type vcan;
# ip link set up vcan0. Usage: smoke.sh CANMCP
set -u
B=$1
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0
fail=0
check() {
	n=$((n + 1))
	if eval "$2"; then echo "ok $n - $1"; else
		echo "not ok $n - $1"
		fail=1
	fi
}

check "version" '"$B" version | grep -q "^canmcp "'
check "check reads the ICSim profile" '"$B" check profiles/icsim.ini | grep -q "7 readings"'
printf '[bus x]\ninterface = vcan0\ndbc = nothing.dbc\n' >"$T/bad.ini"
check "a missing DBC file is named" '! "$B" check "$T/bad.ini" 2>"$T/err" && grep -q "nothing.dbc" "$T/err"'
printf '[bus can]\ninterface = vcan0\ndbc = %s/dbc/icsim.dbc\n[reading s]\nsignal = can SPEED.sped\n' "$PWD" >"$T/typo.ini"
check "a misspelt signal is named" '! "$B" check "$T/typo.ini" 2>"$T/err" && grep -q "SPEED has no signal sped" "$T/err"'

cat >"$T/ic.log" <<'EOF'
(100.000000) can0 244#0000001388
(100.500000) can0 188#01000000
(101.000000) can0 19B#00000F
(101.200000) can1 244#00000017
(102.000000) can0 244#0000000000
EOF
check "decode: speed, indicator and doors, other interfaces left out" '"$B" decode profiles/icsim.ini "$T/ic.log" 1 >"$T/dec" && grep -q "t=1.0 speed=50 km/h, left_indicator=on" "$T/dec" && grep -q "door4_locked=locked" "$T/dec" && grep -q "t=2.0 speed=0 km/h" "$T/dec" && grep -q "4 frames on the profile.s buses, 1 on other" "$T/dec"'

cat >"$T/mcp.py" <<'EOF'
import json, os, select, socket, struct, subprocess, sys, time

binary, profile = sys.argv[1], sys.argv[2]
have_bus = os.path.exists("/sys/class/net/vcan0")
p = subprocess.Popen([binary, profile], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
buf = b""
n = 0
failed = False

def send(o):
    p.stdin.write((json.dumps(o) + "\n").encode())
    p.stdin.flush()

def recv(want, timeout=10.0):
    global buf
    end = time.time() + timeout
    while True:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            m = json.loads(line)
            if m.get("id") == want:
                return m
        left = end - time.time()
        if left <= 0:
            return None
        r, _, _ = select.select([p.stdout], [], [], left)
        if r:
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                return None
            buf += chunk

def call(i, name, args=None):
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
    m = recv(i)
    return (m["result"]["content"][0]["text"], m["result"]["isError"]) if m else ("(no answer)", True)

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - mcp: {name}" + ("" if ok else f" ({detail[:300]})"))
    failed = failed or not ok

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}})
m = recv(1)
check("initialize", m is not None and m["result"]["protocolVersion"] == "2025-06-18", str(m))
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
m = recv(2)
names = [t["name"] for t in m["result"]["tools"]] if m else []
check("tools/list", names[:4] == ["car_readings", "bus_status", "car_signals", "car_wait"], str(names))
text, err = call(3, "car_readings")
check("readings before any frame", not err and "speed: not seen yet" in text, text)
if have_bus:
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind(("vcan0",))
    def frame(cid, data):
        s.send(struct.pack("=IB3x8s", cid, len(data), data.ljust(8, b"\0")))
    time.sleep(0.3)  # canmcp opens the interface when it starts
    frame(0x244, bytes([0, 0, 0, 0x13, 0x88]))
    time.sleep(0.3)
    text, err = call(4, "car_readings")
    check("a frame on vcan0 becomes speed: 50 km/h", "speed: 50 km/h" in text, text)
    send({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "car_wait", "arguments": {"reading": "speed", "condition": ">=", "value": "80", "timeout_s": 10}}})
    time.sleep(0.5)
    text, err = call(6, "bus_status")  # answered while the wait is still open
    check("other calls are answered during a wait", "awake" in text, text)
    frame(0x244, bytes([0, 0, 0, 0x1F, 0x40]))
    m = recv(5)
    wtext = m["result"]["content"][0]["text"] if m else "(no answer)"
    check("the wait ends when speed reaches 80", "speed >= 80: yes" in wtext, wtext)
else:
    print("# vcan0 missing: the bus checks are skipped")
p.stdin.close()
code = p.wait(timeout=5)
check("exits when stdin closes", code == 0, str(code))
sys.exit(1 if failed else 0)
EOF
if command -v python3 >/dev/null; then
	python3 -I "$T/mcp.py" "$B" profiles/icsim.ini || fail=1
else
	echo "# python3 missing: the MCP checks are skipped"
fi

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	exit 1
fi
