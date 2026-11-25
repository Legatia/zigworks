# harness for a business's money: four jobs on one runtime

For the owner, from the Windows session, 2026-11-26. After three rounds of
research on what today's tools get wrong, the owner asked for "something
universal", asked of the answer "Does it help user earn more money?", and
concluded: "So it's not just for fintech, rather a general b2b money tool.
Good to have. Spec them".

No code. Every decision here is my call and is listed at the end for the
owner to overrule. Facts about the outside world are from searches on
2026-11-25 and 26, with sources at the end; much of it came through
search summaries, vendors' pages and secondary reports, and is marked
where it matters. No buyer was asked. The three research reports are kept
out of this public repository.

This file sits beside `2026-11-25-harness-fintech-design.md` and does not
replace it. That file's disputes pack, its parts on cases, people,
documents and measuring, and its rules are used here by name. Its
onboarding pack is for regulated companies and stays there.

## Intent

A business runs harness on a computer of its own, and harness watches the
places where its money comes in and goes out. It finds the money that is
owed and not billed, the sales being taken back, the payments about to go
wrong, and the bills that grew. It shows a named person each finding with
its evidence and its amount, and nothing changes until that person says
so.

Four jobs, in the order the owner's rule gives them (earning before
keeping, keeping before saving):

| Job | Pack | What it does for the business | Kind |
|---|---|---|---|
| Billing audit | `billing` | finds what customers should be paying and are not | earns |
| Disputes | `disputes` | wins back sales that card disputes took | earns |
| Payment-run check | `payrun` | stops a wrong payment before it leaves; finds past duplicates | keeps |
| Bill watch | `bills` | says when cloud and AI-model bills move, and what to do | saves |

"Earns, keeps, saves" is a judgment, and two are near the line: a
duplicate payment claimed back is money in the bank, and a billing error
corrected is revenue the business already earned.

## Who it is for

- **A business of five to two hundred people** that bills customers and
  pays suppliers, in any country and any trade.
