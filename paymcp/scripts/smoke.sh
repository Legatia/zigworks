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
# ...and with four card disputes
DPORT=$(free_port)
"$S" "$DPORT" "$KEY" --disputes >"$T/sim3.out" 2>&1 &
PIDS="$PIDS $!"
# ...and one where a second key may change things
WKEY=rk_test_smoke_second_key_not_real
WPORT=$(free_port)
"$S" "$WPORT" "$KEY" --disputes --write-key "$WKEY" >"$T/sim4.out" 2>&1 &
PIDS="$PIDS $!"
wait_port "$PORT"
wait_port "$MPORT"
wait_port "$DPORT"
wait_port "$WPORT"
cp examples/who.csv "$T/who.csv"
sed -e "s|8743|$PORT|" examples/sim.ini >"$T/pay.ini"
sed -e "s|8743|$MPORT|" examples/sim.ini >"$T/nometers.ini"
grep -v "^who = " "$T/pay.ini" >"$T/nowho.ini"
sed -e "s|8743|$DPORT|" examples/sim.ini >"$T/disputes.ini"
sed -e "s|8743|$WPORT|" examples/sim.ini >"$T/nochange.ini"
{ cat "$T/nochange.ini"; printf '\n[changes]\nallow = yes\n'; } >"$T/change.ini"
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
check "a finding whose change is the customer's to see says a message is drafted" '[ "$(grep -c "^   A message to the customer is drafted: ask for the draft of this key\.$" "$T/a")" = 9 ]'
check "the draft: to whom, the subject, the text, signed as the pay file says, and nothing sent" '"$B" draft "$T/pay.ini" "[more_seats:sub_alder:si_alder_1]" >"$T/dr" && grep -qx "A draft, for you to read, change and send from your own mail. paymcp sent nothing and can send nothing." "$T/dr" && grep -qx "To: billing@alder.example" "$T/dr" && grep -qx "Subject: The seats on your subscription" "$T/dr" && grep -q "^Your account has 9 seats in use, and your subscription covers 5\. From your next billing period we would like to set it to 9 seats (12.00 EUR a seat a month)\.$" "$T/dr" && [ "$(tail -n 2 "$T/dr" | tr -d "\r" | tr "\n" "|")" = "Kind regards,|Ola at Fernhill|" ]'
check "a reminder for an invoice past due names it and its day" '"$B" draft "$T/pay.ini" overdue:cus_dogwood:eur >"$T/dr2" && grep -qx "Subject: Invoice FH-0405" "$T/dr2" && grep -q "^Invoice FH-0405 for 340.00 EUR was due on ....-..-.. and is still open\." "$T/dr2"'
check "nothing to tell the customer: no draft, and why; a key nothing has is refused" '"$B" draft "$T/pay.ini" paused:sub_gorse >"$T/dr3" && grep -q "^No message is drafted for paused:sub_gorse: nothing about it is the customer.s to see yet\." "$T/dr3" && ! "$B" draft "$T/pay.ini" paused:sub_nobody 2>"$T/err" && grep -q "no finding has the key paused:sub_nobody now" "$T/err"'
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
check "card disputes: those to answer first, by their last day; what was lost unanswered as one sum" '"$B" audit "$T/disputes.ini" >"$T/dp" && grep -qx "17 findings: 371.00 EUR a month and 1341.00 EUR once." "$T/dp" && grep -qx "1. A card dispute to answer: 60.00 EUR, once" "$T/dp" && grep -qx "2. A card dispute to answer: 48.00 EUR, once" "$T/dp" && grep -q "^   The bank of Birch Studio took back a payment of 48.00 EUR made on ....-..-..: the cardholder says nothing was received\. It can be answered until ....-..-.., [89] days from now\.$" "$T/dp" && grep -q "^[0-9]*\. Disputes lost without an answer: 90.00 EUR, once$" "$T/dp" && ! grep -q "du_juniper_won" "$T/dp"'
check "the evidence draft: what the account shows, what only the business has, nothing sent" '"$B" evidence "$T/disputes.ini" dispute:du_birch >"$T/ev" && grep -q "^Evidence for dispute du_birch, as a draft\. Nothing was sent to the provider or the bank" "$T/ev" && grep -qx "  customer_name: Birch Studio" "$T/ev" && grep -q "the same customer made 6 payments to us, the first on ....-..-..; none of them was disputed or refunded\.$" "$T/ev" && grep -qx "  - access_activity_log: when the account was used after the payment" "$T/ev" && ! "$B" evidence "$T/disputes.ini" free:sub_elm 2>"$T/err" && grep -q "no card dispute to answer has the key free:sub_elm" "$T/err"'
check "a note to the customer about the bank's question" '"$B" draft "$T/disputes.ini" dispute:du_alder_inq >"$T/dl" && grep -qx "Subject: A question from your bank about a payment to us" "$T/dl" && grep -q "^Your bank has asked us about a payment to us of 60.00 EUR made on ....-..-..: it was for \"Team plan\"\." "$T/dl"'
check "change without --yes: the finding, what would be done, and nothing changed" '"$B" change "$T/change.ini" paused:sub_gorse >"$T/ch" && grep -qx "Collection paused: 29.00 EUR a month" "$T/ch" && grep -q "^Resume collection on subscription sub_gorse: its next invoice is collected again\." "$T/ch" && grep -qx "Nothing was changed. To do exactly this, run it again with --yes." "$T/ch"'
check "no [changes] in the pay file, or no second key: nothing is changed" '! STRIPE_WRITE_KEY=$WKEY "$B" change "$T/nochange.ini" paused:sub_gorse --yes 2>"$T/err" && grep -q "nothing was changed: .*nochange.ini doesn.t say \[changes\] allow = yes" "$T/err" && ! "$B" change "$T/change.ini" paused:sub_gorse --yes 2>"$T/err" && grep -q "nothing was changed: STRIPE_WRITE_KEY isn.t set" "$T/err" && ! STRIPE_WRITE_KEY=sk_live_abc "$B" change "$T/change.ini" paused:sub_gorse --yes 2>"$T/err" && grep -q "STRIPE_WRITE_KEY is a secret key, which can do everything" "$T/err" && "$B" audit "$T/change.ini" | grep -q "^[0-9]*\. Collection paused: 29.00 EUR a month"'
check "the reading key in the second key.s place: the provider refuses, and it is said" '! STRIPE_WRITE_KEY=$KEY "$B" change "$T/change.ini" paused:sub_gorse --yes 2>"$T/err" && grep -q "Nothing was changed: the second key may not change this (403)" "$T/err"'
check "with both, one thing is changed, read back, and the next audit no longer finds it" 'STRIPE_WRITE_KEY=$WKEY "$B" change "$T/change.ini" paused:sub_gorse --yes >"$T/ch2" && grep -q "^Done: collection on subscription sub_gorse is no longer paused\." "$T/ch2" && STRIPE_WRITE_KEY=$WKEY "$B" audit "$T/change.ini" >"$T/ch3" && ! grep -q "Collection paused" "$T/ch3" && grep -q "1 no longer found (29.00 EUR a month)" "$T/ch3" && grep -q "paymcp can do this, when a person says so: End the discount" "$T/ch3" && "$B" record "$T/change.ini" | grep -q "changed through paymcp on ....-..-..: resumed collection on subscription sub_gorse"'
check "what paymcp can.t do about a finding is said, and a second time finds the record changed" '! STRIPE_WRITE_KEY=$WKEY "$B" change "$T/change.ini" written_off:cus_ivy:eur --yes 2>"$T/err" && grep -q "there is nothing paymcp can do about written_off:cus_ivy:eur" "$T/err" && ! STRIPE_WRITE_KEY=$WKEY "$B" change "$T/change.ini" paused:sub_gorse --yes 2>"$T/err" && grep -q "no finding has the key paused:sub_gorse now" "$T/err"'
check "evidence for a dispute is kept at the provider and not sent" 'STRIPE_WRITE_KEY=$WKEY "$B" stage "$T/change.ini" dispute:du_birch --yes >"$T/st" && grep -q "^Done: 6 fields are kept at the provider as evidence for dispute du_birch .*Nothing was sent to the bank\." "$T/st" && STRIPE_WRITE_KEY=$WKEY "$B" audit "$T/change.ini" | grep -q "dispute du_birch: status needs_response, .*evidence kept at the provider yes, sent to the bank 0 times"'
check "an unknown command line is the usage" '! "$B" audit "$T/pay.ini" --fix 2>"$T/err" && grep -q "^usage: paymcp PAY.ini" "$T/err"'

