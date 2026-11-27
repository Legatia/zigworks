#!/usr/bin/env python3
"""Fills a Stripe SANDBOX with the made-up business that paymcp-sim plays,
so that paymcp can be run against Stripe itself with nothing real in it.

    STRIPE_SEED_KEY=sk_test_... python3 scripts/seed-sandbox.py
    python3 scripts/seed-sandbox.py --dry-run     # print the requests, send nothing

It writes, so it has a key of its own (STRIPE_SEED_KEY, never paymcp's
STRIPE_KEY) and takes only a sandbox key: sk_test_... or rk_test_...
A live key is refused before anything is sent. Nothing is charged: no
payment method is added to any customer. Use a sandbox made for this and
delete the sandbox afterwards; the script stops if the business is
already there.

Written from Stripe's API reference for version 2026-11-18.endive.
Needs python3 and nothing else.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

API_VERSION = "2026-11-18.endive"
STRIPE = "https://api.stripe.com"
METER_EVENT = "paymcp_seed_api_calls"

# name, address
CUSTOMERS = [
    ("alder", "Alder Works", "billing@alder.example"),
    ("birch", "Birch Studio", "ola@birch.example"),
    ("cedar", "Cedar Co", "accounts@cedar.example"),
    ("dogwood", "Dogwood Labs", "finance@dogwood.example"),
    ("elm", "Elm & Sons", "office@elm.example"),
    ("fir", "Fir Analytics", "ap@fir.example"),
    ("gorse", "Gorse Ltd", "pay@gorse.example"),
    ("hazel", "Hazel Design", "hello@hazel.example"),
    ("ivy", "Ivy Partners", "ivy@ivy.example"),
    ("juniper", "Juniper", "team@juniper.example"),
    ("kapok", "Kapok", "kapok@kapok.example"),
    ("larch", "Larch", "larch@larch.example"),
]

EXPECTED = """\
With examples/sandbox.ini (every "how old" setting at 0, since nothing in a
new sandbox is old) the audit should say:

  15 findings: 371.00 EUR a month and 871.00 EUR once; 1 with an amount this audit can't know.

   87.00 a month   Free, and has been for a while       Elm & Sons (everything off, for ever)
   68.00 a month   A higher plan than paid for          Birch Studio (pro in the product, billed for team)
   58.00 a month   Using the product, not paying        Cedar Co (subscription cancelled)
   48.00 a month   More seats than paid for             Alder Works (9 in the product, 5 paid)
   36.00 a month   Using the product, not in billing    nobody@maple.example
   30.00 a month   A price no longer sold               Dogwood Labs (Team 2023)
   29.00 a month   Collection paused                    Gorse Ltd
   15.00 a month   A discount with no end               Alder Works (Launch, 25% off)
  480.00 once      An invoice never sent                Gorse Ltd (a draft)
  126.00 once      Use that was never reported          Fir Analytics (15300 used, 9000 reported)
  120.00 once      Invoices written off                 Ivy Partners (one uncollectible, one void)
   58.00 once      An invoice never sent                Cedar Co (the cancelled subscription's draft)
   58.00 once      An invoice never sent                Ivy Partners (the cancelled subscription's draft)
   29.00 once      An invoice never charged             Hazel Design
   not known       Free, and has been for a while       Larch (a price of zero)

Nothing about Juniper (a yearly plan, a discount that ends) or Kapok (in
trial). Where Stripe's answer differs from this list, the difference is
what the run is for: note it.

This is what a run on 2026-11-27 gave. The two drafts at 58.00 are not in
paymcp-sim's business: Stripe leaves a cancelled subscription's first
invoice a draft that it will never send.

For a few minutes after seeding, Stripe has not yet counted the meter
event, and "Use that was never reported" says 0 was reported (306.00,
and 1051.00 once in all).
"""


class Fail(Exception):
    pass


class Stripe:
    def __init__(self, url, key, dry):
        self.url = url
        self.key = key
        self.dry = dry
        self.n = 0
        self.made = []

    def call(self, method, path, fields=None):
        """One request; the answer as a dict. `fields`: a list of (name, value)."""
        fields = fields or []
        self.n += 1
        if self.dry:
            print(f"{method} {path}" + ("  " + "  ".join(f"{k}={v}" for k, v in fields) if fields else ""))
            if method == "GET":
                return {"data": []}
            noun = [p for p in path.split("/") if p and not p.startswith(("dry_", "v1"))]
            return {"id": f"dry_{noun[0] if noun else 'x'}_{self.n}", "livemode": False, "status": "dry"}
        target = self.url + path
        data = None
        if method == "GET":
            if fields:
                target += "?" + urllib.parse.urlencode(fields)
        else:
            data = urllib.parse.urlencode(fields).encode()
        headers = {
            "Authorization": "Bearer " + self.key,
            "Stripe-Version": API_VERSION,
            "User-Agent": "paymcp-seed",
        }
        if method == "POST":
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            # the same key on every try: a request sent twice is made once
            headers["Idempotency-Key"] = str(uuid.uuid4())
        last = ""
        for attempt in range(4):
            req = urllib.request.Request(target, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=60) as res:
                    return json.loads(res.read().decode())
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")
                try:
                    message = json.loads(body)["error"]["message"]
                except (ValueError, KeyError, TypeError):
                    message = body[:300]
                last = f"{e.code}: {message}"
                if e.code != 429 and e.code < 500:
                    break
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                last = f"not reached ({e})"
            time.sleep(1 << attempt)
        raise Fail(f"{method} {path}: {last}")

    def make(self, kind, path, fields):
        o = self.call("POST", path, fields)
        if o.get("livemode") is True:
            raise Fail(f"{path} answered livemode=true: this is not a sandbox. Stopped after one object ({o.get('id')}); delete it in the Dashboard.")
        if "id" not in o:
            raise Fail(f"POST {path}: the answer had no id")
        self.made.append((kind, o["id"]))
        return o["id"]


def seed(s):
    found = s.call("GET", "/v1/customers", [("email", CUSTOMERS[0][2]), ("limit", "1")])
    if found.get("data"):
        raise Fail(f"this sandbox already has {CUSTOMERS[0][2]}: the made-up business is there (or half of it). Use a new sandbox.")

    tag = ("metadata[paymcp_seed]", "1")

    coupon = {}
    for name, percent, more in [
        ("Launch", "25", [("duration", "forever")]),
        ("Friends", "100", [("duration", "forever")]),
        ("Welcome", "10", [("duration", "repeating"), ("duration_in_months", "12")]),
    ]:
        coupon[name] = s.make("coupon", "/v1/coupons", [("name", name), ("percent_off", percent)] + more + [tag])

    product = {}
    for key, name in [("team", "Team"), ("pro", "Pro"), ("api", "API calls"), ("comped", "Pro, comped")]:
        product[key] = s.make("product", "/v1/products", [("name", name), tag])

    meter = s.make("meter", "/v1/billing/meters", [
        ("display_name", "API calls"),
        ("event_name", METER_EVENT),
        ("default_aggregation[formula]", "sum"),
        ("customer_mapping[type]", "by_id"),
        ("customer_mapping[event_payload_key]", "stripe_customer_id"),
        ("value_settings[event_payload_key]", "value"),
    ])

    def price(prod, amount, interval, extra):
        return s.make("price", "/v1/prices", [
            ("product", product[prod]), ("currency", "eur"), ("unit_amount", str(amount)),
            ("recurring[interval]", interval), ("recurring[interval_count]", "1"),
        ] + extra + [tag])

    def lookup(key):
        return [("lookup_key", key), ("transfer_lookup_key", "true")]

    prices = {
        "team": price("team", 1200, "month", lookup("team_monthly")),
        "pro": price("pro", 2900, "month", lookup("pro_monthly")),
        "pro_year": price("pro", 29000, "year", lookup("pro_yearly")),
        "api": price("api", 2, "month", [("recurring[usage_type]", "metered"), ("recurring[meter]", meter), ("nickname", "API calls")]),
        "team_2023": price("team", 900, "month", [("nickname", "Team 2023")]),
        "comped": price("comped", 0, "month", [("nickname", "Pro, comped")]),
    }

    cus = {}
    for key, name, email in CUSTOMERS:
        cus[key] = s.make("customer", "/v1/customers", [("name", name), ("email", email), tag])

    def subscribe(who, items, extra=None):
        fields = [("customer", cus[who]), ("collection_method", "send_invoice"), ("days_until_due", "30")]
        for i, (p, quantity) in enumerate(items):
            fields.append((f"items[{i}][price]", prices[p]))
            # an item billed by use has no quantity
            if quantity is not None:
                fields.append((f"items[{i}][quantity]", str(quantity)))
        return s.make("subscription", "/v1/subscriptions", fields + (extra or []) + [tag])

    sub = {
        # 25% off with no end; nine seats in the product, five paid
        "alder": subscribe("alder", [("team", 5)], [("discounts[0][coupon]", coupon["Launch"])]),
        # on Pro in the product, billed for Team
        "birch": subscribe("birch", [("team", 4)]),
        # cancelled below, still active in the product
        "cedar": subscribe("cedar", [("pro", 2)]),
        # on a price withdrawn below
        "dogwood": subscribe("dogwood", [("team_2023", 10)]),
        # everything off, for good
        "elm": subscribe("elm", [("pro", 3)], [("discounts[0][coupon]", coupon["Friends"])]),
        # metered: 15300 used in the product, 9000 reported below
        "fir": subscribe("fir", [("team", 5), ("api", None)]),
        # collection paused below, with no date to resume
        "gorse": subscribe("gorse", [("pro", 1)]),
        "hazel": subscribe("hazel", [("pro", 1)]),
        "ivy": subscribe("ivy", [("pro", 2)]),
        # nothing to find: a yearly plan with a discount that ends
        "juniper": subscribe("juniper", [("pro_year", 1)], [("discounts[0][coupon]", coupon["Welcome"])]),
        # nothing to find: in trial
        "kapok": subscribe("kapok", [("team", 2)], [("trial_period_days", "14")]),
        # a price of zero
        "larch": subscribe("larch", [("comped", 1)]),
    }

    s.call("DELETE", f"/v1/subscriptions/{sub['cedar']}")
    s.call("DELETE", f"/v1/subscriptions/{sub['ivy']}")
    s.call("POST", f"/v1/subscriptions/{sub['gorse']}", [("pause_collection[behavior]", "void")])
    # no longer sold; Dogwood stays on it
    s.call("POST", f"/v1/prices/{prices['team_2023']}", [("active", "false")])

    def invoice(who, amount, what):
        # the invoice first, then its line put on it by name: nothing
        # depends on which pending items an invoice picks up
        inv = s.make("invoice", "/v1/invoices", [
            ("customer", cus[who]), ("currency", "eur"), ("collection_method", "charge_automatically"),
            ("auto_advance", "false"), ("description", what), tag,
        ])
        s.call("POST", "/v1/invoiceitems", [("customer", cus[who]), ("invoice", inv), ("amount", str(amount)), ("currency", "eur"), ("description", what)])
        return inv

    def finalize(inv):
        # (auto_advance false: Stripe is not to try a payment or move it on)
        s.call("POST", f"/v1/invoices/{inv}/finalize", [("auto_advance", "false")])
        return inv

    # a draft never sent
    invoice("gorse", 48000, "Onboarding and data migration")
    # open, to be charged by Stripe, never tried (no payment method)
    finalize(invoice("hazel", 2900, "Pro, one extra month"))
    # sent, then given up on: one uncollectible, one void
    s.call("POST", f"/v1/invoices/{finalize(invoice('ivy', 6000, 'Pro, August'))}/mark_uncollectible")
    s.call("POST", f"/v1/invoices/{finalize(invoice('ivy', 6000, 'Pro, September'))}/void")

    # what billing was told of Fir's use
    s.call("POST", "/v1/billing/meter_events", [("event_name", METER_EVENT), ("payload[stripe_customer_id]", cus["fir"]), ("payload[value]", "9000")])


def main():
    ap = argparse.ArgumentParser(description="Fill a Stripe sandbox with paymcp-sim's made-up business.")
    ap.add_argument("--dry-run", action="store_true", help="print the requests, send nothing (needs no key)")
    ap.add_argument("--yes", action="store_true", help="don't ask before sending")
    ap.add_argument("--url", default=STRIPE, help=argparse.SUPPRESS)
    args = ap.parse_args()

    key = os.environ.get("STRIPE_SEED_KEY", "")
    if not args.dry_run:
        if not key:
            sys.exit("seed-sandbox: STRIPE_SEED_KEY isn't set: the sandbox's secret key (sk_test_...). Not paymcp's STRIPE_KEY, which can only read.")
        if "_live_" in key or not key.startswith(("sk_test_", "rk_test_")):
            sys.exit("seed-sandbox: STRIPE_SEED_KEY is not a sandbox key (sk_test_... or rk_test_...). Nothing was sent. This script never writes to a live account.")
        local = args.url.startswith(("http://127.0.0.1:", "http://localhost:"))
        if not args.url.startswith("https://") and not local:
            sys.exit("seed-sandbox: --url is https://..., or http:// on this computer only: a key isn't sent in the clear")
        if not args.yes:
            if not sys.stdin.isatty():
                sys.exit("seed-sandbox: nobody to ask (no terminal). Run it with --yes once you have read what it does.")
            print("This creates, in the Stripe sandbox the key belongs to: 12 customers, 12 subscriptions,")
            print("4 invoices, 6 prices, 4 products, 3 coupons, a meter and a meter event. No payment")
            print("method is added, so nothing is charged; the customers' addresses end in .example.")
            try:
                answer = input("Go on? [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes"):
                sys.exit("seed-sandbox: nothing was sent.")

    s = Stripe(args.url.rstrip("/"), key, args.dry_run)
    try:
        seed(s)
    except Fail as e:
        print(f"seed-sandbox: {e}", file=sys.stderr)
        if s.made:
            print(f"Made before it stopped: {len(s.made)} objects ({', '.join(sorted(set(k for k, _ in s.made)))}). The sandbox now holds half the business: delete the sandbox and start in a new one.", file=sys.stderr)
        return 1
    if args.dry_run:
        print(f"\n{s.n} requests would be sent. Nothing was sent.")
        return 0
    print(f"Done: {s.n} requests, {len(s.made)} objects made. Nothing was charged.\n")
    print("Now, with a restricted key that can only read (README, The key), or this sandbox's secret key:\n")
    print("  STRIPE_KEY=rk_test_... paymcp check examples/sandbox.ini")
    print("  STRIPE_KEY=rk_test_... paymcp audit examples/sandbox.ini\n")
    print(EXPECTED)
    return 0


if __name__ == "__main__":
    sys.exit(main())
