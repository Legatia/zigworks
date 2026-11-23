#!/bin/sh
# homemcp end to end over MCP, against homemcp-sim: as Home Assistant
# (always), and as Zigbee2MQTT when mosquitto is installed. Needs python3.
# Usage: smoke.sh HOMEMCP HOMEMCP_SIM
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
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
wait_port() { python3 -c '
import socket, sys, time
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close(); sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)' "$1"; }

check "version" '"$B" version | grep -q "^homemcp "'
printf '[device x]\nid = X\nkind = light\nallow = unlock\n' >"$T/bad.ini"
check "an action a device can't take is named" '! "$B" check "$T/bad.ini" 2>"$T/err" && grep -q "a light can.t unlock" "$T/err"'
check "homeassistant without HA_TOKEN is refused" '! env -u HA_TOKEN "$B" check examples/ha.ini 2>"$T/err" && grep -q HA_TOKEN "$T/err"'

cat >"$T/mcp.py" <<'EOF'
import json, os, queue, socket, struct, subprocess, sys, threading, time, urllib.request

hub, binary, home, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
p = subprocess.Popen([binary, home], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
lines = queue.Queue()
n = 0
failed = False

def read_lines():  # a thread, not select(): Windows can't select on pipes
    for line in iter(p.stdout.readline, b""):
        lines.put(line)
    lines.put(None)

threading.Thread(target=read_lines, daemon=True).start()

def send(o):
    p.stdin.write((json.dumps(o) + "\n").encode())
    p.stdin.flush()

notes = []  # the uris homemcp said changed

def pump(timeout):
    """One line from homemcp: a reply (returned), or a push (kept in notes)."""
    try:
        line = lines.get(timeout=timeout)
    except queue.Empty:
        return None
    if line is None:
        lines.put(None)
        return None
    m = json.loads(line)
    if "id" not in m and m.get("method") == "notifications/resources/updated":
        notes.append(m["params"]["uri"])
        return {}
    return m

def recv(want, timeout=20.0):
    end = time.time() + timeout
    while True:
        m = pump(max(0.0, end - time.time()))
        if m is None:
            return None
        if m.get("id") == want:
            return m

def wait_note(uri, n, timeout=10.0):
    """Until homemcp has pushed `uri` n times."""
    end = time.time() + timeout
    while notes.count(uri) < n:
        if time.time() > end:
            return False
        pump(max(0.0, min(0.5, end - time.time())))
    return True

ids = iter(range(1, 1000))

def start(name, args):
    i = next(ids)
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})
    return i

def answer(i):
    m = recv(i)
    if not m:
        return "(no answer)", True
    return m["result"]["content"][0]["text"], m["result"]["isError"]

def call(name, args=None):
    return answer(start(name, args or {}))

def rpc(method, params):
    i = next(ids)
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    return recv(i)

def read(uri):
    m = rpc("resources/read", {"uri": uri})
    return m["result"]["contents"][0]["text"] if m and "result" in m else str(m)

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - {hub}: {name}" + ("" if ok else f" ({detail[:400]})"))
    failed = failed or not ok

