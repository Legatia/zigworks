# harness for fintech companies: three jobs, and what harness needs for them

For the owner, from the Windows session, 2026-11-25. The owner asked what
harness could be sold for to fintech companies, chose jobs that earn the
client money over jobs that save cost ("We should sell something that
helps our clients make more money"), said of the three named "These 3 are
nice to build. But explore what is needed and what are we lacking", and
then "Explore and spec the fintech".

No code. Every decision here is my call and is listed at the end for the
owner to overrule. The facts about the outside world come from a search
on 2026-11-25; each has its source at the end, and what could not be
confirmed is marked "not confirmed".

## Intent

A company that takes payments or opens accounts runs harness on its own
server, and harness prepares three kinds of work for its staff:

1. **Disputes:** the answer to a card chargeback, with its evidence, ready
   to send before the deadline.
2. **Overdue:** reminders and follow-up for unpaid invoices and failed
   subscription payments.
3. **Onboarding:** the file on a business that applied to become a
   customer (KYB), ready for the compliance officer's decision.

In all three harness gathers, checks and drafts. A named person decides
and the log shows who. That is what harness already is for one owner: it
asks before acting, keeps a log that shows tampering, keeps secrets from
the model, caps spending, and runs unattended commands in a sandbox.

## What the company gets, and how it is measured

| Job | What it earns the company | Measured by |
|---|---|---|
| Disputes | money won back | amount won ÷ amount disputed, against the months before |
| Overdue | money collected sooner, customers kept | amount collected, days to payment, against a group left as before |
| Onboarding | customers who start paying sooner, fewer who give up | days from application to decision, share of applications finished |

Prices are not in this file: the repository is public.

## Goals

- Each job runs from an outside event to a person's decision with no step
  done by hand in between, and each fact in front of that person names
  where it came from.
- A company installs it on a Linux server of its own. Its customers' data
  never leaves that server except to the model it chose and the services
  it already uses.
- More than one person can work in it, each signed in as themself, and a
  second person can be required for a decision.
- Before a company relies on it, it can run its own past cases through it
  and read a score.

## Non-goals

- Deciding. Whether to take a customer, what a customer's risk is, whether
  to report a suspicion, whether to send a dispute answer: a person's, in
  every version of this.
- Retrying failed card payments better than the payment provider does.
  Stripe, Adyen and GoCardless retry with data from every merchant they
  serve. harness checks the company's retry settings and works on what the
  retries leave.
- Checking identity documents and faces of people (passports, liveness).
  Specialised services do that; harness reads their result.
- Monitoring transactions for money laundering. Another product, with
  another risk.
- A hosted service. The owner set that aside on 2026-11-24 ("we don't rent
  server for clients").

## Anti-goals

- **No credit decisions about people.** Scoring a natural person's
  creditworthiness is a high-risk use under the EU AI Act (Annex III,
  point 5(b)). None of the three jobs does it, and no pack may add it.
- **No collecting for others.** harness sends in the creditor's own name,
  from the creditor's own systems. A company that collects other
  companies' debts is a debt collector under US Regulation F and needs
  licences in several EU states; that is not this product.
- **No way around a register's limits.** No CAPTCHA solving, no reading a
  register's pages faster than its terms allow (Germany's Handelsregister:
  60 retrievals an hour), no beneficial-owner register reached with
  another company's access.
- **No card numbers.** The payment providers' APIs return the last four
  digits. A full card number that arrives in a customer's message is
  masked before the model or the log sees it.
- **No free text from a model to a consumer about a debt.** Fixed texts a
  person approved, with fields filled in.

## What harness has for this today, and what it lacks

Checked against the README and the source on 2026-11-25.

| Need | Today | Lacks |
|---|---|---|
| A person approves each action | the gate, the inbox, workflows' `approve` and `review` steps | more than one person; roles; a second approver; sign-in |
| A record of who did what | a hash-chained log, `harness log verify` | the person's name on an answer; personal data kept out of the log |
| Outside systems reached without the model seeing keys | secrets in the key store, MCP with bearer or OAuth, variables for commands, masking | narrow tools for payment providers and registers; uploads |
| Started by an outside event | triggers that poll (a minute at least) | webhooks |
| Documents | text files only | PDFs and images read; a PDF written |
| Many cases at once, lasting weeks | workflows: 3 at once, 50 instances, 7 days | limits a company sets; a case as a thing with a folder and a deadline |
| Messages to the company's customers | `mail_send` from the agent's own mailbox, asked each time, never unattended, 30 a day | sending from the company's systems under a plan approved once |
| Run on a server | `harness run` in the foreground, the desk on 127.0.0.1 | a service, a page for staff behind the company's proxy |
| Proof it works | unit tests, a smoke script, injection checks against a stand-in | scored runs on real past cases; any run against a real provider |

The last line is the first thing to change: nothing in harness has run
against a real model provider, payment provider or mail server yet
(`2026-11-23-harness-gaps.md`, "Not tested in the world").

## The design in one page

- **One install per company,** on its own server. One data folder. harness
  listens on 127.0.0.1 as today; the company's own reverse proxy ends TLS
  and forwards.
- **A pack per job.** A pack is a folder: workflows, agent definitions,
  rules sections for the gate, the settings of the MCP servers it needs, a
  page for staff, and a set of test cases. `harness pack add disputes`.
  The three packs are `disputes`, `overdue` and `onboarding`.
- **A case per piece of work.** One dispute, one unpaid invoice, one
  application. A case is a workflow instance with a folder of its own.
- **Staff sign in** through the company's own sign-in (OpenID Connect)
  and answer on a page that lists the cases.
- **Connectors are MCP servers** with narrow tools the gate can rule on by
  name.

The parts below are each usable alone and are in build order further down.

## Part A: cases

A case is what staff see and what the log, the measures and deletion
work on.

- **Where:** `cases/PACK/ID/` in the data folder:
  - `case.ini`: what it is about (the provider's own id for the dispute,
    invoice or application), its state, its deadline, who holds it, the
    amounts.
  - `evidence/`: every file and page gathered, each with a line in
    `evidence.jsonl`: where it came from (tool and address), when, its
    SHA-256, and which statement in the draft rests on it.
  - `draft/`: what harness prepared (fields, texts, the PDF).
  - `decision.ini`: who decided what, when, with their note.
- **States:** gathering, needs a person, returned for more, approved,
  sent, closed (with its outcome), failed. Fixed, and set by harness's
  code from the workflow's steps, never by model text.
- **A case's runs see only that case.** Its folder is the run's workspace.
  They get no memory tool and no `people` tool (as workflow runs already
  do not), so one customer's facts cannot reach another's case.
- **Deadlines:** a case with a deadline shows it everywhere. Two days
  before it (set per pack) an unapproved case becomes urgent for every
  approver. harness never sends by itself because a deadline is near.
- **Limits a company sets,** in `[workflows]` and per workflow: instances
  (default stays 50), `at-once`, and `days` (a dispute's outcome can take
  75 days after the answer). The numbers the three jobs need are small:
  tens to hundreds of new cases a month for a small company. One turn at
  a time per case; cases in parallel on the background slots
  (`concurrent_runs`, raised by the company to what its model budget
  bears).
- **Deleting:** `harness case rm PACK ID` removes the folder. The log
  keeps its lines with sizes and keyed hashes in place of content (as
  `/private` does today), so the chain still verifies. `[cases] keep_days`
  removes closed cases after that many days.

## Part B: people

Today harness has one owner. A company needs several people and needs to
know which of them answered.

- **`staff.ini`:** one section per person: the name harness uses, the
  sign-in's subject, and roles.
  - `prepare`: may open cases, return them, edit drafts.
  - `approve`: may approve and send.
  - `admin`: may change settings, rules and staff. The owner of today is
    the first admin, and stays the only one who answers in a terminal.
- **Sign-in:** OpenID Connect against the company's own provider (Entra
  ID, Okta, Google Workspace, Keycloak), authorization code with PKCE.
  harness already has that flow as a client for MCP servers. It checks
  the ID token's signature itself (RS256 and ES256, from the provider's
  published keys). The session is a cookie, as on the desk. No passwords
  in harness.
