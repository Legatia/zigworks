# paymcp

What your customers should be paying and are not, what they owe you that
is late, and which card payments their banks are taking back, found in
your billing account by fixed rules, as tools for an AI agent over MCP on
stdio or as a report on the command line. It reads Stripe with a key that
can only read. It changes nothing there unless you turn that on, give it a
second key, and say so for each change.

```
agent ──MCP, stdio──▶ paymcp ──https, GET only──▶ Stripe
                        │      (one POST at a time with a second key,
                        │       only where the pay file allows it)
                        ├── your own file of who has what (optional, CSV)
                        └── its own record: what each reading found, what you decided
```

Every finding has an amount (or says plainly that the amount isn't known),
the rows it rests on, and what is proposed. A finding is a question for a
person, not a mistake found: a discount may be meant to last, an old price
may be a promise. So "it is meant to be so" is an answer paymcp keeps,
with your reason, and from the second reading on a report says what is
new and what is no longer found.

- **Drafts, never sent.** Where a change is the customer's to see, a
  finding has a draft of the message to them; a card dispute has a draft
  of the evidence, as far as the account shows it. You read, change and
  send them yourself.
- **Payments going out, too.** The payment-run check reads a batch of
  payments to suppliers before you pay it, from the file you export, and
  searches past payments for ones made twice
  ([The payment-run check](#the-payment-run-check)). It needs no key and
  no account: only files.
- **A page.** With [harness](../harness), the findings are one page: the
  list, each finding's rows and drafts, your decisions
  ([harness/](harness/README.md)).

Linux and Windows; it builds for macOS (where it links libc, as calmcp
does) but hasn't been run there. One binary, nothing beyond the Zig
standard library.

**State: 0.4.0, written from Stripe's public documentation for API version
`2026-11-18.endive`, tested against `paymcp-sim` (a stand-in built from the
same documentation) and run against Stripe itself,** on 2026-11-27, in a
test account holding only the made-up business below. There it found what
it was built to find, with the amounts expected; read three card disputes
made by Stripe's own test cards; and made each kind of change once, each
seen at Stripe afterwards ([Against a Stripe sandbox](#against-a-stripe-sandbox)).
It has never read a live account, and never an account with real history
in it. Run it on a sandbox first and read the report against the
dashboard before trusting a number. The payment-run check has read
made-up files only: no business's own export yet. See [Limits](#limits).

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
   A message to the customer is drafted: ask for the draft of this key.
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
   A message to the customer is drafted: ask for the draft of this key.
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

The reminder for Dogwood's invoice, as a draft:

```
$ ./zig-out/bin/paymcp draft examples/sim.ini overdue:cus_dogwood:eur
A draft, for you to read, change and send from your own mail. paymcp sent nothing and can send nothing.
About: Invoices past due: 340.00 EUR, once, Dogwood Labs  [overdue:cus_dogwood:eur]

To: finance@dogwood.example
Subject: Invoice FH-0405

Hello,

Invoice FH-0405 for 340.00 EUR was due on 2026-11-06 and is still open. Could you pay it, or tell us if something about it is not right?

Kind regards,
Ola at Fernhill
```

`paymcp audit examples/sim.ini --json` gives the audit as data, and
`--all` lists what was dismissed too. `paymcp examples/sim.ini` serves MCP
on stdin and stdout, the way an agent starts it. Started with
`--disputes`, the stand-in's business also has four card disputes
([Card disputes](#card-disputes)); with `--write-key KEY2` it takes
changes from a second key ([Changing things](#changing-things)).

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

   It asks once before sending. About 75 requests: 12 customers, 12
   subscriptions, 6 invoices, 6 prices, 4 products, 3 coupons, a meter and
   a meter event, and five test payments with Stripe's own test cards,
   three of which those cards dispute (the script closes one of the
   disputes unanswered). No real card is charged and no bank is asked;
   the customers' addresses end in `.example`.
4. The audit, with the key that can only read:

   ```
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp check examples/sandbox.ini
   $ STRIPE_KEY=rk_test_... ./zig-out/bin/paymcp audit examples/sandbox.ini
   21 findings: 371.00 EUR a month and 1486.00 EUR once; 1 with an amount this audit can't know.
   ```

   `examples/sandbox.ini` sets every "how old" setting to 0, since nothing
   in a new sandbox is old, and `examples/sandbox-who.csv` finds the
   customers by address. The script prints the twenty-one findings to
   expect: the stand-in's fifteen, the three from the disputes, and three
   that only Stripe makes: two drafts it leaves behind when a
   subscription is cancelled before its first invoice went out, and the
   invoice it voids for a subscription paused with "void".

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
before calling it never sent, whatever `draft_days` says. The voided
invoice of the paused subscription appears after that hour too.

The changes were tried in the same account on the same day, with
`[changes] allow = yes` added to the pay file and the sandbox's secret
key as the second key: a discount ended, a quantity set from 5 to 9, an
item moved to another price with its quantity kept, collection resumed,
a draft invoice finalised, an invoice sent again, and evidence kept for
one dispute and not sent. Each was read back from Stripe as done, and
the next audit no longer found the five that a change settles. The
finalised invoice then showed as "never charged": that customer has no
payment method on file, which is a true finding.

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

Card disputes (below) are read with the rest:

| Finding | The rule |
|---|---|
| A card dispute to answer | A dispute, an inquiry or an appeal that waits for an answer, with the last day to give one. |
| Disputes lost without an answer | Disputes of the last `[disputes] days` (180) that were lost with no evidence ever sent, as one sum. A count of what not answering cost, not money to collect. |

What has a last day comes first, the nearest day first. Then the rest,
largest first: amounts a month, then one-off amounts, then
those whose amount this audit can't know. The same thing has the same key
at every reading (`more_seats:sub_...:si_...`), so paymcp's record can
follow it from one reading to the next.

## Card disputes

When a cardholder's bank asks about a payment or takes it back, there are
days, not weeks, to answer, and an answer is taken once. paymcp reads the
disputes of the last months with the account (`GET /v1/disputes`, each
with its payment) and, for a customer with a dispute to answer, what that
customer paid before.

- **A dispute to answer is a finding** with its last day, what the
  cardholder says, the payment, and how many earlier payments from the
  same customer were never disputed or refunded: what a bank weighs most
  against "it wasn't me".
- **An inquiry** says so: the bank asks before taking anything back, and
  answering it, or refunding, can end it there.
- **The evidence draft** (`paymcp evidence PAY.ini KEY`, the tool
  `dispute_evidence`): what the bank wants to see for that reason, the
  fields of Stripe's evidence form that the account already fills (who
  paid, when, for what, the earlier payments), and what only you have
  and must add (logs of use, what was delivered, your exchange with the
  customer). It claims nothing the account doesn't show: it never says a
  thing was delivered or used.
- **A note to the customer**, as a draft: many disputes are a payment
  somebody didn't recognise on a statement.
- **Nothing is sent to a bank from here, ever.** Sending evidence is
  final. With changes on, `dispute_stage` keeps the draft's fields at
  Stripe as evidence not yet sent; you add the rest there and send it.

A key that may not read disputes: the report says so and audits the rest.
`[disputes] read = no` asks for none.

## The payment-run check

For the money going out. Before a batch of payments to suppliers is
paid, export it as a file and let paymcp read it. In most countries the
business that pays carries the loss when a payment goes to the wrong
account, and a bank's own name check often skips payments sent as a
batch.

```
$ paymcp payrun examples/payrun.ini history examples/payrun/payments-2025.csv
Read examples/payrun/payments-2025.csv: 7 payments, 4191.00 EUR. 7 added to paymcp's list of past payments (examples/payrun.payments.jsonl); 0 were in it already.
Past payments searched on 2026-11-27: 7 payments in paymcp's list. Nothing was changed, and no bank or supplier was asked.

1 payment made twice, by the look of it: 149.00 EUR. Each is a question: two bills of the same amount are common.

1. Paid twice: 149.00 EUR, once
   Bill KH-5521 of Kestrel Hosting for 149.00 EUR was paid on 2025-09-10 and again on 2025-09-24.
   ...
$ paymcp payrun examples/payrun.ini check examples/payrun/run-2025-11-17.csv
Payment run run-2025-11-17.csv, checked 2026-11-27. Nothing was paid and nothing was changed: paymcp read these files, and asked no bank.
Read: 5 payments, 3681.40 EUR; 3 suppliers in your suppliers file; 7 past payments in paymcp's list, the first of 2025-08-04.

5 things to look at before paying. Each is a question, not a mistake found.

1. Bank details changed: 1230.00 EUR, once
   Nordlys Print is to be paid 1230.00 EUR to account 44114020040000310276543210; the last payment to them went to 61109010140000071219812874.
   - run-2025-11-17.csv, line 2: Nordlys Print, bill NP/2025/140, 1230.00 EUR, to account 44114020040000310276543210
   - paymcp's list of past payments: last paid on 2025-10-02 to account 61109010140000071219812874; 3 payments went to that account
   - your suppliers file, line 2: account 61109010140000071219812874, phone +48 22 555 01 01
   Proposed: Before paying, call the supplier on a number you had before this change (your suppliers file has +48 22 555 01 01), never one from the message that announced the new account, and ask whether the account is theirs. ...
   [account_changed:run-2025-11-17.csv:5260001246]
   ...
$ paymcp payrun examples/payrun.ini paid examples/payrun/run-2025-11-17.csv
Written down: 5 payments of run-2025-11-17.csv, 3681.40 EUR, as paid. The next check knows them. (paymcp paid nothing: it only keeps the list.)
```

| Finding | The rule |
|---|---|
| Bank details changed | The account differs from the one this supplier was last paid to (or, with no past payment, from your suppliers file). Comes first. |
| A supplier never paid before | No past payment to this supplier, once there are past payments at all. |
| A likely duplicate | The same supplier with the same bill number as a past payment or another row; or the same amount within `duplicate_days` (45) with no bill number to tell them apart, or one a slip of the hand away. Bills numbered in a row for the same monthly amount are two bills. |
| An amount out of line | More than `out_of_line` (3) times the largest ever paid to that supplier, with three payments or more to judge by. |
| Two suppliers, one account | The account is another supplier's, in your suppliers file or in past payments. |
| Paid twice (the look-back) | Over past payments: the same supplier and amount with the same bill number, or one a slip away. With a draft of the request to the supplier (`payrun ... draft KEY`). |

- **The files.** CSV with a heading row, cells apart by `,` or `;`.
  Columns are found by their headings (`supplier`/`vendor`/`name`,
  `tax_id`/`vat`/`nip`, `bill`/`invoice`/`reference`, `amount`/`total`,
  `currency`, `date`, `account`/`iban`, and in the suppliers file `phone`
  and `email`). A supplier is matched by tax number where the file has
  one, else by name. Amounts as people write them (`1 234,56`,
  `1,234.56`); a day is `2026-11-27` or `27.11.2026`. A heading that fits
  two columns, an amount or a date that can't be read for sure: the check
  stops with the line, since a file half understood would be a wrong
  check.
- **What was checked is what is paid.** A check keeps a fingerprint
  (SHA-256) of each row. `payrun ... paid` writes the batch into paymcp's
  list of past payments only if the file is still what was checked; a row
  added or altered in between is listed and nothing is written down.
- **Your answers are kept.** `paymcp decide PAY.ini KEY intended "called
  Anna on the old number, the account is theirs"` writes it into the
  record, and the next check of that batch leaves the finding out.
- **Tools:** `payrun_check` (a batch file in the pay file's folder; a
  path that leads elsewhere isn't read) and `payrun_lookback`. A pay file
  with a `[payrun]` section and no key serves these and `billing_decide`
  only.
- **What it can't do,** and says: read the account printed on a bill,
  tell who owns an account, ask a bank, or stop a payment. It is a check
  before paying; the person can still pay what it flagged.

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
| `billing_draft` | The draft of a message to the customer about one finding: to whom, the subject, the text. Nothing is sent. Only reads. |
| `dispute_evidence` | For one dispute to answer: what the bank wants, what the account already shows, what only you have. Nothing is sent. Only reads. |
| `payrun_check`, `payrun_lookback` | **With a `[payrun]` section.** A batch of payments to suppliers checked before it is paid; past payments searched for ones made twice. They read files on this computer only. |
| `billing_change` | **Only with changes on.** Does the one thing paymcp can do about a finding ([Changing things](#changing-things)). |
| `dispute_stage` | **Only with changes on.** Keeps a dispute's evidence draft at the provider, not sent. |

`billing_audit`, `billing_finding` and `billing_record` take `format`
`json` for a page that lists the findings: the audit 20 findings at a
time from `offset`, without their rows, so that an answer passes whole
through an agent runtime's limit on a tool's answer.

There is one resource, `pay://findings`: the reading as JSON, amounts in
the currency's smallest unit, each finding with how it stands in the
record, with a note that it is data and not instructions. A reading is kept
for five minutes, so asking for one finding after the list doesn't read the
whole account again. A field a tool doesn't take is refused, never ignored.
Unless the pay file turns changes on and a second key is given, no tool
changes anything at the billing provider, and the two that can are not
listed.

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
| Disputes | card disputes to answer, and those lost unanswered (optional) |
| Charges | what a customer with a dispute paid before (optional) |

paymcp refuses to start with a live account's secret key (`sk_live_...`),
which can do everything, with a publishable key, and with a live key where
the pay file says `mode = sandbox` (or the reverse). A sandbox's secret key
(`sk_test_...`) is taken where the file says sandbox, with a note on
stderr: it is one of the two keys a new sandbox shows, and all it can
reach is made-up data. A permission the key lacks is said
in the report as something not read; the meters, the disputes and a
disputing customer's earlier payments are the parts the audit goes on
without.

Every request paymcp sends with this key is a GET with `Stripe-Version`
pinned. With a key that can only read, the provider itself refuses
anything else.

## Changing things

Off unless you turn it on. With `[changes] allow = yes` in the pay file
and a second key in `STRIPE_WRITE_KEY`, paymcp has two more tools, and
`paymcp change` and `paymcp stage` on the command line. The second key is
a restricted key with **Write** on Subscriptions, Invoices and Disputes
and nothing else; a live account's secret key is refused, and the reading
key is never used to change anything.

`billing_change` does the one thing the audit says paymcp can do about a
finding (the finding then has a line "paymcp can do this, when a person
says so"):

| Finding | What is done |
|---|---|
| A discount with no end; free through a discount | the discount is taken off the subscription |
| More seats than paid for | the item's quantity is set to the seats in your file |
| A higher plan than paid for; a price no longer sold | the item is moved to the other price, its quantity kept |
| Collection paused | collection is resumed |
| An invoice never sent | the draft is finalised: sent to the customer to pay, or charged by Stripe to the payment method on file |
| Invoices past due (up to five) | Stripe sends each invoice to the customer again |

- **From now on only.** Every change of a subscription is sent with
  `proration_behavior=none`: the next invoice is different, and nothing is
  charged for time already invoiced. paymcp takes no payment, refunds
  nothing, deletes nothing, and sends no evidence to a bank.
- **What you were shown is what is done.** The call names the finding's
  amount again, and a different amount stops it. `max_amount` is the most
  one change may be worth.
- **It looks first and afterwards.** The record at Stripe is read before
  the change, and the change stops if it is no longer as the finding said.
  Then one POST, with an idempotency key so that a request sent twice is
  made once. Then it is read back, and the answer says what Stripe now
  shows. A line goes into paymcp's record.
- **Nothing about a customer's money is decided by an agent.** The tools'
  descriptions say to act only on what a person has said for that one
  finding; in harness, declare them as money tools ([harness/](harness/README.md))
  and the gate asks every time, whatever the rules say.

```
$ paymcp change pay.ini paused:sub_gorse           # the finding, what would be done; nothing is changed
$ STRIPE_WRITE_KEY=rk_test_... paymcp change pay.ini paused:sub_gorse --yes
Done: collection on subscription sub_gorse is no longer paused. Its next invoice is collected again; invoices made while it was paused stay as they are.
```

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

[disputes]
; read = yes                      ; card disputes: those to answer, and those lost unanswered
; days = 180                      ; how far back

[letters]
from = Ola at Fernhill            ; who a drafted message to a customer is from

[changes]
; allow = no                      ; yes: one thing at a time may be changed, with STRIPE_WRITE_KEY
; max_amount = 0                  ; the most one change may be worth (smallest unit); 0: no limit here

[payrun]                          ; the payment-run check: files only, no key
suppliers = suppliers.csv         ; your suppliers: name, tax number, account, phone, mail (optional)
; history = pay.payments.jsonl    ; paymcp's list of past payments (the default: beside this file)
; duplicate_days = 45
; out_of_line = 3
; currency = eur                  ; of a file with no currency column
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

- Change anything in your billing account, unless you turned changes on: without `[changes] allow = yes` and a second key there is no tool for it, the reading key can't, and every request is a GET.
- With changes on: do anything but the one thing a finding names, for the amount you were shown. There is no tool that takes a payment, refunds, deletes, cancels, or sends evidence to a bank, and none that takes a customer or an amount of the agent's choosing.
- Send a message: drafts are text. paymcp has no way to send mail.
- See a key: both are in paymcp's environment, never in a tool's answer, the report or the record.
- Widen what is read by asking: the reading tools take only `kind`, `limit`, `fresh`, `all`, `format`, `offset` and `key`.
- Write anything but a decision: `billing_decide` adds one line to paymcp's record, about a finding the record already has, and a dismissal needs a reason. It is the one tool not marked as only reading, so a gate can ask before each use. A decision is yours: the tool's description tells the agent to write down only what you have said.

Customers' names, addresses and invoice numbers are text other people
chose. paymcp puts each on one line (control characters taken out) and the
tools say they are data, not instructions; an agent with other tools
should still be given a gate that asks before it acts on a finding.

## With harness

[harness/](harness/README.md) has what makes this a job harness does for
you: the server's section for `mcp.ini` (the key from harness's key
store), the Money page, a reading every Monday, and the rules that let
those read without a question while a decision, and any change, is still
yours.

Tried on 2026-11-27 on Windows, with a real model and the Stripe test
account above: asked in conversation, harness asked once before the
audit and the answer had the three largest findings with their amounts
and proposals; run as the schedule, it reported with nobody asked. The
Money page was seen working inside a harness started for the purpose,
against the stand-in.

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
file that isn't paymcp's), the drafts, the disputes and their evidence,
each change (made once, stopped when the record is no longer as found,
refused without the second key, and never anything sent to a bank), the
Money page's files and calls, and the whole audit, the decisions and the
record through the command line and over MCP against `paymcp-sim`.

## Limits

- **Run against Stripe on one day, on a made-up business a few hours old** (2026-11-27, a test account, the sandbox's secret key as both keys). The lists, the expanded discount, the meters' event summaries, an invoice past due, a payment the test card refused, three disputes from Stripe's test cards and each kind of change read and wrote as the documentation says. Not yet tried: a restricted key for reading or for changing (so the names of the permissions in [The key](#the-key) and [Changing things](#changing-things) are from the documentation only), a live account, an account with years of history or more than one page of anything, a real dispute from a real bank, and what the "how old" rules say of things that really are old.
- Drafts are in English, and written by fixed rules: they say what the audit found and nothing warmer. Read them as a start.
- The evidence draft has text only. Files (a log, a screenshot, a contract) are yours to add at the provider, and so is every sentence about delivery or use.
- A change is from the next invoice on. Charging for the past, taking a failed payment again, refunding and cancelling are not done from here.
- Amounts are at list price. A customer with a discount and too few seats shows both findings, and the seats are counted at the full price, so the two sums overlap.
- A tiered or metered price has no single amount a month: such findings say "amount not known".
- A subscription with two meters is skipped for "Use that was never reported": which meter your file's number belongs to isn't known.
- A list is read to 200 pages (20,000 records at 100 a page); past that it is cut, and the report says so.
- Days are UTC.
- Not looked for yet: payments taken twice or refunded twice, early fraud warnings, taxes, trials that never convert, coupons past their redeem-by date.
- Without changes turned on it proposes and does not fix: changing a subscription, sending an invoice or reminding a customer is done in the dashboard, or from your own mail, by a person.
- The payment-run check has read made-up files only. Real exports name their columns in many ways and languages: where a heading isn't one it knows, rename it; nothing is guessed. It matches a supplier by tax number or by name as written, so one supplier under two spellings is two. It knows only the payments it was given.
- "No longer found" is not "put right": a finding also goes when a "how old" setting, your price list or your own file changes. The record keeps what it was worth; what happened to it is yours to say.
- The record is one file on one computer, written whole each time: two readings at the same moment from two programs can lose one's lines.

## License

MIT. See [LICENSE](LICENSE).