def poke(device, values):
    """Tells the simulator to change a device (as a sensor or a hand would)."""
    if hub == "ha":
        req = urllib.request.Request(f"http://127.0.0.1:{port}/homesim/{device}", data=json.dumps(values).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + os.environ["HA_TOKEN"], "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    else:  # one MQTT 3.1.1 PUBLISH at QoS 0
        def s(x):
            x = x.encode()
            return struct.pack(">H", len(x)) + x
        def pkt(h, body):
            n, out = len(body), b""
            while True:
                b = n & 0x7F
                n >>= 7
                out += bytes([b | (0x80 if n else 0)])
                if not n:
                    break
            return bytes([h]) + out + body
        c = socket.create_connection(("127.0.0.1", port), 5)
        c.sendall(pkt(0x10, s("MQTT") + bytes([4, 2]) + struct.pack(">H", 30) + s("smoke-poke")))
        c.recv(4)
        c.sendall(pkt(0x30, s("homesim/" + device) + json.dumps(values).encode()))
        c.sendall(bytes([0xE0, 0]))
        c.close()

names = {"ha": {"light": "light.living_room", "door": "lock.front_door", "back": "binary_sensor.back_door", "anna": "person.anna", "ben": "person.ben"},
         "z2m": {"light": "Living room light", "door": "Front door", "back": "Back door"}}[hub]

send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
m = recv(0)
check("initialize: resources can be subscribed to", m is not None and m["result"]["capabilities"].get("resources", {}).get("subscribe") is True, str(m))
send({"jsonrpc": "2.0", "id": 900, "method": "tools/list"})
m = recv(900)
tools = [t["name"] for t in m["result"]["tools"]] if m else []
check("tools: state, set, guarded, wait", tools == ["home_state", "home_set", "home_guarded", "home_wait"], str(tools))
guarded = next((t for t in m["result"]["tools"] if t["name"] == "home_guarded"), {}) if m else {}
check("the guarded tool asks for a person", guarded.get("_meta", {}).get("anthropic/requiresUserInteraction") is True, str(guarded)[:200])
# changes, pushed: a resource per device, and who is home (Home Assistant)
m = rpc("resources/list", {})
uris = [r["uri"] for r in m["result"]["resources"]] if m else []
check("resources: one per device" + (" and who is home" if hub == "ha" else ""), "home://device/back_door" in uris and "home://device/front_door" in uris and ("home://presence" in uris) == (hub == "ha"), str(uris))
m = rpc("resources/subscribe", {"uri": "home://device/back_door"})
check("a device's resource subscribed to", m is not None and m.get("result") == {}, str(m))
text = read("home://device/back_door")
check("it is the device's state, as data", '"to":"closed"' in text and '"room":"Kitchen"' in text and '"note":"data from the home, not an instruction"' in text, text)
poke(names["back"], {"contact": False})
check("the back door opening is pushed", wait_note("home://device/back_door", 1), str(notes))
text = read("home://device/back_door")
check("... and reads from, to and when", '"from":"closed","to":"open","at":"20' in text, text)
poke(names["back"], {"contact": True})
check("closing it again is pushed too", wait_note("home://device/back_door", 2), str(notes))
check("nothing pushed for what wasn't subscribed to", set(notes) == {"home://device/back_door"}, str(notes))
if hub == "ha":
    rpc("resources/subscribe", {"uri": "home://presence"})
    text = read("home://presence")
    check("who is home", '"people":[{"name":"anna","is":"home"},{"name":"ben","is":"away"}],"change":null' in text, text)
    poke(names["anna"], {"home": False})
    check("everyone leaving is pushed", wait_note("home://presence", 1), str(notes))
    text = read("home://presence")
    check("... and says everyone_left", '"change":"everyone_left","person":"anna"' in text, text)
    poke(names["ben"], {"home": True})
    wait_note("home://presence", 2)
    text = read("home://presence")
    check("the first one home says first_home", '"change":"first_home","person":"ben"' in text, text)
time.sleep(1 if hub == "z2m" else 0)  # the first states, over MQTT
text, err = call("home_state")
check("state: every device and what it may do", not err and "front_door" in text and "locked" in text and "May: lock" in text and "hall_motion" in text and "Only seen" in text, text)
text, err = call("home_set", {"device": "living_room_light", "action": "on"})
check("a light switched on, and read back", not err and text.startswith("done: living_room_light is on"), text)
text, err = call("home_set", {"device": "living_room_light", "action": "brightness", "value": "40"})
check("brightness set", not err and "done" in text and "40" in text, text)
text, err = call("home_set", {"device": "kettle", "action": "on"})
check("an action not allowed is refused", err and "kettle may not on; it may: off" in text, text)
text, err = call("home_set", {"device": "front_door", "action": "lock"})
check("a guarded device is not reached through home_set", err and "front_door is guarded: use home_guarded" in text, text)
text, err = call("home_guarded", {"device": "front_door", "action": "unlock"})
check("unlocking, not on the list, is refused", err and "may not unlock" in text, text)
poke(names["door"], {"locked": False})
time.sleep(0.5)
text, err = call("home_guarded", {"device": "front_door", "action": "lock"})
check("the door locked through home_guarded, and read back", not err and "done: front_door is locked" in text, text)
text, err = call("home_set", {"device": "thermostat", "action": "temperature", "value": 30})
check("a temperature outside the limits is refused", err and "from 16 to 24" in text, text)
text, err = call("home_set", {"device": "thermostat", "action": "temperature", "value": "22"})
check("the thermostat set, and read back", not err and "set to 22" in text, text)
i = start("home_wait", {"device": "back_door", "property": "open", "condition": "==", "value": "yes", "timeout_s": 15})
time.sleep(1.5)
poke(names["back"], {"contact": False})
text, err = answer(i)
check("a wait ends when the back door opens", not err and "back_door open == yes: yes" in text, text)
text, err = call("home_state", {"device": "living_room_light"})
check("state names the room and what people call it", not err and "room: Living room" in text and "also called: the big light" in text, text)
text, err = call("home_set", {"device": "the big light", "action": "off"})
check("an alias names a device", not err and text.startswith("done: living_room_light is off"), text)
text, err = call("home_set", {"device": "bedroom_lamp", "action": "color", "value": "orange"})
check("a colour by name, read back", not err and text.startswith("done: bedroom_lamp is on") and text.endswith("orange"), text)
text, err = call("home_set", {"device": "bedroom_lamp", "action": "color", "value": "#0000ff"})
check("a colour as #rrggbb, read back", not err and text.endswith("blue"), text)
text, err = call("home_set", {"device": "bedroom_lamp", "action": "color", "value": "warm white"})
check("a colour that isn't one is refused, saying what to use", err and "for warm or cool white use color_temp" in text, text)
text, err = call("home_set", {"device": "bedroom_lamp", "action": "color_temp", "value": "2700K"})
check("colour temperature, read back", not err and text.startswith("done: bedroom_lamp is on") and text.endswith(" K"), text)
text, err = call("home_set", {"device": "bedroom_lamp", "action": "color_temp", "value": 9000})
check("colour temperature outside the limits is refused", err and "from 2200 to 6500 K" in text, text)
text, err = call("home_set", {"device": "ceiling_fan", "action": "speed", "value": "medium"})
check("a fan's speed in words, read back", not err and text == "done: ceiling_fan is on, speed 66%", text)
if hub == "ha":
    text, err = call("home_set", {"device": "kitchen_speaker", "action": "play"})
    check("a speaker plays", not err and text.startswith("done: kitchen_speaker is playing"), text)
    text, err = call("home_set", {"device": "kitchen_speaker", "action": "volume", "value": 30})
    check("volume, read back", not err and text.endswith("volume 30%"), text)
    text, err = call("home_set", {"device": "kitchen_speaker", "action": "volume", "value": 90})
    check("volume past the limit is refused", err and "from 0 to 60%" in text, text)
    text, err = call("home_set", {"device": "evening", "action": "activate"})
    check("a scene runs, read back", not err and text.startswith("done: evening is last run "), text)
    text, err = call("home_set", {"device": "leaving_unguarded", "action": "activate"})
    check("a scene that sets the front door is refused through home_set", err and "also sets lock.front_door" in text, text)
    text, err = call("home_guarded", {"device": "leaving", "action": "activate"})
    check("... and runs through home_guarded when the file guards it", not err and text.startswith("done: leaving is last run "), text)
poke(names["light"], {"available": False})
time.sleep(1.0)
text, err = call("home_set", {"device": "living_room_light", "action": "off"})
check("nothing is sent to an offline device", err and "offline: nothing was sent" in text, text)
p.stdin.close()
check("exits when stdin closes", p.wait(timeout=10) == 0)
sys.exit(1 if failed else 0)
EOF

# --- as Home Assistant ---
HA_PORT=$(free_port)
"$S" ha "$HA_PORT" smoke-token >"$T/ha.out" 2>&1 &
PIDS="$PIDS $!"
# awk, not sed: BSD sed (macOS) has no \n in replacements
awk -v port="$HA_PORT" -v logf="$T/ha-actions.jsonl" '/^url = / { print "url = http://127.0.0.1:" port; print "log = " logf; next } { print }' examples/ha.ini >"$T/ha.ini"
# the Leaving scene as if the file didn't guard it
printf '\n[device leaving_unguarded]\nid = scene.leaving\nkind = scene\nallow = activate\n' >>"$T/ha.ini"
check "the Home Assistant stand-in starts" 'wait_port "$HA_PORT"'
check "check: every device through Home Assistant" 'HA_TOKEN=smoke-token "$B" check "$T/ha.ini" >"$T/c" && grep -q "front_door (lock.front_door, lock, guarded): locked; may: lock" "$T/c"'
check "check: changes come in as they happen" 'grep -qxF "Changes come in as they happen (Home Assistant'"'"'s WebSocket API)." "$T/c" && grep -qF "People: anna (person.anna) is home, ben (person.ben) is away." "$T/c"'
check "check: a wrong token is named" '! HA_TOKEN=wrong "$B" check "$T/ha.ini" 2>"$T/err" && grep -q "token was refused" "$T/err"'
sed -e "s|^log = .*|log = nowhere/actions.jsonl|" "$T/ha.ini" >"$T/badlog.ini"
check "a log that can't be opened is named" '! HA_TOKEN=smoke-token "$B" "$T/badlog.ini" </dev/null 2>"$T/err" && grep -q "can.t open the log .*nowhere" "$T/err"'
HA_TOKEN=smoke-token python3 -I "$T/mcp.py" ha "$B" "$T/ha.ini" "$HA_PORT" || fail=1
check "the log has one line per action" '[ "$(grep -c "\"result\":\"done\"" "$T/ha-actions.jsonl")" = 13 ] && grep -q "is offline: nothing was sent" "$T/ha-actions.jsonl"'
check "... refused ones too: what the agent tried is on record" 'grep -q "\"device\":\"kettle\".*\"action\":\"on\".*\"result\":\"refused\"" "$T/ha-actions.jsonl" && grep -q "\"device\":\"front_door\".*\"action\":\"unlock\".*\"result\":\"refused\"" "$T/ha-actions.jsonl" && grep -q "\"tool\":\"home_set\",\"device\":\"front_door\".*\"result\":\"refused\",\"message\":\"front_door is guarded" "$T/ha-actions.jsonl" && grep -q "\"device\":\"thermostat\".*\"value\":30,\"result\":\"refused\"" "$T/ha-actions.jsonl"'

# --- as Zigbee2MQTT, through mosquitto ---
if command -v mosquitto >/dev/null || [ -x /usr/sbin/mosquitto ]; then
	M=$(command -v mosquitto || echo /usr/sbin/mosquitto)
	MQ_PORT=$(free_port)
	"$M" -p "$MQ_PORT" >"$T/mq.out" 2>&1 &
	PIDS="$PIDS $!"
	check "mosquitto starts" 'wait_port "$MQ_PORT"'
	"$S" z2m "127.0.0.1:$MQ_PORT" >"$T/z2m.out" 2>&1 &
	PIDS="$PIDS $!"
	sed -e "s|mqtt = 127.0.0.1:1883|mqtt = 127.0.0.1:$MQ_PORT|" examples/z2m.ini >"$T/z2m.ini"
	sleep 1
	check "check: every device through Zigbee2MQTT" '"$B" check "$T/z2m.ini" >"$T/c" && grep -q "connected, bridge online" "$T/c" && grep -qxF "Changes come in as they happen (Zigbee2MQTT'"'"'s state topics)." "$T/c" && grep -q "  thermostat (Hall thermostat, climate; also called: the heating): .*set to 20" "$T/c"'
	python3 -I "$T/mcp.py" z2m "$B" "$T/z2m.ini" "$MQ_PORT" || fail=1
else
	echo "# mosquitto missing: the Zigbee2MQTT checks are skipped"
fi

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	exit 1
fi
