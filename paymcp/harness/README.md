# paymcp with harness: the Money pack

What makes paymcp a job harness does for you: the server in `mcp.ini`, the
key in harness's key store, a page that lists the findings and takes your
decisions, a reading every Monday, and the rules that let those run
without a question while everything else is still asked.

```
harness/
  mcp.ini          the server: paymcp with your pay file, the key from the key store
  rules            what may run unasked: the weekly reading's reads, the page's reads and decisions
  triggers.ini     the weekly reading
  apps/money/      the Money page (a harness app)
  try-page.py      the page without harness, to look at it
```

## The Money page

One page in harness's Apps (and so in the desk): the open findings,
largest first, with the sums a month and once. A finding opens to the
rows it rests on, what is proposed, the draft of a message to the
customer where there is one, and your decision: **It is meant to be so**
(with your reason, which is kept), **I asked someone**, or **Open
again**. Below it, the record: what you asked about, what you dismissed
and why, and what a later reading no longer found.

- **Payments going out.** Where the pay file has a `[payrun]` section,
  the page has a box for the payment-run check: give a batch file's name
  (a file in the pay file's folder) and read what to look at before
  paying; or search past payments for ones made twice. The answer is the
  tool's own text. A decision about one of its findings is made in the
  chat or with `paymcp decide`.
- **The books, and the bills that grow.** Under "Other readings" are two
  buttons: the payment-run check from your accounting program (the pay
  file's `[ledger]`), and the bill watch (`[bills]`). Each reads only
  when you press it, and shows the tool's own text; where the section or
  the key is missing, the text says so.
- The page holds no key and reaches nothing but harness. Each thing it
  reads or writes is a call of one of paymcp's tools through harness's
  gate, as `app:money`, and is in harness's log.
- It changes nothing in the billing account: paymcp only reads it. A
  decision is one line in paymcp's own record beside your pay file.
- A draft is sent by nobody but you. The page shows it for you to copy
  into your own mail.

To see it before installing anything, against the stand-in's made-up
business (from `paymcp/`, after `zig build`):

```
$ python3 harness/try-page.py zig-out/bin/paymcp --sim zig-out/bin/paymcp-sim
The Money page: http://127.0.0.1:8744/  (no gate here: this is for looking at the page)
```

## Setting it up

1. **The pay file.** Copy `examples/sim.ini` or `examples/sandbox.ini`,
   and your own file of who has what, into a folder of yours; set them as
   the paymcp README says. Run `paymcp check PAY.ini` once by hand.
2. **The key**, into harness's key store, never into a file:
   `harness secret add stripe` (it asks for the key and doesn't show it).
3. **The server.** Add `mcp.ini`'s section to the `mcp.ini` in your data
   folder, with the paths to `paymcp` and your pay file. The section's
   name must stay `billing`: the page and the rules call the tools by it.
4. **The page.** Copy `apps/money` into your data folder's `apps/`, then
   approve it, which only you can do:
   `harness app approve money`. Harness serves an app only as you
   approved it; if its files change, it asks again.
5. **The rules.** Add `rules` here to yours. Without them everything still
   works, and each read is a question.
6. **The weekly reading.** Add `triggers.ini` here to yours.
7. `/reload` in the chat (or start harness). `/apps` gives the page's
   link; in the desk it is under Apps.

## What may run unasked, and what may not

- **The weekly reading** (`[schedule:billing-audit]`) may read: the
  audit, one finding, the record, a draft. It may not decide: a run
  nobody watches never writes a decision, because `billing_decide` is not
  in its rules.
- **The page** (`[app:money]`) may read, and may write your decision:
  the buttons are pressed by you. Take the `billing_decide` line out and
  each decision is asked once more in the bar above the page.
- **The agent in the chat** has no rule here: when you ask it about your
  billing, harness asks you before the first call, as for any MCP tool.
- **The daily readings** of the books and of the bills
  (`[schedule:books]`, `[schedule:bill-watch]`; their triggers are in
  `triggers.ini`, commented out) may read and nothing else.
- **Nothing here changes the billing account**, with or without rules.

## Changing things, asked every time

Off unless you turn it on in two places: `[changes] allow = yes` in the
pay file, and the second key in harness's key store (`harness secret add
stripe-write`), named on the section's `secret` line. `mcp.ini` here has
the lines, commented out.

paymcp then has two more tools: `billing_change` (the one thing a finding
says paymcp can do: end a discount, set a quantity, move to a price,
resume collection, finalise a draft invoice, have an invoice sent again)
and `dispute_stage` (keep a dispute's evidence draft at Stripe, not sent).
Declare them as money tools, as those lines do, and harness treats them
as it treats anything that moves money:

- **Asked every time**, with the call in front of you: the finding's key
  and its amount. There is no "Allow 24 h", and no rule lifts the
  question.
- **Never from a run nobody watches** unless you set a budget for
  routines, and never from the page: an app's acts call no money tool.
  You change things by asking in the chat ("end Alder's discount") and
  answering harness's question.
- **`max_per_call`** in `mcp.ini` is harness's own limit on one change's
  amount, beside the pay file's `max_amount`.

What a change does and doesn't do is in the paymcp README, "Changing
things": from the next invoice on, one request, read back, never a
payment taken, never evidence sent to a bank.

## Tried, and not

On Windows 11, with harness 0.4.0: the page inside a harness started for
the purpose, against the stand-in (the findings listed through the gate,
each call in the log as `app:money`), and the page on its own through
`try-page.py`, by hand: opening a finding, the draft, each decision, the
record, reading again. With the lines for changes in `mcp.ini`, harness
started the server and listed its eight tools. Not tried: the page in a
harness of the owner's with a real account behind it (approving an app is
the owner's to do), a change asked for in the chat and answered at the
gate (the changes themselves were made from the command line, against
Stripe's test mode), macOS and Linux by hand, a pay file with more than a
few dozen findings. What 0.5.0 adds to the pack (the two buttons under
"Other readings", their rules and triggers, the keys' line in `mcp.ini`)
was tried through `try-page.py` against the stand-in only, not inside a
harness.
