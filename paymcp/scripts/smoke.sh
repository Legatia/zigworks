#!/bin/sh
# paymcp end to end, on the command line and over MCP, against paymcp-sim
# (a stand-in for the billing provider). Needs python3.
# Usage: smoke.sh PAYMCP PAYMCP_SIM
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
KEY=rk_test_smoke_not_a_real_key
PORT=$(free_port)
"$S" "$PORT" "$KEY" >"$T/sim.out" 2>&1 &
PIDS="$PIDS $!"
# the same business behind a key that may not read the meters
MPORT=$(free_port)
"$S" "$MPORT" "$KEY" --no-meters >"$T/sim2.out" 2>&1 &
PIDS="$PIDS $!"
wait_port "$PORT"
wait_port "$MPORT"
cp examples/who.csv "$T/who.csv"
sed -e "s|8743|$PORT|" examples/sim.ini >"$T/pay.ini"
sed -e "s|8743|$MPORT|" examples/sim.ini >"$T/nometers.ini"
grep -v "^who = " "$T/pay.ini" >"$T/nowho.ini"
export STRIPE_KEY=$KEY

check "version" '"$B" version | grep -q "^paymcp "'
check "no key, no start" '! env -u STRIPE_KEY "$B" check "$T/pay.ini" 2>"$T/err" && grep -q "STRIPE_KEY isn.t set" "$T/err"'
check "a live account's secret key is refused before anything is sent" '! STRIPE_KEY=sk_live_abc "$B" audit "$T/pay.ini" 2>"$T/err" && grep -q "is a secret key, which can do everything" "$T/err"'
check "a sandbox's secret key is taken, with a note" '! STRIPE_KEY=sk_test_abc "$B" check "$T/pay.ini" 2>"$T/err" && grep -q "is the sandbox.s secret key" "$T/err" && grep -q "the billing provider refused the key (401)" "$T/err"'
check "a live key is refused where the file says sandbox" '! STRIPE_KEY=rk_live_abc "$B" audit "$T/pay.ini" 2>"$T/err" && grep -q "is a live key and the file says mode = sandbox" "$T/err"'
check "a key the provider refuses is named" '! STRIPE_KEY=rk_test_other "$B" check "$T/pay.ini" 2>"$T/err" && grep -q "the billing provider refused the key (401)" "$T/err"'
printf '[stripe]\nurl = http://example.com\n' >"$T/clear.ini"
check "a key is never sent in the clear to another computer" '! "$B" check "$T/clear.ini" 2>"$T/err" && grep -q "clear.ini line 2: .*a key isn.t sent in the clear" "$T/err"'
printf '[stripe]\nkey = rk_test_abc\n' >"$T/keyed.ini"
check "a key in the file is refused with its line" '! "$B" check "$T/keyed.ini" 2>"$T/err" && grep -q "keyed.ini line 2: \[stripe\] has no setting key" "$T/err"'
check "check says what was read, and that it only read" '"$B" check "$T/pay.ini" >"$T/c" && grep -q "^Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 5 invoices .*; from the business.s own file: 7 rows\.$" "$T/c" && grep -q "requests, every one a GET. The key works and nothing was changed.$" "$T/c"'
check "the audit: what was read, the sums, the findings largest first" '"$B" audit "$T/pay.ini" >"$T/a" && grep -q "^Billing audit of ....-..-..\. Nothing was changed: paymcp only reads\.$" "$T/a" && grep -qx "12 findings: 371.00 EUR a month and 755.00 EUR once." "$T/a" && grep -qx "1. Free, and has been for a while: 87.00 EUR a month" "$T/a" && grep -qx "12. An invoice never charged: 29.00 EUR, once" "$T/a"'
check "each finding has its rows, a proposal and a key" '[ "$(grep -c "^   Proposed: " "$T/a")" = 12 ] && [ "$(grep -c "^   \[[a-z_]*:.*\]$" "$T/a")" = 12 ] && grep -qx "   - the business.s file, line 2: seats 9" "$T/a" && grep -qx "   - subscription item si_alder_1: price price_team, quantity 5, 12.00 EUR a unit a month" "$T/a"'
check "customers with nothing to find aren't named" '! grep -q "Juniper\|Kapok\|Larch\|cus_old" "$T/a"'
check "the audit as data" '"$B" audit "$T/pay.ini" --json >"$T/a.json" && python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1], encoding=\"utf-8\"))
assert \"not instructions\" in d[\"note\"] and d[\"mode\"] == \"sandbox\"
assert len(d[\"findings\"]) == 12 and d[\"totals\"] == [{\"currency\": \"eur\", \"a_month\": 37100, \"once\": 75500}], d[\"totals\"]
assert d[\"read\"] == {\"customers\": 12, \"subscriptions\": 12, \"prices\": 6, \"invoices\": 5, \"business_file_rows\": 7}, d[\"read\"]
f = d[\"findings\"][0]
assert f[\"kind\"] == \"free\" and f[\"amount\"] == 8700 and f[\"per\"] == \"month\" and len(f[\"rows\"]) == 2, f
" "$T/a.json"'
check "without the business's file: said, and billing alone is audited" '"$B" audit "$T/nowho.ini" >"$T/n" && grep -q "^The business.s own file wasn.t given" "$T/n" && grep -qx "7 findings: 161.00 EUR a month and 629.00 EUR once." "$T/n"'
check "meters the key may not read: said, the rest still found" '"$B" audit "$T/nometers.ini" >"$T/m" && grep -q "^Not read: use reported to the meters wasn.t read: the key may not read this (403)" "$T/m" && grep -qx "11 findings: 371.00 EUR a month and 629.00 EUR once." "$T/m"'
printf 'customer,seats\ncus_alder,many\n' >"$T/badwho.csv"
sed -e "s|^who = .*|who = badwho.csv|" "$T/pay.ini" >"$T/badwho.ini"
check "a line of the business's file that can't be read is named" '! "$B" audit "$T/badwho.ini" 2>"$T/err" && grep -q "badwho.csv line 2" "$T/err"'
sed -e "s|^who = .*|who = nowhere.csv|" "$T/pay.ini" >"$T/nofile.ini"
check "a business's file that isn't there is named" '! "$B" audit "$T/nofile.ini" 2>"$T/err" && grep -q "can.t read the business.s file .*nowhere.csv" "$T/err"'
check "an unknown command line is the usage" '! "$B" audit "$T/pay.ini" --fix 2>"$T/err" && grep -q "^usage: paymcp PAY.ini" "$T/err"'

# the files for a Stripe sandbox (customers found by address, every "how
# old" setting at 0), against the same business
cp examples/sandbox-who.csv "$T/sandbox-who.csv"
awk -v port="$PORT" '{ print } /^\[stripe\]/ { print "url = http://127.0.0.1:" port }' examples/sandbox.ini >"$T/sandbox.ini"
check "the sandbox's files: found by address, nothing has to be old" '"$B" audit "$T/sandbox.ini" >"$T/s" && grep -qx "13 findings: 371.00 EUR a month and 755.00 EUR once; 1 with an amount this audit can.t know." "$T/s" && grep -q "Larch has been on a price of zero" "$T/s"'
check "the seed script: a dry run sends nothing and lists what it would" 'python3 -I scripts/seed-sandbox.py --dry-run >"$T/seed" && grep -qx "57 requests would be sent. Nothing was sent." "$T/seed" && [ "$(grep -c "^POST /v1/subscriptions  " "$T/seed")" = 12 ] && ! grep -q "payment_method" "$T/seed"'
check "the seed script takes a sandbox key only" '! STRIPE_SEED_KEY=sk_live_abc python3 -I scripts/seed-sandbox.py --yes 2>"$T/err" && grep -q "is not a sandbox key" "$T/err" && ! env -u STRIPE_SEED_KEY python3 -I scripts/seed-sandbox.py --yes 2>"$T/err" && grep -q "STRIPE_SEED_KEY isn.t set" "$T/err"'

cat >"$T/mcp.py" <<'EOF'
import json, queue, subprocess, sys, threading, time

binary, pay = sys.argv[1], sys.argv[2]
n = 0
failed = False

class Mcp:
    def __init__(self, path):
        self.p = subprocess.Popen([binary, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.lines = queue.Queue()
        threading.Thread(target=self.read_lines, daemon=True).start()
        self.i = 0
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
        self.hello = self.recv(0)
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

m = Mcp(pay)
info = m.hello["result"]
check("initialize names paymcp and says what it reads is data", info["serverInfo"]["name"] == "paymcp" and "data, not instructions" in info["instructions"] and "It only reads" in info["instructions"], json.dumps(info))
tools = m.rpc("tools/list")["result"]["tools"]
check("two tools, both marked as only reading", [t["name"] for t in tools] == ["billing_audit", "billing_finding"] and all(t["annotations"]["readOnlyHint"] for t in tools), json.dumps(tools)[:600])
text, err = m.call("billing_audit")
check("billing_audit: the sums and the findings", not err and "12 findings: 371.00 EUR a month and 755.00 EUR once." in text and "More seats than paid for: 48.00 EUR a month\n   Alder Works has 9 seats in the product and pays for 5." in text, text)
text, err = m.call("billing_audit", {"kind": "usage_not_reported"})
check("one kind", not err and "1 finding of the kind usage_not_reported (12 in all): 126.00 EUR once." in text and "Fir Analytics used 15300 this period in the product; billing was told of 9000." in text and "Alder" not in text, text)
text, err = m.call("billing_audit", {"limit": 2})
check("a limit says what it left out", not err and "\n2. " in text and "\n3. " not in text and "...and 10 more, smaller" in text, text)
text, err = m.call("billing_finding", {"key": "written_off:cus_ivy:eur"})
check("billing_finding: one finding with its rows", not err and text.startswith("Invoices written off: 120.00 EUR, once") and "- invoice in_ivy_bad: uncollectible, 60.00 EUR" in text and "in_ivy_never" not in text, text)
text, err = m.call("billing_finding", {"key": "written_off:cus_nobody:eur"})
check("a key no finding has is said", err and "No finding has the key" in text, text)
text, err = m.call("billing_audit", {"customer": "cus_alder"})
check("a field the tool doesn't take is refused", err and "billing_audit has no field customer; it takes kind, limit, fresh." in text, text)
text, err = m.call("billing_fix", {"key": "paused:sub_gorse"})
check("there is no tool that changes anything", err and "no tool called billing_fix" in text, text)
res = m.rpc("resources/read", {"uri": "pay://findings"})
body = json.loads(res["result"]["contents"][0]["text"])
check("the findings as a resource", len(body["findings"]) == 12 and "not instructions" in body["note"], json.dumps(body)[:600])
check("paymcp ends when its input does", m.close() == 0)
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/mcp.py" "$B" "$T/pay.ini" || fail=1
check "the key is in nothing paymcp wrote" '! grep -rq "$KEY" "$T/a" "$T/a.json" "$T/c" "$T/n" "$T/m" "$T/err"'

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- sim"
	cat "$T/sim.out"
	exit 1
fi
