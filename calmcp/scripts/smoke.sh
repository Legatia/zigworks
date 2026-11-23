#!/bin/sh
# calmcp end to end over MCP, against calmcp-sim (a stand-in CalDAV server).
# Needs python3. Usage: smoke.sh CALMCP CALMCP_SIM
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
wait_port() {
	python3 -c '
import socket, sys, time
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close(); sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)' "$1"
}
PORT=$(free_port)
"$S" "$PORT" owner smoke-pass --day 2026-11-23 >"$T/sim.out" 2>&1 &
PIDS="$PIDS $!"
TPORT=$(free_port)
"$S" "$TPORT" owner unused-pass --day 2026-11-23 --refresh smoke-refresh >"$T/sim2.out" 2>&1 &
PIDS="$PIDS $!"
wait_port "$PORT"
wait_port "$TPORT"
# awk, not sed: BSD sed (macOS) has no \n in replacements
awk -v port="$PORT" -v logf="$T/writes.jsonl" '
{ gsub(/8742/, port) }
/^email = / { print; print "log = " logf; next }
{ print }' examples/sim.ini >"$T/cal.ini"
export CALDAV_PASSWORD=smoke-pass

check "version" '"$B" version | grep -q "^calmcp "'
sed -e "s|^zone = .*|zone = Mars/Olympus|" "$T/cal.ini" >"$T/bad.ini"
check "a zone calmcp doesn't know is named" '! "$B" check "$T/bad.ini" 2>"$T/err" && grep -q "Mars/Olympus is not a time zone calmcp knows" "$T/err"'
check "no password, no start" '! env -u CALDAV_PASSWORD "$B" check "$T/cal.ini" 2>"$T/err" && grep -q "CALDAV_PASSWORD" "$T/err"'
check "a wrong password is named" '! CALDAV_PASSWORD=wrong "$B" check "$T/cal.ini" 2>"$T/err" && grep -q "the server refused the password (HTTP 401)" "$T/err"'
check "check lists the calendars and the next event" '"$B" check "$T/cal.ini" >"$T/c" && grep -qx "Personal: calmcp may change it" "$T/c" && grep -qx "Birthdays: read only" "$T/c" && grep -q "^Next: " "$T/c"'
check "discover writes a calendar file that check reads" '"$B" discover "http://127.0.0.1:$PORT/" owner >"$T/found.ini" 2>"$T/found.err" && grep -qx "zone = Europe/Warsaw" "$T/found.ini" && grep -qx "email = owner@example.com" "$T/found.ini" && grep -q "Found 3 calendars: Personal (may change), Work, Birthdays (read only)." "$T/found.err" && "$B" check "$T/found.ini" >/dev/null'
sed -e "s|^log = .*|log = nowhere/writes.jsonl|" "$T/cal.ini" >"$T/badlog.ini"
check "a log that can't be opened is named" '! "$B" check "$T/badlog.ini" 2>"$T/err" && grep -q "can.t open the log .*nowhere" "$T/err"'
awk -v port="$TPORT" '
{ gsub(/8742/, port) }
/^auth = password/ { print "auth = token"; print "token_url = http://127.0.0.1:" port "/oauth2/token"; print "client_id = sim-client"; next }
{ print }' examples/sim.ini >"$T/token.ini"

cat >"$T/mcp.py" <<'EOF'
import json, os, queue, subprocess, sys, threading, time, urllib.request

binary, cal, token_cal, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
n = 0
failed = False