- **One person uses it:** the founder, the finance lead or the
  bookkeeper. harness has one owner today, and for these jobs that is
  enough to start; a second person is needed only where a company wants
  two signatures on a payment (the fintech file's Part B).
- **They install the desk app.** No server. Whether a bookkeeper will
  install an agent and bring a model key is not known, and is one of the
  things the first trials are for.

## What makes it one product

The research found the same failure in every market it looked at: tools
automate what is easy to reach and act on it with confidence. And it found
where harness's own parts are worth most: where an ordinary business
process has no pause.

- **Every finding has an amount and its evidence,** row by row. What could
  not be read is shown as missing.
- **A named person decides each one,** and the decision keeps what they
  were shown.
- **The rules are code.** Sums, dates, matching and limits are worked out
  by fixed code in the sandbox. The model's part is small and named in
  each pack: reading a column heading, matching two names that differ by a
  letter, explaining a finding in a sentence, drafting a message.
- **Read-only first.** Each pack starts with keys or files that can only
  be read. A pack changes something only later, through a tool the gate
  asks about every time, with a cap.
- **The keys and the data stay in the business.** Keys are in the system's
  key store and never shown to the model.
- **It counts its own results,** against what would have happened anyway
  where that can be told.

## Goals

- A first result in money within a month of installing, for the two packs
  that earn.
- Nothing to connect for a first look where a file export will do.
- The same pack in any country. What a country adds (a register, an
  e-invoice system, a bank's name check) is an optional input, never a
  requirement.
- Few questions. A person who is asked forty things a day stops reading
  them; a pack shows only what crosses a threshold the owner set, largest
  amount first.

## Non-goals

- Bookkeeping, invoicing, payroll, tax returns. The business has software
  for those; harness reads it.
- Moving money. No pack pays, refunds or charges in its first version.
- Retrying failed card payments, chasing overdue invoices at volume,
  negotiating contracts. (Overdue is in the fintech file, last.)
- Reading scanned documents. Until harness reads PDFs, a pack works from
  data and says what it could not see.
- A hosted service.

## Anti-goals

- **No charge to a customer without a person's decision on that customer,**
  and never for the past by default (see the billing pack).
- **No message to a business's customer or supplier written and sent by
  the model alone.**
- **No finding without its rows.** A total with nothing behind it is not
  shown.
- **No share of what is found.** How the product is paid for is not in
  this public file, but the packs are built so that it need not depend on
  counting wins.

## What harness has for this, and what it lacks

| Need | Today | Lacks |
|---|---|---|
| A person approves | the gate, the inbox, workflows that wait | a record of what the person was shown (the fintech file, Part B) |
| Keys the model never sees | the key store, MCP with bearer keys or OAuth, masking | connectors for billing, accounting and cloud bills |
| Fixed rules on data | commands in a sandbox with no network | a place for a pack's code and its history; file importers |
| Watching for change | triggers that poll, schedules | nothing for these jobs: polling is enough |
| One user, no server | the desk app on Windows, macOS and Linux | a page for findings (the desk shows conversations and items) |
| A count of results | the log | findings with amounts, outcomes, a report |
| Proof | tests against stand-ins | any run against a real model or provider |

## The parts all four packs use

### Findings

A finding is one thing with an amount: an unbilled seat, a dispute, a
payment that looks wrong, a bill that jumped. It is the fintech file's
"case" made lighter.

- **Where:** `findings/PACK/ID/`: `finding.ini` (what, whose, the amount
  and its currency, per month or once, the state), `rows.jsonl` (the
  evidence: each row with its source, the time read and a SHA-256),
  `decision.ini`.
- **States:** new, needs a person, fixed, dismissed (with the reason),
  asked (waiting for someone else), gone (the next reading no longer
  shows it). Set by code.
- **The same finding is one finding.** Each has a key made from what it is
  about, so a second reading updates it and never asks twice. A dismissed
  finding stays dismissed until its amount changes by more than the pack's
  margin.
- **Thresholds:** `[findings] ask_above` per pack, in the business's
  currency. Below it a finding is listed and not asked about.

### The findings page

One page in the desk: the open findings of every pack, largest first,
with the month's totals at the top (found, fixed, dismissed). A finding
opens to its rows, the proposed action and its buttons. It is the fintech
file's staff page for one person.

### Readers

- **Files.** A pack can start from an export: CSV, or XML where a
  standard exists (SEPA's payment file). The first time, the model
  proposes which column is which from the headings and three rows; the
  person confirms; the mapping is kept and code reads every later file by
  it. A file that no longer fits the mapping stops with a line, and is
  not guessed at.
- **Connectors.** MCP servers in Zig, as `mailmcp` and `calmcp` are, each
  with a simulated backend and read tools only at first:
  - `paymcp` (the fintech file's, for Stripe): gains the billing reads
    below.
  - `ledgermcp` (the fintech file's, for Xero then QuickBooks): suppliers,
    bills, payments.
  - `cloudmcp`: cost and usage from Anthropic, OpenAI and AWS.
- **A key that can do more than read is refused** where the provider lets
  the connector tell (Stripe's restricted keys say what they may do).

### Counting

- `findings/outcomes.jsonl`: one line when a finding closes, with its
  amount, what was done, and whether the person changed the proposal.
- `harness report PACK --month`: found, fixed, dismissed, and what fixed
  findings are worth per month from now on.
- **Each pack says what it compares with** (below). Where nothing can be
  compared, the report says the figure is a count and not a gain.

## The billing audit (`billing`)

For a business that bills customers by subscription or by use. Stripe
first, because its keys can be made read-only per kind of record and it
is the same in every country it serves.

### What it reads

- From the billing provider: customers, subscriptions and their items,
  prices, discounts, invoices and their lines, credit notes, usage
  reported.
- From the business, optionally, one file: **who has what.** One row per
  account: the customer's id or email, the plan it is on in the product,
  its seats, its use this period. This is what the provider cannot know,
  and most of the money is in the difference.

### What it looks for

Each is a rule in code, with the rows that show it.

| Finding | Rule | Needs the business's file |
|---|---|---|
| A discount that should have ended | a discount with no end on a price that has one in the business's price list, or older than the owner's limit | no |
| Free for ever | a subscription at 100% off, or at a price of zero, older than the limit | no |
| An invoice never sent | a draft older than a week; an invoice finalised and never attempted | no |
| Written off quietly | invoices marked uncollectible or voided, by customer, above a sum | no |
| A plan nobody is sold any more | subscriptions on a price the list has replaced, with the difference per month | no |
| Paused and forgotten | collection paused past its date | no |
| More seats than paid for | seats in the product above the subscription's quantity | yes |
| A higher plan than paid for | the product's plan above the billed one | yes |
| Use that was never reported | use in the product above what the provider was told | yes |
| Still in, not paying | an account active in the product whose subscription is cancelled, unpaid or missing | yes |
| Paid twice, or refunded twice | two payments or refunds of one invoice | no |

- **Not every finding is an error.** A founder gave a friend the product
  for nothing; an old customer keeps an old price on purpose. That is why
  each is a question, and why "dismissed, intended" with its reason is an
  ordinary outcome that the pack remembers.
- **The owner's price list and limits are a small file** (`billing.ini`):
  which prices are current, which discounts are meant to end and after
  how long, what counts as old.

### What it proposes

- **From now on, by default.** Correct the quantity, end the discount,
  move the plan, send the invoice: from the next period. Charging a
  customer for months already past is offered only when the owner asks,
  finding by finding, with the customer's history beside it; a surprise
  bill costs more customers than it earns.
- **A message to the customer first, where the change is theirs to see.**
  harness drafts it; the person sends it from their own mail.
- **First version: nothing is changed by harness.** The proposal says
  exactly what to change and where in the provider's own pages. Later,
  with a second key the owner makes for it, `paymcp` gets tools that
  change one subscription at a time, asked every time.

### What it counts

- Per month: what the fixes made are worth each month from now, and
  one-off invoices sent and paid.
- **Against what:** the same subscriptions the month before the fix. This
  is the one pack where the comparison is exact, because the provider's
  own records show the price before and after.

### What is not known

- **How much there is to find.** The figure everyone quotes (one to five
  percent of revenue) has no source that could be found; the only survey
  with a method is from 2016. The first audit of a real account is the
  test.
- **Whether small subscription businesses have the second file.** Without
  it the pack finds discounts, drafts and old prices, not seats and use.

## Disputes (`disputes`)

As in the fintech file ("The three packs", Disputes), revised there on
2026-11-25. Here it is one of four, for any business that takes cards.

- It shares `paymcp` and the same key store, the findings page (a dispute
  is a finding with a deadline) and the counting.
- What it needs that the others do not: PDFs written, and for most
  evidence, PDFs read.
- It comes second because the billing audit needs less: no documents and
  no deadline.

## The payment-run check (`payrun`)

For any business that pays suppliers. In nearly every country looked at,
the business that pays carries the loss when the money goes to the wrong
account, and the banks' own name checks mostly skip payments sent as a
batch.

### What it reads

- **First version, two files the person exports before paying:** the
  suppliers (name, tax number where there is one, bank account), and the
  bills or the batch about to be paid (supplier, bill number, amount,
  date, account).
- **Its own history,** kept in the data folder: what each supplier was
  paid, when, and to which account.
- **Later:** `ledgermcp`, so nothing is exported and a change to a
  supplier's bank details is seen the day it is made, not at the next
  run.

### What it looks for

| Finding | Rule |
|---|---|
| Bank details changed | the account differs from the one this supplier was last paid to |
| A supplier never paid before | no payment in the history |
| A likely duplicate | the same supplier with the same number, or the same amount within the owner's days, or a number that differs by a character (the model's part, then a person's) |
| An amount out of line | far from what this supplier has been paid, by the owner's margin |
| The file is not what was approved | the batch at the bank's door differs from the one checked: a row added, an account or amount altered (by SHA-256 of each row) |
| Two suppliers, one account | an account that belongs to another supplier or to an employee |

- **For changed bank details the question is specific:** it shows the
  account before and after, when the change was made and by whom if the
  file says, and the phone number held before the change, and asks whether
  the supplier was called on that number. The answer is kept.
- **It cannot** read the account printed on a PDF invoice, tell who owns
  an account, or stop a payment at the bank. It says so on its first run.
  Until harness writes the payment file itself, its check is advice: the
  person can still pay what it flagged.

### The look-back

On its first day the same rules run over the last one to two years of
payments. Duplicates and overpayments found there can be claimed back
from the supplier; harness drafts the request and the person sends it.
This is the only way this pack shows money in its first month, and it
measures something nobody has published: how often a small business pays
twice.

### What a country adds

Optional inputs, each a reader of its own, none required:

- **Poland:** the state e-invoice system (KSeF) gives the invoice as
  data, account included, so the invoice can be compared with the
  supplier's record; the tax office's list of accounts answers whether an
  account is registered to the supplier. (The earlier report's "nearest
  build" is this pack with these two readers.)
- **Countries with structured e-invoices** (Belgium and France from 2026,
  Germany's issuers from 2027): the same comparison, one reader each.
- **A bank's name check,** where a bank gives its result for a batch.

### What it counts

- Runs checked, payments and value covered; findings by kind; findings
  the person confirmed as real; value stopped; from the look-back, what
  was found and what came back.
- **Against what:** nothing, for a fraud that did not happen. The report
  says so. Duplicates stopped and money claimed back are counted as money;
  the rest is counted as findings.

### What would end it

Fixed before a trial starts, so that the trial can fail:

- fewer than three businesses in ten asked will install it and export
  their files;
- the look-back finds nothing to claim at any of them, and a month of
  runs confirms no finding as real;
- nine findings in ten are dismissed, or decided in seconds;
- the accounting programs add the bank-change warning themselves.

## The bill watch (`bills`)

For any team that pays for cloud services and AI models. It saves, so it
is last by the owner's rule; it is here because its first user can be the
owner, on the owner's own accounts, and because that would be harness's
first run against a real provider.

- **Reads:** cost and usage by day from Anthropic and OpenAI (an
  organisation's admin key is needed at both) and from AWS (whose cost
  interface charges per request, so the pack asks once a day).
- **Looks for:** a day far above the usual for that weekday; a model or a
  key whose cost doubled; a service that costs and shows no use; spend on
  the way past the month's budget.
- **Proposes:** what to look at and what to change, with the number.
  Changing it (a limit lowered, a key withdrawn, a machine stopped) needs
  a key that can write, and is a later step, asked every time.
- **Counts:** findings, actions taken, and the spend after against the
  spend before.
- **Seeing the bills is free elsewhere** (the providers' own alerts; one
  tool is free up to $2,500 of spend a month). If a month beside those
  shows nothing they did not, this stays a small feature and goes no
  further.
- **With omnigate:** the owner's gateway already sees what was routed
  through it. The pack can set the provider's bill beside omnigate's
  count and show the difference, which neither sees alone.

## Build order

Each step ends in something that can be shown.

0. **In the world.** harness against a real model, with the owner's own
   key, and `bills` reading the owner's own accounts. The first real
   numbers.
1. **Findings, the page, the file reader, counting.** Used by every pack.
2. **`billing`, read-only, on Stripe.** Built against Stripe's test mode;
   then one real account, whose audit is the first result to show anyone.
3. **`disputes`** on the same connector, once PDFs are written.
4. **`payrun` from files, with the look-back.** Three to five businesses,
   one of them outside Poland, with the ending rules above.
5. **`ledgermcp`,** then the Polish readers for `payrun`.
6. **Changing things:** the tools that end a discount, correct a
   quantity, write the payment file. Each asked every time, each with a
   cap.

## Constraints

- Std only in harness; connectors are separate programs.
- The gate, the log, the injection checks and the sandbox stay as they
  are. A pack's code runs in the sandbox with no network; only connectors
  reach outside.
- A file a person exports is outside text: a cell that says what to do is
  data.
- An install with no pack is unchanged.
- Copy: plain labels and sentences. Amounts with their currency, never
  rounded in a finding's rows.

## What is not known

- **Whether anyone wants it.** No business was asked. The price points
  seen are small (one bank-change alert for an accounting program costs
  about AUD 9 a month and has one review).
- **How much each pack finds at a small business.** Fraud figures are
  not split by company size; duplicate-payment rates (0.8 to 2% of what
  is paid out) describe large organisations; revenue leakage has no
  trustworthy figure at all.
- **Whether a bookkeeper will install an agent,** bring a model key, and
  export files before each payment run.
- **Whether accounting programs other than Xero give suppliers' bank
  details to a connector.** Xero's fields were confirmed only through
  others' documentation.
- **Whether AI providers' admin keys can be made read-only.**
- **Whether a model is good enough** at the small parts given to it here,
  in English or in Polish. Nothing has run.

## Questions for the owner

1. **Is the order right:** billing audit, disputes, payment-run check,
   with the bill watch run first on your own accounts? Proposed: yes.
2. **Is there a Stripe account to audit?** Yours, or one company's that
   would let harness read it. Proposed: nothing past step 2's test-mode
   build until there is.
3. **Charging for the past:** off unless asked, finding by finding?
   Proposed: yes.
4. **One file for both lines of work,** or does the fintech file fold
   into this one? Proposed: two files; onboarding and the regulated
   buyers stay there.
5. **A name for it?** The packs have names; the product does not.

## Calls I made (the owner can overrule)

- **One product, four packs, in the order earn, keep, save.**
- **One person uses it, through the desk app.** More people come with the
  fintech file's Part B, when a company asks for two signatures.
- **Read-only first, in every pack.** Changing anything is the last build
  step.
- **Rules in code; the model's part is small and named.**
- **A finding is a question, and "intended" is an answer.**
- **From now on by default; the past only when asked.**
- **Files before connectors** for the payment-run check.
- **The look-back** as the way to a number in the first month.
- **Ending rules written before a trial.**
- **A country's systems are optional inputs.** Poland's are the first and
  the best, and the place to start.
- **The gate for other companies' agents is not here.** The research found
  that market crowded and priced near zero; it would be a free feature of
  harness, not a job in this product.

## Sources (read 2026-11-25 and 26)

- Stripe's keys that can only read chosen records:
  https://docs.stripe.com/keys/restricted-api-keys
- Revenue leakage, the one survey with a method (2016):
  https://mgiresearch.com/research/revenue-leakage/
- Losses to payments sent to the wrong account, UK (2025 figures):
  https://www.ukfinance.org.uk/system/files/2026-06/UK%20Finance%20Fraud%20Report%202026.pdf
- Bank name checks and batches (how many company files opted out at one
  bank):
  https://flow.db.com/files/documents/more/publications/flow-briefing/Deutsche-Bank-flow-briefing-Verification-of-Payee.pdf
- The US rule that every business sending bank payments must have a
  process against payments made under false pretences (2026):
  https://www.nacha.org/rules/risk-management-topics-fraud-monitoring-phase-2
- Average claim for a diverted payment, from an insurer:
  https://www.coalitioninc.com/claims-report/2026
- Duplicate or wrong payments as a share of what is paid out (large
  organisations, second-hand):
  https://www.cfo.com/news/metric-of-the-month-detect-and-prevent-duplicate-or-erroneous-payments/
- Firms that search past payments for duplicates, for a share:
  https://www.sec.gov/Archives/edgar/data/1007330/000100733020000013/prgx-20200930.htm
- An accounting program's users asking to be told when a supplier's bank
  details change:
  https://productideas.xero.com/forums/939198-for-small-businesses/suggestions/44961181-contact-email-notification-notify-all-users-or
  ; the one small tool that does it:
  https://apps.xero.com/uk/function/payments/app/vendoralert
- Structured e-invoices by country and year:
  https://www.vatupdate.com/2025/11/03/2026-the-year-mandatory-e-invoicing-sweeps-across-europe
- AI-model cost by interface: https://platform.claude.com/docs/en/manage-claude/usage-cost-api
- Cloud waste as organisations estimate it themselves:
  https://www.flexera.com/about-us/press-center/flexera-finds-cloud-value-is-rising-while-ai-waste-grows
  ; a cost tool that is free at small scale: https://www.vantage.sh/pricing
- How often people accept an agent's questions without reading:
  https://www.anthropic.com/news/claude-code-auto-mode