# the files for a Stripe sandbox (customers found by address, every "how
# old" setting at 0), against the same business
cp examples/sandbox-who.csv "$T/sandbox-who.csv"
awk -v port="$PORT" '{ print } /^\[stripe\]/ { print "url = http://127.0.0.1:" port }' examples/sandbox.ini >"$T/sandbox.ini"
check "the sandbox's files: found by address, nothing has to be old" '"$B" audit "$T/sandbox.ini" >"$T/s" && grep -qx "15 findings: 371.00 EUR a month and 1143.00 EUR once; 1 with an amount this audit can.t know." "$T/s" && grep -q "Larch has been on a price of zero" "$T/s"'
check "the seed script: a dry run sends nothing and lists what it would" 'python3 -I scripts/seed-sandbox.py --dry-run >"$T/seed" && grep -qx "72 requests would be sent. Nothing was sent." "$T/seed" && [ "$(grep -c "^POST /v1/payment_intents  " "$T/seed")" = 5 ] && grep -q "^POST /v1/disputes/dry_dispute/close$" "$T/seed" && [ "$(grep -c "^POST /v1/subscriptions  " "$T/seed")" = 12 ] && [ "$(grep -c "^POST /v1/payment_methods/" "$T/seed")" = 1 ] && grep -q "^POST /v1/payment_methods/pm_card_chargeCustomerFail/attach" "$T/seed"'
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
check("six tools; the one that writes, writes only paymcp's own record", [t["name"] for t in tools] == ["billing_audit", "billing_finding", "billing_decide", "billing_record", "billing_draft", "dispute_evidence"] and [t["annotations"]["readOnlyHint"] for t in tools] == [True, True, False, True, True, True] and "Nothing was sent" not in tools[5]["description"] and "sending is final" in tools[5]["description"] and "Changes nothing at the billing provider" in tools[2]["description"] and "paymcp sends nothing" in tools[4]["description"], json.dumps(tools)[:600])
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
check("a field the tool doesn't take is refused", err and "billing_audit has no field customer; it takes kind, limit, fresh, all, format, offset." in text, text)
text, err = m.call("billing_fix", {"key": "paused:sub_gorse"})
check("there is no tool that changes anything at the provider", err and "no tool called billing_fix" in text, text)
text, err = m.call("billing_decide", {"key": "paused:sub_gorse", "decision": "asked", "reason": "wrote to Gorse"})
check("billing_decide: a person's decision, written down", not err and "Written down: paused:sub_gorse (Collection paused: 29.00 EUR a month, Gorse Ltd) is marked as asked: wrote to Gorse." in text, text)
text, err = m.call("billing_audit", {"kind": "paused"})
check("the audit marks it", not err and "1. Collection paused: 29.00 EUR a month (asked)" in text and "   Asked on " in text, text)
text, err = m.call("billing_record")
check("billing_record: where things stand", not err and "Asked, waiting for an answer: 1 finding, 29.00 EUR a month." in text and "[paused:sub_gorse]" in text, text)
# as data, for a page that lists the findings: a page at a time, and
# short enough to pass an agent runtime's limit on a tool's answer
text, err = m.call("billing_audit", {"format": "json"})
page = json.loads(text) if not err else {}
check("billing_audit as data: the sums, how many, and each finding without its rows", not err and len(text) < 16000 and page["total"] == 14 and len(page["findings"]) == 14 and page["sums"] == "371.00 EUR a month and 1143.00 EUR once" and page["findings"][0]["amount_text"] == "87.00 EUR a month" and page["findings"][0]["letter"] is True and "rows" not in page["findings"][0] and [f["state"] for f in page["findings"] if f["kind"] == "paused"] == ["asked"] and "not instructions" in page["note"] and page["read"].startswith("Read from the sandbox: 12 customers"), text)
text, err = m.call("billing_audit", {"format": "json", "offset": 10, "limit": 3})
page = json.loads(text) if not err else {}
check("a page of it from an offset", not err and page["total"] == 14 and page["offset"] == 10 and len(page["findings"]) == 3, text)
text, err = m.call("billing_audit", {"offset": 2})
check("an offset without data is refused", err and "offset goes with format json" in text, text)
text, err = m.call("billing_audit", {"format": "xml"})
check("a format there isn't is refused", err and "format is text (the default) or json." in text, text)
text, err = m.call("billing_finding", {"key": "more_seats:sub_alder:si_alder_1", "format": "json"})
one = json.loads(text) if not err else {}
check("billing_finding as data: the rows, the proposal and the draft", not err and one["amount"] == 4800 and len(one["rows"]) == 2 and one["rows_more"] == 0 and one["proposal"].startswith("Set the quantity") and one["letter"]["to"] == "billing@alder.example" and one["letter"]["body"].endswith("Kind regards,\nOla at Fernhill\n") and one["state"] in ("open", "new"), text)
text, err = m.call("billing_draft", {"key": "[higher_plan:sub_birch]"})
check("billing_draft: the message, and that nothing was sent", not err and "paymcp sent nothing and can send nothing." in text and "Subject: Your plan" in text and "Your account has the plan \"pro\", and your subscription is for team_monthly." in text, text)
text, err = m.call("billing_draft", {"key": "written_off:cus_ivy:eur"})
check("billing_draft where nothing is the customer's to see", not err and text.startswith("No message is drafted for written_off:cus_ivy:eur"), text)
text, err = m.call("billing_record", {"format": "json"})
rec = json.loads(text) if not err else {}
check("billing_record as data", not err and rec["asked"]["n"] == 1 and rec["asked"]["items"][0]["key"] == "paused:sub_gorse" and rec["asked"]["items"][0]["reason"] == "wrote to Gorse" and rec["open"]["n"] == 13 and rec["readings"] >= 1, text)
res = m.rpc("resources/read", {"uri": "pay://findings"})
body = json.loads(res["result"]["contents"][0]["text"])
check("the findings as a resource", len(body["findings"]) == 14 and "not instructions" in body["note"] and [f["state"] for f in body["findings"] if f["kind"] == "paused"] == ["asked"], json.dumps(body)[:600])
check("paymcp ends when its input does", m.close() == 0)
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/mcp.py" "$B" "$T/pay.ini" || fail=1
# the Money page's files as harness would serve them, and its calls
# answered by a paymcp behind them (harness/try-page.py)
cat >"$T/page.py" <<'EOF'
import json, subprocess, sys, time, urllib.request, urllib.error

