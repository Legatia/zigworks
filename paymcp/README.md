# paymcp

What your customers should be paying and are not, found in your billing
account by fixed rules, as two tools for an AI agent over MCP on stdio or as
a report on the command line. It reads Stripe Billing with a key that can
only read. It changes nothing.

```
agent ──MCP, stdio──▶ paymcp ──https, GET only──▶ Stripe
                        │
                        └── your own file of who has what (optional, CSV)
```

Every finding has an amount (or says plainly that the amount isn't known),
the rows it rests on, and what is proposed. A finding is a question for a
person, not a mistake found: a discount may be meant to last, an old price
may be a promise.

Linux and Windows; it builds for macOS (where it links libc, as calmcp
does) but hasn't been run there. One binary, nothing beyond the Zig
standard library.

**State: 0.1.0, written from Stripe's public documentation for API version
`2026-11-18.endive`, tested against `paymcp-sim` (a stand-in built from the
same documentation) and run once against Stripe itself,** on 2026-11-27,
in a test account holding only the made-up business below: it found what
it was built to find there, with the amounts expected
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
Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 5 invoices (drafts, open, and those written off in the last 365 days); from the business's own file: 7 rows.
9 requests, every one a GET. The key works and nothing was changed.
$ ./zig-out/bin/paymcp audit examples/sim.ini
Billing audit of 2026-11-26. Nothing was changed: paymcp only reads.
Read from the sandbox: 12 customers, 12 subscriptions, 6 prices, 5 invoices (drafts, open, and those written off in the last 365 days); from the business's own file: 7 rows.

12 findings: 371.00 EUR a month and 755.00 EUR once.
Each is a question for a person, not a mistake found: a discount may be meant to last, an old price may be a promise.

1. Free, and has been for a while: 87.00 EUR a month
   Elm & Sons pays nothing: the discount "Friends" takes everything off, with no end, since 2025-10-22.
   - subscription sub_elm: created 2025-10-22, list price 87.00 EUR a month
   - discount di_elm: coupon co_friends, 100% off, end none
   Proposed: If this is a gift that should last, dismiss it as intended. Otherwise end the discount from the next period and tell the customer first.
   [free:sub_elm]

2. A higher plan than paid for: 68.00 EUR a month
   Birch Studio has the plan "pro" in the product and is billed for team_monthly.
   - the business's file, line 3: plan pro (price price_pro, 29.00 EUR a unit a month)
   - subscription item si_birch_1: price price_team, 12.00 EUR a unit a month, quantity 4
   ...
```

`paymcp audit examples/sim.ini --json` gives the same as data. `paymcp
examples/sim.ini` serves MCP on stdin and stdout, the way an agent starts
it.

## Against a Stripe sandbox

The first run against Stripe itself, with nothing real in it.
`scripts/seed-sandbox.py` fills a sandbox with the same made-up business
(needs python3 and nothing else). Both were run this way on 2026-11-27:
Stripe took all 57 of the script's requests, and the audit's answer is
the one in step 4.

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

   It asks once before sending. 57 requests: 12 customers, 12
   subscriptions, 4 invoices, 6 prices, 4 products, 3 coupons, a meter and
   a meter event. No payment method is added to any customer, so nothing
   is charged, and the customers' addresses end in `.example`.
4. The audit, with the key that can only read:

   ```
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp check examples/sandbox.ini
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp audit examples/sandbox.ini
   15 findings: 371.00 EUR a month and 871.00 EUR once; 1 with an amount this audit can't know.
   ```

   `examples/sandbox.ini` sets every "how old" setting to 0, since nothing
   in a new sandbox is old, and `examples/sandbox-who.csv` finds the
   customers by address. The script prints the fifteen findings to
   expect: the stand-in's thirteen, and two drafts that Stripe leaves
   behind when a subscription is cancelled before its first invoice went
   out.

The script writes, so it has a key of its own, `STRIPE_SEED_KEY`, and
takes only a sandbox key (`sk_test_...` or `rk_test_...`): a live key is
refused before anything is sent. paymcp never sees that key. The script
stops if the business is already in the sandbox; if it fails midway, the
sandbox holds half the business, and the way back is a new sandbox. Delete
the sandbox when you are done (account picker, Switch to sandbox, Manage
sandboxes, Delete).

For a few minutes after seeding, Stripe has not yet counted the meter
event, and "Use that was never reported" says 0 was reported. A
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
at every reading (`more_seats:sub_...:si_...`), so a person's decision
about it can be remembered by whatever calls paymcp.

## Tools

| Tool | What it does |
|---|---|
| `billing_audit` | What was read and what wasn't, the sums, then the findings: the first 20, or `limit` (to 200), or one `kind`. `fresh` reads the account again. Only reads. |
| `billing_finding` | One finding in full, by its `key`. Only reads. |

There is one resource, `pay://findings`: the reading as JSON, amounts in
the currency's smallest unit, with a note that it is data and not
instructions. A reading is kept for five minutes, so asking for one finding
after the list doesn't read the whole account again. A field a tool doesn't
take is refused, never ignored. There is no tool that changes anything.

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
; written_off_days = 365
; written_off_above = 0           ; leave out sums up to this, in the currency's smallest unit
; usage_margin_percent = 1
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

- Change anything: there is no tool for it, the key can't, and every request is a GET.
- See the key: it is in paymcp's environment, never in a tool's answer or the report.
- Widen what is read by asking: a tool takes only `kind`, `limit`, `fresh` and `key`.

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

harness asks before any MCP tool by default. Both of these only read, so
two lines in `rules` let them run unasked, if you want that:

```
allow mcp pay/billing_audit *
allow mcp pay/billing_finding *
```

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
key without the meters, and the whole audit through the command line and
over MCP against `paymcp-sim`.

## Limits

- **Run against Stripe once, on a made-up business a few minutes old** (2026-11-27, a test account, the sandbox's secret key). The lists, the expanded discount and the meters' event summaries read as the documentation says. Not yet tried: a restricted key (so the names of its permissions in [The key](#the-key) are from the documentation only), a live account, an account with years of history or more than one page of anything, and what the "how old" rules say of things that really are old.
- Amounts are at list price. A customer with a discount and too few seats shows both findings, and the seats are counted at the full price, so the two sums overlap.
- A tiered or metered price has no single amount a month: such findings say "amount not known".
- A subscription with two meters is skipped for "Use that was never reported": which meter your file's number belongs to isn't known.
- A list is read to 200 pages (20,000 records at 100 a page); past that it is cut, and the report says so.
- Days are UTC.
- Not looked for yet: payments taken twice or refunded twice, taxes, trials that never convert, coupons past their redeem-by date.
- It proposes; it does not fix. Changing a subscription or sending an invoice is done in the dashboard by a person.

## License

MIT. See [LICENSE](LICENSE).