- **A second person:** a rules line per pack or per kind of item,
  `approvers = 2` or `not_the_preparer = on`. An item then closes only
  when the people required have answered, and a person who edited the
  draft does not count when `not_the_preparer` is on.
- **The log names the person** on every answer and edit (`by:
  staff:NAME`), and `harness log search` finds by person.
- **Telegram stays the single owner's.** Staff are told of urgent cases by
  mail to their work address through the company's mail server, a line
  and a link, never the case's content.

## Part C: the staff page

An app in harness's app server (the apps design, gap 8), reached through
the company's proxy.

- A list of cases: pack, state, deadline, amount, who holds it. Sorted by
  deadline. Filters by pack and state.
- A case: the draft on one side, the evidence on the other. Each statement
  in the draft links to the evidence line it rests on; a statement with no
  evidence is marked.
- Buttons from the case's state: Approve and send, Return (with a note
  harness acts on), Take over (the person edits the draft), Close without
  sending.
- What a button does goes through the gate like every action, and is
  logged with the person.
- The page never shows a secret, and what came from outside (a customer's
  message, a web page, a document) is shown as text, never run.

## Part D: events from outside

- **`kind = webhook` for triggers:** `POST /hooks/NAME` on the app
  server's port. harness stays on 127.0.0.1; the company's proxy forwards
  that one path.
