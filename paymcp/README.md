# paymcp

What your customers should be paying and are not, and what they owe you
that is late, found in your billing account by fixed rules, as tools for
an AI agent over MCP on stdio or as a report on the command line. It reads
Stripe Billing with a key that can only read, and changes nothing there.

```
agent ──MCP, stdio──▶ paymcp ──https, GET only──▶ Stripe
                        │
                        ├── your own file of who has what (optional, CSV)
                        └── its own record: what each reading found, what you decided
```

Every finding has an amount (or says plainly that the amount isn't known),
the rows it rests on, and what is proposed. A finding is a question for a
person, not a mistake found: a discount may be meant to last, an old price
may be a promise. So "it is meant to be so" is an answer paymcp keeps,
with your reason, and from the second reading on a report says what is
new and what is no longer found.

Linux and Windows; it builds for macOS (where it links libc, as calmcp
does) but hasn't been run there. One binary, nothing beyond the Zig
standard library.

**State: 0.2.0, written from Stripe's public documentation for API version
`2026-11-18.endive`, tested against `paymcp-sim` (a stand-in built from the
same documentation) and run against Stripe itself,** on 2026-11-27, in a
test account holding only the made-up business below: it found what it
was built to find there, with the amounts expected
([Against a Stripe sandbox](#against-a-stripe-sandbox)). It has never read
a live account, and never an account with real history in it. Run it on a
sandbox first and read the report against the dashboard before trusting a
number. See [Limits](#limits).

## Quick start, without an account

`paymcp-sim` is built alongside paymcp. It plays the billing provider for a
made-up software business with twelve customers: nine with something to
find, three with nothing.

```
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/paymcp-sim 8743 rk_test_not_a_real_key &
$ export STRIPE_KEY=rk_test_not_a_real_key
$ ./zig-out/bin/paymcp check examples/sim.ini
Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 7 invoices (drafts, open, and those written off in the last 365 days); from the business's own file: 7 rows.
9 requests, every one a GET. The key works and nothing was changed.
$ ./zig-out/bin/paymcp audit examples/sim.ini
Billing audit of 2026-11-27. Nothing was changed: paymcp only reads.
Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 7 invoices (drafts, open, and those written off in the last 365 days); from the business's own file: 7 rows.

14 findings: 371.00 EUR a month and 1143.00 EUR once.
Each is a question for a person, not a mistake found: a discount may be meant to last, an old price may be a promise.
This is the first reading in paymcp's record (examples/sim.record.jsonl): the next one says what is new and what is no longer found.

1. Free, and has been for a while: 87.00 EUR a month
   Elm & Sons pays nothing: the discount "Friends" takes everything off, with no end, since 2025-10-23.
   - subscription sub_elm: created 2025-10-23, list price 87.00 EUR a month
   - discount di_elm: coupon co_friends, 100% off, end none
   Proposed: If this is a gift that should last, dismiss it as intended. Otherwise end the discount from the next period and tell the customer first.
   [free:sub_elm]

2. A higher plan than paid for: 68.00 EUR a month
   Birch Studio has the plan "pro" in the product and is billed for team_monthly.
   - the business's file, line 3: plan pro (price price_pro, 29.00 EUR a unit a month)
   - subscription item si_birch_1: price price_team, 12.00 EUR a unit a month, quantity 4
   ...

10. Invoices past due: 340.00 EUR, once
   An invoice to Dogwood Labs for 340.00 EUR has been past due since 2026-11-06.
   - invoice FH-0405: due 2026-11-06, 21 days ago, remaining 340.00 EUR
   Proposed: Remind the customer, with the invoice's own link to pay. If they dispute it or can't pay, settle that on purpose: an invoice left open is neither collected nor written off.
   [overdue:cus_dogwood:eur]
   ...
```

Elm's discount is a gift, so say so, and look at the record:

```
$ ./zig-out/bin/paymcp decide examples/sim.ini free:sub_elm intended a gift to our first customer
Written down: free:sub_elm (Free, and has been for a while: 87.00 EUR a month, Elm & Sons) is dismissed as intended: a gift to our first customer. It is no longer listed, and comes back if its amount grows by more than a tenth.
$ ./zig-out/bin/paymcp audit examples/sim.ini
...
13 findings: 284.00 EUR a month and 1143.00 EUR once.
Each is a question for a person, not a mistake found: a discount may be meant to last, an old price may be a promise.
Since the reading of 2026-11-27: nothing new, and nothing gone.
1 dismissed as intended is not listed (87.00 EUR a month): ask for all to list them.
...
$ ./zig-out/bin/paymcp record examples/sim.ini
```

`paymcp audit examples/sim.ini --json` gives the audit as data, and
`--all` lists what was dismissed too. `paymcp examples/sim.ini` serves MCP
on stdin and stdout, the way an agent starts it.

## Against a Stripe sandbox

The first run against Stripe itself, with nothing real in it.
`scripts/seed-sandbox.py` fills a sandbox with the same made-up business
(needs python3 and nothing else). Both were run this way on 2026-11-27:
Stripe took every request of the script at the first try, and the audit's
answer is the one in step 4.

1. In the Stripe Dashboard: the account picker, **Switch to sandbox**,
   **Create sandbox**. Give it a name of its own and turn off "Copy live
   account to sandbox", so that it holds only the made-up business and can
   be deleted whole afterwards.
2. In that sandbox, under Developers, API keys: copy the **secret key**
   (`sk_test_...`) for the script, and create a **restricted key**
   (`rk_test_...`) that can only read ([The key](#the-key)) for paymcp.
   To only try it, the sandbox's secret key will do for paymcp too: it is
   taken with a note, since all it can reach is made-up data.
3. See what the script would send, then send it:

   ```
   $ python3 scripts/seed-sandbox.py --dry-run
   $ STRIPE_SEED_KEY=sk_test_... python3 scripts/seed-sandbox.py
   ```

   It asks once before sending. 66 requests: 12 customers, 12
   subscriptions, 6 invoices, 6 prices, 4 products, 3 coupons, a meter and
   a meter event. The one payment method it adds is Stripe's test card
   that is always refused (to make a payment that failed), so nothing is
   charged, and the customers' addresses end in `.example`.
4. The audit, with the key that can only read:

   ```
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp check examples/sandbox.ini
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp audit examples/sandbox.ini
   17 findings: 371.00 EUR a month and 1259.00 EUR once; 1 with an amount this audit can't know.
   ```

   `examples/sandbox.ini` sets every "how old" setting to 0, since nothing
   in a new sandbox is old, and `examples/sandbox-who.csv` finds the
   customers by address. The script prints the seventeen findings to
   expect: the stand-in's fifteen, and two drafts that Stripe leaves
   behind when a subscription is cancelled before its first invoice went
   out.

The script writes, so it has a key of its own, `STRIPE_SEED_KEY`, and
takes only a sandbox key (`sk_test_...` or `rk_test_...`): a live key is
refused before anything is sent. paymcp never sees that key. Run again on
a sandbox that has the business, the script adds only what a newer script
has and the sandbox lacks, and stops if nothing is missing; if it fails
midway, the sandbox holds half the business, and the way back is a new
sandbox. Delete
the sandbox when you are done (account picker, Switch to sandbox, Manage
sandboxes, Delete).

For the first minutes after seeding, two findings differ: Stripe has not
yet counted the meter event, so "Use that was never reported" says 0 was
reported, and Dogwood's invoice is not yet past due (Stripe takes no due
date in the past, so the script sets it two minutes ahead). A
subscription's first invoice is a draft for about an hour before Stripe
sends it; the audit gives a draft that Stripe will send itself a day
before calling it never sent, whatever `draft_days` says.

## What it looks for

From the billing account alone:

| Finding | The rule |
|---|---|
| A discount with no end | A live subscription has a discount older than `old_discount_days` (365) whose coupon lasts for ever. The amount is what it takes off a month. |
| Free, and has been for a while | A live subscription older than `free_days` (90), not in trial, pays nothing: everything off for ever, or every price zero. |
| A price no longer sold | A live subscription is on a price that is withdrawn (or isn't on your `current` list). The amount is the difference to the one price sold now for the same product and interval, when there is exactly one and it costs more. |
| Collection paused | Collection is paused with no date to resume, or the date has passed. |
| An invoice never sent | A draft invoice older than `draft_days` (7). A draft the provider will send itself is given at least a day. |
| An invoice never charged | An open invoice the provider should collect itself, older than `unsent_days` (3), with no payment ever tried. |
| Invoices written off | Invoices marked uncollectible, or voided after being sent, in the last `written_off_days` (365), summed for each customer. |
| Invoices past due | Open invoices sent to be paid by hand, more than `overdue_days` (7) past their due date, summed for each customer, with the oldest due date. |
| Payments that failed | Open invoices the provider tried to charge and couldn't, summed for each customer; each row says how often it was tried and whether another try is planned. |

With your own file of who has what (below), also:

| Finding | The rule |
|---|---|
| More seats than paid for | Your file says more seats than the subscription's quantity. Fewer is the customer's to notice, and isn't reported. |
| A higher plan than paid for | Your file says a plan whose price is another product's and costs more than the one billed. |
| Using the product, not paying | Active in your file; in billing, no live subscription. |
| Using the product, not in billing at all | Active in your file; no customer with that id or address. |
| Use that was never reported | Your file's use for the period exceeds what the meter was told by more than `usage_margin_percent` (1). |

Findings come largest first: amounts a month, then one-off amounts, then
those whose amount this audit can't know. The same thing has the same key
at every reading (`more_seats:sub_...:si_...`), so paymcp's record can
follow it from one reading to the next.

## The record

paymcp keeps one file of its own beside the pay file (`pay.ini` gives
`pay.record.jsonl`): a line for each reading, for each finding when it is
first found, for each finding a later reading no longer finds, and for
each decision a person makes. Lines are only ever added. It is the one
thing paymcp writes.

- **What is new.** From the second reading on, the report says how many
  findings are new, how many were found again after being gone, and how
  many are no longer found, with their sums; new ones are marked.
- **"It is meant to be so."** `paymcp decide PAY.ini KEY intended REASON`
  (or the `billing_decide` tool) dismisses a finding with your reason. It
  is then left out of the list and the sums, and the report says how many
  are left out. It comes back by itself if its amount grows by more than
  a tenth. `asked` marks a finding you are waiting on someone for; it
  stays listed, marked. `open` puts either back.
- **What is no longer found.** `paymcp record PAY.ini` (or
  `billing_record`) gives the whole record in a few lines: open now,
  asked, dismissed and why, and no longer found, each with its sums. "No
  longer found" is as far as the record goes: whether a finding was put
  right, or went because a setting or your own file changed, is yours to
  say. A reading that could not have seen a finding (a list cut at the
  page limit, your file not given, the meters not read) does not call it
  gone.
- A line in the file that paymcp didn't write stops the record from being
  used, and the report says so: the audit is still made, and the file is
  left as it is.
- `record = none` in the pay file keeps no record; `record = FILE` puts it
  elsewhere. `decide` and `record` need no key and send nothing.

## Tools

| Tool | What it does |
|---|---|
| `billing_audit` | What was read and what wasn't, the sums, what changed since the reading before, then the findings: the first 20, or `limit` (to 200), or one `kind`. `fresh` reads the account again; `all` lists what was dismissed too. Only reads the account. |
| `billing_finding` | One finding in full, by its `key`. Only reads. |
| `billing_decide` | A person's decision about one finding, by its `key`: `intended` (with the `reason`), `asked`, or `open`. Writes one line into paymcp's record, and nothing anywhere else. |
| `billing_record` | The record: readings since when, what is open, asked, dismissed and why, and no longer found, with the sums. Only reads. |

There is one resource, `pay://findings`: the reading as JSON, amounts in
the currency's smallest unit, each finding with how it stands in the
record, with a note that it is data and not instructions. A reading is kept
for five minutes, so asking for one finding after the list doesn't read the
whole account again. A field a tool doesn't take is refused, never ignored.
No tool changes anything at the billing provider.

## The key

The key is never in a file: paymcp takes it from `STRIPE_KEY` in the
environment. Make a **restricted key** in the Stripe dashboard (Developers,
API keys, Create restricted key) with **Read** on these and **None** on
everything else:

| Permission | For |
|---|---|
| Customers | names and addresses of the customers in findings |
| Subscriptions | plans, quantities, discounts, pauses |
| Prices | what each plan costs, which are withdrawn |
| Coupons | what a discount takes off |
| Invoices | drafts, open invoices, written-off invoices |
| Billing meters, Billing meter events | use reported, for "Use that was never reported" (optional) |

paymcp refuses to start with a live account's secret key (`sk_live_...`),
which can do everything, with a publishable key, and with a live key where
the pay file says `mode = sandbox` (or the reverse). A sandbox's secret key
(`sk_test_...`) is taken where the file says sandbox, with a note on
stderr: it is one of the two keys a new sandbox shows, and all it can
reach is made-up data. A permission the key lacks is said
in the report as something not read; the meters are the one part the audit
goes on without.

Every request paymcp sends is a GET with `Stripe-Version` pinned. With a
key that can only read, the provider itself refuses anything else.

## The pay file

```ini
[stripe]
; url = https://api.stripe.com    ; the default; http:// only on this computer (the stand-in)
mode = sandbox                    ; sandbox: the key begins rk_test_ (or sk_test_); live: rk_live_
; page = 100                      ; records a request, 1 to 100

[billing]
who = who.csv                     ; your own file (optional; relative to this file)
; old_discount_days = 365
; free_days = 90
; draft_days = 7
; unsent_days = 3
; overdue_days = 7                ; an invoice sent to be paid by hand, this long past due
; written_off_days = 365
; written_off_above = 0           ; leave out sums up to this, in the currency's smallest unit
; usage_margin_percent = 1
; record = pay.record.jsonl       ; paymcp's record (the default: beside this file, named after it); none: keep none
; current = team_monthly, pro_monthly   ; your price list now; without it, every active price

[plans]                           ; a plan's name in your file = the price it means
team = team_monthly               ; a price's id or lookup key
pro = pro_monthly
```

A setting the file doesn't have is refused with its line, a key in the
file among them.

## The business's own file

The billing provider knows what it bills, not what your customers have.
What they have is in your product's database. Export it as CSV with a
heading row and any of these columns:

```
customer,email,plan,seats,usage,active
cus_alder,,team,9,,yes
,ola@birch.example,pro,4,,yes
cus_fir,,team,5,15300,yes
```

- `customer` (the billing provider's id) or `email`: one of them finds the customer.
- `plan`: a name from `[plans]`.
- `seats`: seats in use now.
- `usage`: use in the current billing period, in the meter's units.
- `active`: `no` for an account closed in your product (the row is then left alone).

An empty cell means "not known", and nothing is concluded from it. A cell
that can't be read (seats that aren't a number) stops the audit with its
line, since a row half understood would give a wrong finding.

## What the agent can't do

- Change anything in your billing account: there is no tool for it, the key can't, and every request is a GET.
- See the key: it is in paymcp's environment, never in a tool's answer, the report or the record.
- Widen what is read by asking: the reading tools take only `kind`, `limit`, `fresh`, `all` and `key`.
- Write anything but a decision: `billing_decide` adds one line to paymcp's record, about a finding the record already has, and a dismissal needs a reason. It is the one tool not marked as only reading, so a gate can ask before each use. A decision is yours: the tool's description tells the agent to write down only what you have said.

Customers' names, addresses and invoice numbers are text other people
chose. paymcp puts each on one line (control characters taken out) and the
tools say they are data, not instructions; an agent with other tools
should still be given a gate that asks before it acts on a finding.

## With harness

In `mcp.ini`:

```ini
[pay]
command = /usr/local/bin/paymcp /path/to/pay.ini
; stored with `harness secret add stripe`
secret = STRIPE_KEY:stripe
```

harness asks before any MCP tool by default. Three of the four only read,
so these lines in `rules` let them run unasked, if you want that.
`billing_decide` is best left asked every time: it writes down a decision
that is yours.

```
allow mcp pay/billing_audit *
allow mcp pay/billing_finding *
allow mcp pay/billing_record *
```

**Every Monday, by itself.** A schedule in `triggers.ini` and the same
three lines for it in `rules` (a scheduled run has nobody to ask, so what
isn't allowed there is refused, a decision among it):

```ini
[billing-audit]
at = 09:00
days = mon
do = Run billing_audit with fresh set to true. Tell me what is new since the last reading and what is no longer found, each with its amount, then the three largest open findings with what is proposed. If nothing changed, say so in one line. Decide nothing yourself.
```

```
[schedule:billing-audit]
allow mcp pay/billing_audit *
allow mcp pay/billing_finding *
allow mcp pay/billing_record *
[all]
```

Tried on 2026-11-27 on Windows, with a real model and the Stripe test
account above: asked in conversation, harness asked once before the
audit and the answer had the three largest findings with their amounts
and proposals; run as the schedule, it reported with nobody asked.

In Claude Code: `claude mcp add --env STRIPE_KEY=... pay -- paymcp
/path/to/pay.ini`. That stores the key in Claude Code's settings.

## Building and testing

Zig 0.17.1.

```
zig build -Doptimize=ReleaseSafe      # zig-out/bin/paymcp, zig-out/bin/paymcp-sim
zig build unit                        # the unit tests
zig build test                        # the unit tests, then scripts/smoke.sh (needs python3 and sh)
```

The tests cover the rules one by one, reading lists in pages of two and of
a hundred, a provider that is busy (429) and one that refuses the key, a
key without the meters, the record (what is new, gone, found again,
dismissed and reopened; readings that could not have seen a finding; a
file that isn't paymcp's), and the whole audit, the decisions and the
record through the command line and over MCP against `paymcp-sim`.

## Limits

- **Run against Stripe on one day, on a made-up business a few hours old** (2026-11-27, a test account, the sandbox's secret key). The lists, the expanded discount, the meters' event summaries, an invoice past due and a payment the test card refused read as the documentation says. Not yet tried: a restricted key (so the names of its permissions in [The key](#the-key) are from the documentation only), a live account, an account with years of history or more than one page of anything, and what the "how old" rules say of things that really are old.
- Amounts are at list price. A customer with a discount and too few seats shows both findings, and the seats are counted at the full price, so the two sums overlap.
- A tiered or metered price has no single amount a month: such findings say "amount not known".
- A subscription with two meters is skipped for "Use that was never reported": which meter your file's number belongs to isn't known.
- A list is read to 200 pages (20,000 records at 100 a page); past that it is cut, and the report says so.
- Days are UTC.
- Not looked for yet: payments taken twice or refunded twice, disputes, taxes, trials that never convert, coupons past their redeem-by date.
- It proposes; it does not fix. Changing a subscription, sending an invoice or reminding a customer is done in the dashboard, or from your own mail, by a person.
- "No longer found" is not "put right": a finding also goes when a "how old" setting, your price list or your own file changes. The record keeps what it was worth; what happened to it is yours to say.
- The record is one file on one computer, written whole each time: two readings at the same moment from two programs can lose one's lines.

## License

MIT. See [LICENSE](LICENSE).