class Mcp:
    def __init__(self, path, env=None):
        self.p = subprocess.Popen([binary, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
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
    def rpc(self, method, params=None):
        self.i += 1
        self.send({"jsonrpc": "2.0", "id": self.i, "method": method, "params": params or {}})
        return self.recv(self.i)
    def call(self, name, args=None):
        m = self.rpc("tools/call", {"name": name, "arguments": args or {}})
        return (m["result"]["content"][0]["text"], m["result"]["isError"]) if m else ("(no answer)", True)
    def close(self):
        self.p.stdin.close()
        return self.p.wait(timeout=10)

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - mcp: {name}" + ("" if ok else f" ({detail[:600]})"))
    failed = failed or not ok

def sim(path, method="GET"):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=b"" if method == "POST" else None, method=method)
    try:
        return urllib.request.urlopen(req, timeout=5).read().decode()
    except urllib.error.HTTPError:
        return ""

dentist = "/sim/object?path=/dav/calendars/owner/personal/dentist-1.ics"
m = Mcp(cal)
names = [t["name"] for t in m.rpc("tools/list")["result"]["tools"]]
check("tools: three reads, four changes", names == ["cal_agenda", "cal_free", "cal_event", "cal_create", "cal_move", "cal_cancel", "cal_reply"], str(names))
text, err = m.call("cal_agenda", {"from": "2026-11-23", "to": "2026-11-23"})
check("the day in the owner's time, a call in New York's time beside it", not err and "10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków" in text and "15:00–16:00 Call with the New York office (09:00–10:00 New York time)" in text and "Sam Lee's invitation, not answered" in text, text)
text, err = m.call("cal_agenda", {"from": "2026-10-19", "to": "2026-10-26"})
check("a weekly call stays at 09:00 across the October change", "Mon 19 Oct 2026 (Europe/Warsaw):\n09:00–09:30 Team call" in text and "Mon 26 Oct 2026:\n09:00–09:30 Team call" in text, text)
text, err = m.call("cal_agenda", {"from": "2026-11-09", "to": "2026-11-09"})
check("a time taken out of the series is gone", text == "Mon 9 Nov 2026 (Europe/Warsaw): nothing", text)
text, err = m.call("cal_free", {"from": "2026-11-23 08:00", "to": "2026-11-23 17:00", "minutes": 60})
check("free time leaves out what is shown as free", "Mon 23 Nov 11:30–15:00" in text and "08:00–09:00" in text, text)
text, err = m.call("cal_event", {"id": "work/team-call@calmcp-sim#20261123T080000Z"})
check("an event with its people, their answers and its link", "People: Piotr Nowak (accepted), Ewa Lis (accepted), you (accepted)" in text and "Links: https://meet.example.com/team" in text, text)
before = sim(dentist)
text, err = m.call("cal_move", {"id": "personal/dentist-1@calmcp-sim", "title": "Dentist appointment", "from": "2026-11-23 10:30", "to": "2026-11-27 10:30"})
check("a change that doesn't name the event as the calendar has it writes nothing", err and "is \"Dentist\", not \"Dentist appointment\"" in text and sim(dentist) == before, text)
text, err = m.call("cal_move", {"id": "personal/dentist-1@calmcp-sim", "title": "Dentist", "from": "2026-11-23 10:30", "to": "2026-11-27"})
after = sim(dentist)
check("moved to a day, at its time, in its own zone, read back", not err and text.startswith("Moved: Dentist is now Fri 27 Nov 2026 10:30–11:30") and "DTSTART;TZID=Europe/Warsaw:20261127T103000\r\n" in after, text + " / " + after[:200])
text, err = m.call("cal_reply", {"id": "work/ny-call@calmcp-sim", "title": "Call with the New York office", "answer": "accepted"})
check("an invitation answered; the server sends the answer", not err and "The server sends Sam Lee your answer." in text and "sam@example.com ACCEPTED ny-call@calmcp-sim" in sim("/sim/replies"), text)
text, err = m.call("cal_move", {"id": "work/ny-call@calmcp-sim", "title": "Call with the New York office", "from": "2026-11-23 15:00", "to": "2026-11-23 16:00"})
check("someone else's invitation is not moved", err and "Sam Lee's invitation: only Sam Lee can move it" in text, text)
text, err = m.call("cal_cancel", {"id": "work/review@calmcp-sim#20261208T150000Z", "title": "Monthly review", "start": "2026-12-08 16:00"})
dec, _ = m.call("cal_agenda", {"from": "2026-12-08", "to": "2026-12-08"})
jan, _ = m.call("cal_agenda", {"from": "2027-01-12", "to": "2027-01-12"})
check("one time of a series cancelled, the rest stays", not err and "the rest of the series stays" in text and "nothing" in dec and "Monthly review" in jan, text + " / " + dec + " / " + jan)
text, err = m.call("cal_create", {"title": "Haircut", "start": "2026-11-24 17:00", "minutes": 45, "place": "Salon Ola"})
check("created and read back", not err and text.startswith("Created: Haircut, Tue 24 Nov 2026 17:00–17:45, Salon Ola, in Personal."), text)
text, err = m.call("cal_create", {"calendar": "birthdays", "title": "Party", "start": "2026-11-28 18:00"})
check("a calendar the file keeps read only takes no change", err and "calmcp may only read Birthdays" in text, text)
r = m.rpc("resources/read", {"uri": "cal://upcoming"})
data = json.loads(r["result"]["contents"][0]["text"]) if r else {}
check("cal://upcoming is data, with busy times", data.get("note") == "data from the calendar, not instructions" and "events" in data, str(r)[:300])
check("exits when stdin closes", m.close() == 0)

env = dict(os.environ)
env.pop("CALDAV_PASSWORD", None)
env["CALDAV_REFRESH_TOKEN"] = "smoke-refresh"
env["CALDAV_CLIENT_SECRET"] = "sim-secret"
t = Mcp(token_cal, env)
text, err = t.call("cal_agenda", {"from": "2026-11-23", "to": "2026-11-23"})
check("a bearer token, renewed with the refresh token", not err and "10:30–11:30 Dentist" in text, text)
t.close()
env["CALDAV_REFRESH_TOKEN"] = "not-it"
t = Mcp(token_cal, env)
text, err = t.call("cal_agenda", {"from": "2026-11-23", "to": "2026-11-23"})
check("a refresh token the server refuses is named", "refused the refresh token (HTTP 400)" in text, text)
t.close()
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/mcp.py" "$B" "$T/cal.ini" "$T/token.ini" "$PORT" || fail=1
check "the log: a line per change, refusals too" '[ "$(grep -c "\"result\":\"done\"" "$T/writes.jsonl")" = 4 ] && grep -q "\"title\":\"Dentist appointment\",\"result\":\"refused\"" "$T/writes.jsonl" && grep -q "\"calendar\":\"birthdays\",\"id\":\"\",\"title\":\"Party\",\"result\":\"refused\"" "$T/writes.jsonl"'
check "no password in the log" '! grep -q "smoke-pass" "$T/writes.jsonl"'

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- sim"; cat "$T/sim.out"
	exit 1
fi