- **The sender is checked** before anything is read:
  - `verify = stripe`: the `Stripe-Signature` header's time and HMAC-SHA256
    over the body, with a five-minute tolerance;
  - `verify = adyen`: Adyen's HMAC over the notification;
  - `verify = hmac-sha256`: a header the trigger names, hex or base64.
  The key is a stored secret. A request that fails is answered 400 and
  logged without its body.
- **Answered at once, worked on later:** the event is written to disk and
  200 is returned; an event id seen before is dropped.
- **The body is outside text.** The trigger names the fields it takes
  (`take = data.object.id, data.object.amount`); nothing else reaches a
  run, and what reaches it is data. The run then reads the real object
  from the provider through the connector, so a forged body can at most
  start a look at something real.
- **Polling stays** for a company that will not forward a path: the same
  trigger with `kind = mcp` asks the connector every few minutes. For
  disputes and applications, minutes are enough.

## Part E: documents

- **Read:** `read_file` on a PDF or an image hands it to the model as a
  file (the Anthropic format takes PDFs and images; the OpenAI format
  takes images and files). Limits per file and per turn, set in
  `config.ini`. Where the chosen model takes no PDFs, the text is taken
  with `pdftotext` in the sandbox when it is installed, and the run is
  told that pictures in the file were not read.
- **A document is outside text.** After reading one, a run is held to what
  the injection checks already hold it to: no spending, no sending, no
  remembering without a person.
- **Write:** harness writes the pack as HTML and has Chrome print it to
  PDF (the browser it already drives, through its pipe, in the sandbox,
  with no network). That handles every script, where a PDF writer of our
  own would need fonts built in.
- **Size rules are the connector's:** the disputes pack is cut to the
  provider's limits before a person sees it (below), and says what it
  left out.

## Part F: connectors

Each is an MCP server in Zig beside `mailmcp`, `calmcp` and `homemcp`,
with a simulated backend for tests.

### `paymcp`: payment providers

Stripe first, then Adyen. Tools the gate can tell apart:

| Tool | Does | Asked |
|---|---|---|
| `dispute_list`, `dispute_get` | open disputes, one with its charge and the same card's earlier payments | no (reads) |
| `dispute_stage` | puts evidence on the dispute without sending it (`submit=false` on Stripe) | no: nothing leaves |
| `dispute_send` | sends the staged evidence. Final on every provider | every time, by an approver |
| `dispute_accept` | gives the dispute up. Final | every time, by an approver |
| `file_upload` | uploads a PDF or image for a dispute | no |
| `invoice_list`, `invoice_get`, `payment_get` | unpaid invoices, failed payments with the provider's advice | no |
| `payment_link` | a page where the customer pays or changes their card | no |
| `retry_settings` | reads the company's retry settings | no |