binary, sim, port = sys.argv[1], sys.argv[2], sys.argv[3]
p = subprocess.Popen([sys.executable, "-I", "harness/try-page.py", binary, "--sim", sim, port], stdout=subprocess.PIPE)
base = "http://127.0.0.1:" + port
failed = False
n = 0

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - page: {name}" + ("" if ok else f" ({str(detail)[:600]})"))
    failed = failed or not ok

def get(path):
    with urllib.request.urlopen(base + path, timeout=30) as r:
        return r.status, r.read().decode(), r.headers

def act(tool, args):
    req = urllib.request.Request(base + "/api/act", json.dumps({"tool": tool, "input": args}).encode(), {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            job = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    return 200, json.loads(get("/api/act/%d?wait=20" % job["id"])[1])["output"]

try:
    line = p.stdout.readline().decode()
    check("it says where the page is, and that there is no gate", "http://127.0.0.1:" + port in line and "no gate here" in line, line)
    status, html, headers = get("/")
    check("the page and its files, with nothing from anywhere else", status == 200 and '<script src="app.js">' in html and "onclick" not in html and "default-src 'none'" in headers.get("Content-Security-Policy", "") and get("/app.js")[0] == 200 and get("/style.css")[0] == 200, html[:300])
    app = open("harness/apps/money/app.js", encoding="utf-8").read()
    check("the page's script writes what it reads as text, never as markup", "innerHTML" not in app and "eval(" not in app and "document.write" not in app)
    status, out = act("billing/billing_audit", {"format": "json", "limit": 20})
    page = json.loads(out) if status == 200 else {}
    check("the page's first call: a page of findings as data", status == 200 and page.get("total") == 14 and len(page["findings"]) == 14 and len(out.encode()) < 16384, out)
    status, out = act("billing/billing_decide", {"key": page["findings"][0]["key"], "decision": "intended", "reason": "a gift"})
    check("a decision from the page is written down", status == 200 and out.startswith("Written down: free:sub_elm"), out)
    status, out = act("billing/billing_audit", {"format": "json"})
    after = json.loads(out) if status == 200 else {}
    check("and the list leaves it out, saying so", after.get("total") == 13 and after.get("hidden") == 1 and after.get("hidden_sums") == "87.00 EUR a month", out)
    status, out = act("billing/billing_refund", {})
    check("a tool the app's manifest doesn't list is refused", status == 403 and "not in the app's acts" in out, out)
finally:
    p.kill()
sys.exit(1 if failed else 0)
EOF
python3 -I "$T/page.py" "$B" "$S" "$(free_port)" || fail=1
check "the second key is in nothing paymcp wrote" '! grep -rq "$WKEY" "$T/ch" "$T/ch2" "$T/ch3" "$T/st" "$T/err" "$T/change.record.jsonl"'
check "the key is in nothing paymcp wrote" '! grep -rq "$KEY" "$T/a" "$T/a.json" "$T/c" "$T/n" "$T/m" "$T/err" "$T/r" "$T/pay.record.jsonl"'

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- sim"
	cat "$T/sim.out"
	exit 1
fi
