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
check "check says what was read, and that it only read" '"$B" check "$T/pay.ini" >"$T/c" && grep -q "^Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 7 invoices .*; from the business.s own file: 7 rows\.$" "$T/c" && grep -q "requests, every one a GET. The key works and nothing was changed.$" "$T/c"'
check "the audit: what was read, the sums, the findings largest first" '"$B" audit "$T/pay.ini" >"$T/a" && grep -q "^Billing audit of ....-..-..\. Nothing was changed: paymcp only reads\.$" "$T/a" && grep -qx "14 findings: 371.00 EUR a month and 1143.00 EUR once." "$T/a" && grep -qx "1. Free, and has been for a while: 87.00 EUR a month" "$T/a" && grep -qx "10. Invoices past due: 340.00 EUR, once" "$T/a" && grep -qx "13. Payments that failed: 48.00 EUR, once" "$T/a" && grep -qx "14. An invoice never charged: 29.00 EUR, once" "$T/a"'
check "each finding has its rows, a proposal and a key" '[ "$(grep -c "^   Proposed: " "$T/a")" = 14 ] && [ "$(grep -c "^   \[[a-z_]*:.*\]$" "$T/a")" = 14 ] && grep -qx "   - the business.s file, line 2: seats 9" "$T/a" && grep -qx "   - subscription item si_alder_1: price price_team, quantity 5, 12.00 EUR a unit a month" "$T/a"'
check "customers with nothing to find aren't named" '! grep -q "Juniper\|Kapok\|Larch\|cus_old" "$T/a"'
check "the audit as data" '"$B" audit "$T/pay.ini" --json >"$T/a.json" && python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1], encoding=\"utf-8\"))
assert \"not instructions\" in d[\"note\"] and d[\"mode\"] == \"sandbox\"
assert len(d[\"findings\"]) == 14 and d[\"totals\"] == [{\"currency\": \"eur\", \"a_month\": 37100, \"once\": 114300}], d[\"totals\"]
assert d[\"read\"] == {\"customers\": 12, \"subscriptions\": 12, \"prices\": 6, \"invoices\": 7, \"business_file_rows\": 7}, d[\"read\"]
f = d[\"findings\"][0]
assert f[\"kind\"] == \"free\" and f[\"amount\"] == 8700 and f[\"per\"] == \"month\" and len(f[\"rows\"]) == 2, f
" "$T/a.json"'
check "without the business's file: said, and billing alone is audited" '"$B" audit "$T/nowho.ini" >"$T/n" && grep -q "^The business.s own file wasn.t given" "$T/n" && grep -qx "9 findings: 161.00 EUR a month and 1017.00 EUR once." "$T/n"'
check "meters the key may not read: said, the rest still found" '"$B" audit "$T/nometers.ini" >"$T/m" && grep -q "^Not read: use reported to the meters wasn.t read: the key may not read this (403)" "$T/m" && grep -qx "13 findings: 371.00 EUR a month and 1017.00 EUR once." "$T/m"'
printf 'customer,seats\ncus_alder,many\n' >"$T/badwho.csv"
sed -e "s|^who = .*|who = badwho.csv|" "$T/pay.ini" >"$T/badwho.ini"
check "a line of the business's file that can't be read is named" '! "$B" audit "$T/badwho.ini" 2>"$T/err" && grep -q "badwho.csv line 2" "$T/err"'
sed -e "s|^who = .*|who = nowhere.csv|" "$T/pay.ini" >"$T/nofile.ini"
check "a business's file that isn't there is named" '! "$B" audit "$T/nofile.ini" 2>"$T/err" && grep -q "can.t read the business.s file .*nowhere.csv" "$T/err"'
check "the first reading starts paymcp's record, and says so" 'grep -q "^This is the first reading in paymcp.s record (.*pay.record.jsonl): the next one says what is new" "$T/a" && [ "$(grep -c "\"event\":\"found\"" "$T/pay.record.jsonl")" = 14 ] && ! grep -q "(new)" "$T/a"'
check "a decision needs a finding the record has, and a reason" '! "$B" decide "$T/pay.ini" free:sub_nobody intended a gift 2>"$T/err" && grep -q "No finding with the key free:sub_nobody is in the record" "$T/err" && ! "$B" decide "$T/pay.ini" free:sub_elm intended 2>"$T/err" && grep -q "Say why it is intended" "$T/err" && ! "$B" decide "$T/pay.ini" free:sub_elm forgiven x 2>"$T/err" && grep -q "a decision is intended" "$T/err"'
check "dismissed as intended, with the reason: written down, with no key needed" 'env -u STRIPE_KEY "$B" decide "$T/pay.ini" "[free:sub_elm]" intended a gift to our first customer >"$T/d" && grep -q "^Written down: free:sub_elm (Free, and has been for a while: 87.00 EUR a month, Elm & Sons) is dismissed as intended: a gift to our first customer\." "$T/d"'
check "the next audit leaves it out and says so; --all lists it" '"$B" audit "$T/pay.ini" >"$T/a2" && grep -qx "13 findings: 284.00 EUR a month and 1143.00 EUR once." "$T/a2" && grep -qx "Since the reading of ....-..-..: nothing new, and nothing gone." "$T/a2" && grep -qx "1 dismissed as intended is not listed (87.00 EUR a month): ask for all to list them." "$T/a2" && ! grep -q "Elm & Sons" "$T/a2" && "$B" audit "$T/pay.ini" --all >"$T/a3" && grep -qx "14 findings: 371.00 EUR a month and 1143.00 EUR once." "$T/a3" && grep -qx "1. Free, and has been for a while: 87.00 EUR a month (dismissed as intended)" "$T/a3" && grep -q "^   Dismissed on ....-..-..: a gift to our first customer$" "$T/a3"'
check "the record: readings, what is open, what was dismissed and why" 'env -u STRIPE_KEY "$B" record "$T/pay.ini" >"$T/r" && grep -q "pay.record.jsonl: [0-9]* readings since ....-..-.., the last on ....-..-..\.$" "$T/r" && grep -qx "Open now: 13 findings, 284.00 EUR a month and 1143.00 EUR once." "$T/r" && grep -qx "Dismissed as intended: 1 finding, 87.00 EUR a month." "$T/r" && grep -q "Elm & Sons: \"a gift to our first customer\"  \[free:sub_elm\]$" "$T/r" && grep -qx "No longer found: 0 findings." "$T/r"'
check "a finding goes: the next reading says no longer found, with its amount" 'grep -v "nobody@maple.example" "$T/who.csv" >"$T/who2.csv" && cp "$T/who.csv" "$T/who.keep" && cp "$T/who2.csv" "$T/who.csv" && "$B" audit "$T/pay.ini" >"$T/a4" && cp "$T/who.keep" "$T/who.csv" && grep -qx "Since the reading of ....-..-..: 1 no longer found (36.00 EUR a month)." "$T/a4" && "$B" audit "$T/pay.ini" >"$T/a5" && grep -qx "Since the reading of ....-..-..: 1 found again." "$T/a5" && grep -q "^[0-9]*\. Using the product, not in billing at all: 36.00 EUR a month (found again)$" "$T/a5"'
check "open again, and it is back on the list" '"$B" decide "$T/pay.ini" free:sub_elm open >"$T/d" && grep -q "is open again" "$T/d" && "$B" audit "$T/pay.ini" | grep -qx "14 findings: 371.00 EUR a month and 1143.00 EUR once."'
printf '[stripe]\nurl = http://127.0.0.1:%s\n[billing]\nrecord = none\n' "$PORT" >"$T/norecord.ini"
check "record = none: nothing is written, and a decision has nowhere to go" '"$B" audit "$T/norecord.ini" >"$T/nr" && ! grep -q "record" "$T/nr" && [ ! -e "$T/norecord.record.jsonl" ] && ! "$B" decide "$T/norecord.ini" free:sub_elm intended a gift 2>"$T/err" && grep -q "says record = none" "$T/err"'
check "an unknown command line is the usage" '! "$B" audit "$T/pay.ini" --fix 2>"$T/err" && grep -q "^usage: paymcp PAY.ini" "$T/err"'

# the files for a Stripe sandbox (customers found by address, every "how
# old" setting at 0), against the same business
cp examples/sandbox-who.csv "$T/sandbox-who.csv"
awk -v port="$PORT" '{ print } /^\[stripe\]/ { print "url = http://127.0.0.1:" port }' examples/sandbox.ini >"$T/sandbox.ini"
check "the sandbox's files: found by address, nothing has to be old" '"$B" audit "$T/sandbox.ini" >"$T/s" && grep -qx "15 findings: 371.00 EUR a month and 1143.00 EUR once; 1 with an amount this audit can.t know." "$T/s" && grep -q "Larch has been on a price of zero" "$T/s"'
check "the seed script: a dry run sends nothing and lists what it would" 'python3 -I scripts/seed-sandbox.py --dry-run >"$T/seed" && grep -qx "65 requests would be sent. Nothing was sent." "$T/seed" && [ "$(grep -c "^POST /v1/subscriptions  " "$T/seed")" = 12 ] && [ "$(grep -c "^POST /v1/payment_methods/" "$T/seed")" = 1 ] && grep -q "^POST /v1/payment_methods/pm_card_chargeCustomerFail/attach" "$T/seed"'
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
check("four tools; the one that writes, writes only paymcp's own record", [t["name"] for t in tools] == ["billing_audit", "billing_finding", "billing_decide", "billing_record"] and [t["annotations"]["readOnlyHint"] for t in tools] == [True, True, False, True] and "Changes nothing at the billing provider" in tools[2]["description"], json.dumps(tools)[:600])
text, err = m.call("billing_audit")
check("billing_audit: the sums and the findings", not err and "14 findings: 371.00 EUR a month and 1143.00 EUR once." in text and "More seats than paid for: 48.00 EUR a month\n   Alder Works has 9 seats in the product and pays for 5." in text, text)
text, err = m.call("billing_audit", {"kind": "usage_not_reported"})
check("one kind", not err and "1 finding of the kind usage_not_reported (14 in all): 126.00 EUR once." in text and "Fir Analytics used 15300 this period in the product; billing was told of 9000." in text and "Alder" not in text, text)
text, err = m.call("billing_audit", {"limit": 2})
check("a limit says what it left out", not err and "\n2. " in text and "\n3. " not in text and "...and 12 more, smaller" in text, text)
text, err = m.call("billing_finding", {"key": "written_off:cus_ivy:eur"})
check("billing_finding: one finding with its rows", not err and text.startswith("Invoices written off: 120.00 EUR, once") and "- invoice in_ivy_bad: uncollectible, 60.00 EUR" in text and "in_ivy_never" not in text, text)
text, err = m.call("billing_finding", {"key": "written_off:cus_nobody:eur"})
check("a key no finding has is said", err and "No finding has the key" in text, text)
text, err = m.call("billing_audit", {"customer": "cus_alder"})
check("a field the tool doesn't take is refused", err and "billing_audit has no field customer; it takes kind, limit, fresh, all." in text, text)
text, err = m.call("billing_fix", {"key": "paused:sub_gorse"})
check("there is no tool that changes anything at the provider", err and "no tool called billing_fix" in text, text)
text, err = m.call("billing_decide", {"key": "paused:sub_gorse", "decision": "asked", "reason": "wrote to Gorse"})
check("billing_decide: a person's decision, written down", not err and "Written down: paused:sub_gorse (Collection paused: 29.00 EUR a month, Gorse Ltd) is marked as asked: wrote to Gorse." in text, text)
text, err = m.call("billing_audit", {"kind": "paused"})
check("the audit marks it", not err and "1. Collection paused: 29.00 EUR a month (asked)" in text and "   Asked on " in text, text)
text, err = m.call("billing_record")
check("billing_record: where things stand", not err and "Asked, waiting for an answer: 1 finding, 29.00 EUR a month." in text and "[paused:sub_gorse]" in text, text)
res = m.rpc("resources/read", {"uri": "pay://findings"})
body = json.loads(res["result"]["contents"][0]["text"])
check("the findings as a resource", len(body["findings"]) == 14 and "not instructions" in body["note"] and [f["state"] for f in body["findings"] if f["kind"] == "paused"] == ["asked"], json.dumps(body)[:600])
check("paymcp ends when its input does", m.close() == 0)
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/mcp.py" "$B" "$T/pay.ini" || fail=1
check "the key is in nothing paymcp wrote" '! grep -rq "$KEY" "$T/a" "$T/a.json" "$T/c" "$T/n" "$T/m" "$T/err" "$T/r" "$T/pay.record.jsonl"'

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- sim"
	cat "$T/sim.out"
	exit 1
fi