- **Why not the provider's own MCP server alone.** Stripe has one
  (`https://mcp.stripe.com`). Its write tool is one tool for the whole
  API, so a rule cannot allow "stage evidence" and refuse "refund" or
  "pay out"; and it does not upload evidence files. It is fine for reads.
- **The key is a restricted one,** made by the company for disputes, files
  and invoices only. `paymcp` refuses to start with a key that can do
  more, where the provider lets it tell.
- **No tool retries a payment or refunds one.** If that is wanted later it
  is a money tool, with caps, asked every time.

### `regmcp`: company registers

| Source | Access | Gives | Note |
|---|---|---|---|
| UK Companies House | official API, free, a key | company, officers, persons with significant control | 600 requests per 5 minutes |
| GLEIF (LEI) | official API, open | legal entity, direct and ultimate parent | no directors or owners |
| Poland KRS | official open API | company, board, shareholders in the extract | by KRS number; limits not confirmed |
| Poland CRBR | public register; an API specification is published | beneficial owners | contents of the API not confirmed |
| France | API Recherche d'entreprises, open | company, directors | no beneficial owners (restricted since 2024-07-31) |
| Estonia | API under a contract with RIK, free | company, shareholders | beneficial owners restricted since 2026-07-10 |
| Netherlands KVK | API with a subscription, paid per query | company profile | beneficial owners: authorised institutions only, as PDF |
| Germany | no official API | — | through a paid aggregator, or by hand |

- Tools: `company_find`, `company_get`, `company_officers`,
  `company_owners`, `company_document` (a filed document, where the
  register gives one).
- Every answer carries the register's name, the address asked and the
  time, and is kept in the case's evidence as received.
- **Beneficial-owner registers** are open to obliged entities for due
  diligence (Directive (EU) 2024/1640, Article 11) and closed to the
  public in most states since the Court's judgment of 2022-11-22. The
  company's own access is used, country by country, under its own name.
- Countries beyond these come through an aggregator the company has a
  contract with (Kyckr and others), one backend each.

### Screening: sanctions, politically exposed persons, adverse media

- **Sanctions:** the official lists are free and machine-readable (EU, UN,
  OFAC, the UK Sanctions List, which replaced OFSI's list on 2026-01-28).
- **Politically exposed persons** are not on any official list of names
  (the EU publishes functions, not people), so a data source is needed.
- **The source is the company's:** the screening service it already pays
  for, or OpenSanctions, which has an official MCP server and a matching
  server that can run on the company's own machine (`yente`). Its data is
  free for non-commercial use only; a company needs a licence.
- **Adverse media** is a web search by harness, kept to what the
  regulation allows to be processed: reports tied to money laundering,
  its predicate offences or terrorist financing, each marked as an
  allegation, an investigation, proceedings or a conviction (AMLR Article
  76(3)).
- **A possible match is never cleared by the model.** harness lays out what
  matches and what differs (date of birth, nationality, identifiers) and a
  person marks it.

### The company's own systems

Orders, deliveries, support tickets, the product's own usage records,
the system applications arrive in. These differ per company.

- Where the system has an MCP server, it is added to `mcp.ini` with a key
  that reads only.
- Where it has an HTTP API, calls go through keygate (the sibling tool
  that adds a real key to a request under allow rules, so the agent holds
  a placeholder). harness's own `fetch` is GET-only and stays so.
- A connector we write for one company's system is that company's work,
  quoted apart.

## Part G: messages to the company's customers

Needed by the overdue pack only. Today every mail harness sends is asked
about, one by one, and none goes out unattended.

- **A plan approved once.** A plan is a file: who it is for (which
  invoices or failures), the texts with their fields, the days between
  messages, the most per customer, and when it stops. An approver reads
  the whole plan and approves it. After that, messages inside the plan go
  out without a question; anything outside it is asked.
- **Sent by the company's own mail system,** from its own address, through
  its relay or mail service. Never from the agent's mailbox.
- **For consumers, fixed texts.** The model picks which approved text
  fits and fills its fields from the case. It writes nothing of its own.
- **For businesses, drafts.** The model may draft a message about an
  invoice; a person approves each, until the company turns a draft into a
  plan's text.
- **Rules harness applies itself,** in code, whatever the plan says:
  - at most the plan's number of messages per customer per week, and never
    more than one a day;
  - none before 08:00 or after 21:00 in the customer's own time;
  - every message says how to stop them, and a stop is kept in a list the
    plan cannot override;
  - no message once the customer disputes the debt, says they cannot pay,
    or asks for no contact: the case goes to a person.
- **Answers are outside text.** A reply is sorted by a model with no tools
  into fixed kinds (will pay on a date, disputes it, cannot pay, wrong
  person, stop, other), and the kind decides what happens next. Nothing
  in a reply is followed as an instruction.

## Part H: measuring

- **`harness eval PACK`:** runs a folder of recorded cases. Each has what
  the connectors answered (played back by a stand-in, no network) and what
  a good result holds (the owners found, the fields filled, the decision a
  person made). The score is by fixed checks, with the run's log kept for
  reading. A company runs its own past cases before it switches a pack on.
- **Outcomes:** each closed case writes a line to `cases/outcomes.jsonl`:
  amounts, days, who decided, whether the person changed the draft.
  `harness report PACK --month` sums it.
- **A group left as before** for the overdue pack: one case in ten
  (set by the company) is not worked, so that what the pack collected can
  be told from what would have been paid anyway.

## Part I: running on a server

- A service unit for systemd (`harness service install`), running as a
  user of its own, with the sandbox for every command.
- `harness run` already works without Telegram (2026-11-25); on a server
  the staff page is the way in.
- The disk's encryption is the company's (the system's own). harness keeps
  files private to its user and says in `harness doctor` when the data
  folder is on an unencrypted disk, where it can tell.
- Updates: the company installs a release when it chooses. Nothing phones
  home.

## The three packs

### Disputes

1. **Start:** the provider says a dispute opened (Stripe:
   `charge.dispute.created`), or the poll finds one. A case is made with
   the provider's deadline (`evidence_details.due_by`; usually 7 to 21
   days on Stripe, 18 days for Visa and 40 for Mastercard on Adyen).
2. **Gather:** the dispute and its reason; the charge with its address,
   code and 3-D Secure results and the buyer's IP; the same card's earlier
   payments; the order, the delivery and its tracking; what the customer
   and the company wrote to each other; the terms shown at the sale; the
   product's own record of use.
3. **Sort by reason,** each with its own list of what counts: fraud, not
   received, not as described, cancelled subscription, duplicate, other.
4. **Visa's rule for fraud disputes** (Compelling Evidence 3.0, reason
   10.4) is checked in code, not by the model: two earlier undisputed
   payments on the same card, 120 to 364 days before, matching the
   disputed one on IP address or device, or on one of those and one of
   shipping address, email or account.
5. **Propose:** answer, give up, or needs a person, with the reason and
   the fee that answering costs (on Stripe a fee equal to the dispute fee
   is charged for answering and returned on a win).
6. **Draft** the provider's fields and one PDF per kind of evidence, cut
   to the provider's limits (Stripe: PDF, JPEG or PNG, 4.5 MB together,
   under 50 pages, 19 for Mastercard). Staged at the provider without
   sending.
7. **A person approves.** `dispute_send` is final: providers take one
   answer.
8. **Wait** for the outcome (`charge.dispute.closed`), which can take 60
   to 75 days, and record it.

- **Where a provider already answers by itself** (Stripe's Smart Disputes
  sends its own packet near the deadline when the merchant has done
  nothing), the pack says so at setup, and the company chooses which of
  the two answers.
- **What harness adds over the provider's own tool:** the evidence in the
  company's own systems, which the provider does not hold.
- **Left out:** alerts before a dispute (Verifi, Ethoca), which the
  company switches on at its provider.

### Overdue

Two kinds of case, with different rules.

**A business's unpaid invoice.** Outside consumer debt rules; in the EU
the Late Payment Directive gives interest and a fixed EUR 40 without a
reminder being needed.

1. **Start:** an invoice passes its due date.
2. **Gather:** the invoice, earlier ones and how they were paid, open
   tickets and disputes with that customer, who the contact is.
3. **Hold back** when something is open: a complaint, a credit note asked
   for, a delivery in question. The case goes to a person with what was
   found.
4. **Draft** the reminder, in the tone the history calls for, with the
   invoice and a way to pay. A person approves, or the plan covers it.
5. **Follow:** a reply saying when it will be paid sets a date; on that
   date harness looks and, unpaid, says so. A dispute or a problem goes to
   a person.

**A subscription's failed payment.** The creditor's own reminder to its
own customer.

1. **Start:** the provider says a payment failed and its retries are used
   up or pointless (Stripe: `invoice.payment_failed` with no next attempt,
   or a decline the provider says not to retry).
2. **Sort** by the provider's advice: the card must be replaced (expired,
   lost, closed), the bank refused for now, the customer must confirm.
3. **Send** the plan's text for that kind, with the provider's own page
   for changing the card. harness never asks for card details.
4. **Stop** when it is paid, when the plan ends, or when the customer
   answers with something for a person.

- **At setup the pack reads the company's retry settings** and says what
  they are against the card networks' limits (Visa: at most 15 tries in
  30 days by the stricter of the two figures published, and never after a
  "do not retry" answer; Mastercard: at most 10 in 24 hours and 35 in 30
  days). It changes nothing there.
- **Consumer credit is out of the first version:** lenders' arrears fall
  under forbearance rules (Directive (EU) 2023/2225 from 2026-11-20; the
  UK's CONC 7) that need the lender's own process around every message.

### Onboarding

What the file must hold is the law's list (EU Regulation 2024/1624,
Articles 20 and 22, applying from 2027-07-10; Directive 2015/849 until
then; the UK's Regulations 2017, regulation 28).

1. **Start:** an application arrives from the company's own system, with
   what the applicant declared and uploaded.
2. **The entity:** found in its register by its number. Name, legal form,
   registered office, where it does business, registration and tax
   numbers, LEI when it has one, the people who represent it. Each
   compared with what was declared; each difference listed.
3. **Who owns and controls it:** shareholders from the register, and
   their owners in turn, until people are reached or a register ends the
   trail. The chain is kept as a tree with a source at every link.
   Beneficial owners by the company's threshold (the EU's new rule is 25%
   or more, today's and the UK's more than 25%), worked out in code from
   the tree. Compared with the beneficial-owner register and with what
   was declared.
4. **Screening:** the entity, its representatives and its owners against
   sanctions and politically exposed persons, and an adverse media search.
   Possible matches laid out for a person.
5. **Documents:** the certificate, the articles, the proof of address
   read and compared with the register.
6. **The business:** its site and what it says it does, against the
   declared activity and the register's.
7. **What is missing:** a list, and a drafted request to the applicant
   for exactly those things, sent by the company's system once a person
   approves.
8. **Risk points** by the company's own table, added up in code from the
   facts found. harness shows the sum and each line's reason; it gives no
   opinion of its own.
9. **The compliance officer decides:** take, ask for more, refuse. The
   file goes to the company's system as a PDF and as data. harness's copy
   is deleted after `keep_days`; the five years the law asks for are kept
   in the company's system of record.

- **What the law keeps with the company,** whatever tool it uses (AMLR
  Article 18): the risk profile, the decision to take the customer, the
  report of a suspicion. And a decision that takes, refuses or keeps a
  customer needs a person's real part in it (Article 76(5)). The pack is
  built so that none of these can happen without a named person.
- **Later:** watching a taken customer's register entry for changes, and
  screening again on a schedule.

## Constraints

- Std only in harness, as now. Connectors are separate programs.
- The gate, the log, the injection checks and the sandbox default stay as
  they are; this adds people to the gate and does not loosen it.
- A single owner's install is unchanged: no staff file means one owner,
  Telegram and the desk as today.
- Copy on the staff page and in every drafted text: plain labels and
  sentences.
- Nothing in a pack is specific to one model provider. A company may keep
  everything on a model it hosts.

## Build order

Each step ends in something a company can use.

0. **In the world.** harness against a real model and against Stripe's
   test mode, which can open a test dispute and settle it (to be checked
   in Stripe's testing pages when this starts). Without this step nothing
   below can be shown to anyone.
1. **Disputes for one person.** `paymcp` for Stripe, the PDF, cases
   (Part A), limits a company sets, polling. It runs with today's single
   owner, who is the company's person for disputes. This is the shortest
   way to a result counted in money.
2. **Measuring** (Part H), on that company's past disputes.
3. **People and the staff page** (Parts B and C), and the server install
   (Part I).
4. **Webhooks** (Part D).
5. **Documents read** (Part E), `regmcp` for the UK, Poland and GLEIF,
   screening through OpenSanctions: **Onboarding**.
6. **Messages under a plan** (Part G): **Overdue**, business invoices
   first.
7. Adyen in `paymcp`; more registers.

## What is not known

- **No company has been asked.** Which of the three hurts most, what they
  use today, and what they would let software do is all assumption until
  five of them say. The first step before step 1 is those conversations.
- **Whether a model's file is good enough** for a compliance officer to
  rely on. Step 2's score answers it; nothing before does.
- **Others sell these jobs already:** Stripe's own Smart Disputes and
  Chargeflow for disputes; Churnkey, Chaser and Upflow for overdue;
  Parcha, Bretton AI, Duna, Spektr and Arva for onboarding, several with
  tens of millions raised in 2026. What is different here is that it runs
  on the company's own server with its own model and a log it can verify.
  Whether that is enough to be chosen is not known.
- **Legal reading,** to be checked by a lawyer before a sale:
  - whether a company that runs this software itself must tell its
    supervisor as it would for outsourcing (AMLR Article 18);
  - whether the licence and support make us an ICT third-party provider
    under DORA, with Article 30's contract terms;
  - each country's rules on a creditor's own reminders (frequency, hours,
    wording), which were not researched beyond the EU, UK and US rules
    listed below.
- **Not confirmed in the search:** Poland's KRS and CRBR API limits and
  contents; Mastercard's rulebook text on retries; the card networks' own
  dispute time limits (the providers' figures are used); whether Shopify
  and Zendesk have MCP servers that reach orders and tickets.

## Questions for the owner

1. **Which job first?** Proposed: disputes, because step 1 needs the
   least new and its result is money won. Onboarding earns more per
   customer and needs steps 3 and 5 first.
2. **Companies run it themselves, and we host nothing,** as decided on
   2026-11-24? Proposed: yes. For this market it is also the reason to
   choose it.
3. **Is there a company to build step 1 with?** Proposed: none of it is
   built before one says yes to trying it on its own test account.
4. **Who pays for data** (screening, registers that charge)? Proposed:
   the company, under its own contracts; we hold none.
5. **A lawyer's reading** of the three points above before the first
   sale? Proposed: yes.
6. **This file is public,** as the repository is. Should fintech work move
   to a private repository? Proposed: specs here, prices and customers'
   names never.

## Calls I made (the owner can overrule)

- **Three packs on one harness,** not three products.
- **A person decides everything that leaves or binds;** no setting turns
  that off for a dispute answer, a customer decision or a suspicion.
- **Retries are left to the payment provider.** The overdue pack works on
  messages and on what retries cannot fix.
- **Consumer credit arrears are out** of the first version; business
  invoices and subscriptions are in.
- **Our own narrow payment connector,** not the provider's general one,
  for anything that writes.
- **Sign-in is the company's own (OpenID Connect),** checked by harness;
  harness holds no passwords.
- **Chrome prints the PDFs.**
- **Rules that matter are code:** Visa's evidence rule, beneficial-owner
  thresholds, risk points, message limits and hours. The model gathers
  and drafts; it is not asked to do arithmetic or to apply a rule.
- **A case's runs see only that case,** and write no memory.
- **Disputes first** in the build order.
- **Nothing is built until a company agrees to try it.**

## Sources (read 2026-11-25)

Payments:

- Stripe disputes: https://docs.stripe.com/disputes/how-disputes-work ,
  https://docs.stripe.com/api/disputes/update ,
  https://docs.stripe.com/disputes/best-practices ,
  https://docs.stripe.com/disputes/responding ,
  https://docs.stripe.com/disputes/smart-disputes ,
  https://docs.stripe.com/disputes/api/visa-ce3 ,
  https://support.stripe.com/questions/june-2025-pricing-updates-for-disputes
- Stripe MCP: https://docs.stripe.com/mcp
- Stripe retries and declines:
  https://docs.stripe.com/billing/revenue-recovery/smart-retries ,
  https://docs.stripe.com/declines/card ,
  https://support.stripe.com/questions/payment-blocked-due-to-excessive-retries
- Adyen disputes: https://docs.adyen.com/risk-management/disputes-api ,
  https://docs.adyen.com/risk-management/understanding-disputes/dispute-timeframes
- Visa and Mastercard retry limits as providers state them:
  https://docs.adyen.com/development-resources/raw-acquirer-responses/visa-integrity-fees ,
  https://www.checkout.com/merchant-communications/changes-to-visa-system-integrity-fees ,
  https://developer.paypal.com/braintree/articles/risk-and-security/compliance/network-updates/2023/mastercard-f23
- Chargeflow's prices: https://www.chargeflow.io/pricing

Contact rules:

- Directive (EU) 2023/2225 (consumer credit):
  https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32023L2225
- Directive 2011/7/EU (late payment):
  https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32011L0007
- UK CONC 7: https://handbook.fca.org.uk/handbook/conc7/conc7s3
- US Regulation F: https://www.consumerfinance.gov/rules-policy/regulations/1006/2/ ,
  https://www.consumerfinance.gov/rules-policy/regulations/1006/6/ ,
  https://www.consumerfinance.gov/rules-policy/regulations/1006/14/

Onboarding:

- Regulation (EU) 2024/1624: https://eur-lex.europa.eu/eli/reg/2024/1624/oj
  (Articles 18, 20, 22, 43, 52, 76, 77, 90, read on a mirror)
- Directive (EU) 2024/1640: https://eur-lex.europa.eu/eli/dir/2024/1640/oj
  (Articles 11, 12, 78)
- UK Money Laundering Regulations 2017:
  https://www.legislation.gov.uk/uksi/2017/692/regulation/28
- EU AI Act, Annex III: https://artificialintelligenceact.eu/annex/3/ ;
  its dates as changed by Regulation (EU) 2026/1744:
  https://eur-lex.europa.eu/eli/reg/2026/1744
- DORA, Articles 28 and 30:
  https://www.digital-operational-resilience-act.com/Article_30.html
- Companies House: https://api.gov.uk/ch/companies-house/ ;
  GLEIF: https://www.gleif.org/en/lei-data/gleif-api ;
  Poland KRS: https://prs.ms.gov.pl/krs/openApi ;
  Poland CRBR: https://www.gov.pl/web/finanse/centralny-rejestr-beneficjentow-rzeczywistych ;
  France: https://www.data.gouv.fr/dataservices/api-recherche-dentreprises ;
  Estonia: https://avaandmed.ariregister.rik.ee/en/open-data-api/introduction-api-services ;
  Netherlands: https://developers.kvk.nl/pricing ;
  Germany: https://github.com/bundesAPI/handelsregister
- UK Sanctions List:
  https://www.gov.uk/guidance/moving-to-a-single-list-for-uk-sanctions-designations-28-january-2026
- OpenSanctions: https://www.opensanctions.org/licensing/ ,
  https://www.opensanctions.org/docs/api/mcp/ ,
  https://www.opensanctions.org/docs/self-hosted/
