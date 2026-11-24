# harness: importing a Hermes setup, and skills from agentskills.io sources

The second of the Hermes differentiators in the gaps list
(`2026-11-23-harness-gaps.md`). The owner's direction from the comparison:
"Make switching easy: read agentskills.io skills, which Hermes also uses,
and import a Hermes setup (memory, skills, cron jobs)." Asked for on
2026-11-24 ("start the Hermes import design").

## Intent

Someone who already runs Hermes has months of setup in `~/.hermes`:
memory about them, skills, scheduled jobs and MCP servers. Rebuilding all
of that by hand is the main thing that keeps them from trying harness.

Two commands remove that:

- **`harness import hermes`** reads a Hermes setup and brings over what
  maps. It also says plainly what doesn't map, and why.
- **`harness skill add SOURCE`** installs any skill in the agentskills.io
  format:
  - from a folder;
  - from a GitHub repo, which covers the `owner/repo` names that skills.sh
    lists;
  - from a link to a `SKILL.md`.

  harness already reads that format (`skills.zig`). What's missing is
  getting skills in, keeping their source, and updating them.

**One rule shapes both commands:** an import can narrow what harness may
do, but it never widens it.

- Deny patterns and excluded tools come in as deny rules.
- Hermes's "always" approvals come only as suggestions, in a file the
  owner can read and copy from.
- A skill's `allowed-tools` is shown, then ignored. Neither the other
  agent's history nor a file someone else wrote can loosen harness's gate.

## Goals

1. **`harness import hermes [--from DIR] [--profile NAME] [--dry-run] [--yes]`**
   - It prints a plan first. Then, in a terminal, it asks
     `Import? [y/N]`.
   - It writes what maps, takes a copy of every harness file it changes
     beforehand, and leaves a report.
   - It never changes Hermes's files.
2. **`harness skill add SOURCE [--skill NAME] [--yes]`**, plus
   `skill list`, `skill show NAME`, `skill update [NAME]` and
   `skill rm NAME`.
   - `add` shows the skill and asks before installing it.
   - Each installed skill keeps its source and a hash, so `update` can
     show what changed.
3. **`harness init` notices a Hermes setup.** When it finds one in
   `HERMES_HOME` or the default place, it says so and suggests
   `harness import hermes --dry-run`. It runs nothing itself.
4. **A README section, "Coming from Hermes".** What comes over, what
   doesn't, and the commands.

## Non-goals

- Importing Hermes's conversations (`state.db`, `sessions/`). They stay
  where they are; the report says so. harness's log is a hash chain of
  harness's own actions, and isn't a place for another agent's history.
- External memory providers (Honcho, Mem0 and others), plugins, kanban,
  plans, skins and pairing data.
- A skills marketplace, a search command, or a content scanner for
  skills. As with the injection checks, safety comes from the gate, not
  from spotting bad text.
- Exporting to Hermes.
- Installing skills from chat. This round is the owner's terminal only.

## Anti-goals

- **Copying a secret.** The import never copies a key or token into
  harness's files or store, and never prints one. Each one the owner will
  need is listed as the exact `harness secret add NAME` command to run.
- **A silent half-import.** Every item in Hermes's setup appears in the
  plan and the report, as imported, needing the owner, or not imported,
  with a reason.
- **Widening the gate** from anything imported (see Intent).
- **Running anything Hermes scheduled without the owner seeing it.**
  Scheduled jobs come over only through the plan the owner confirms.

## Where Hermes keeps things

Read from Hermes's own source at v0.23.4, the latest release, checked on
2026-11-24. Copy the fixtures from real files' shapes.

**Which profile.** Without `--profile`, the import follows
`active_profile`, as plain `hermes` does. The plan names the profile it
read.

**Stored shapes that were checked:**

- `jobs.json` is `{"jobs":[…]}`.
- A schedule is `{kind: once|interval|cron, run_at|minutes|expr, display}`.
  "Every day at 9am" is stored as a cron `expr`.
- `repeat` is `{times, completed}`.
- Memory entries are separated by `"\n§\n"`. The files total at most
  2,200 and 1,375 characters.
- `lock.json` is `{"version":1,"installed":{…}}`. It holds no commit.
- `.bundled_manifest` holds `name:hash` lines.
- MCP env values and headers are usually `${VAR}` references into `.env`.
- MCP servers' include and exclude lists take globs; include wins when
  both are given.

| Hermes | Path (under `HERMES_HOME`, default `~/.hermes`; `%LOCALAPPDATA%\hermes` on Windows; profiles under `profiles/NAME/`) |
|---|---|
| Settings | `config.yaml`: `model`, `providers`, `custom_providers`, `mcp_servers`, `approvals` (`deny`), `command_allowlist`, `skills` (`disabled`, `external_dirs`, `config`) |
| Keys | `.env` |
| Persona | `SOUL.md` |
| Memory | `memories/MEMORY.md` (the agent's notes) and `memories/USER.md` (about the user). Entries are separated by a `§` line |
| Skills | `skills/CATEGORY/NAME/SKILL.md` with support files; `skills/.hub/lock.json` (hub installs: source and hash); `skills/.bundled_manifest` (Hermes's own built-ins) |
| Scheduled jobs | `cron/jobs.json` |
| Conversations | `state.db`, `sessions/` (not imported) |

## `harness import hermes`: what maps

| Hermes | harness | How |
|---|---|---|
| `memories/MEMORY.md`, `USER.md` entries | memory items | One item per entry, counted as the agent's words, not the owner's. Entries already in memory, or nearly so, aren't added twice. An entry over memory's cap (2,000 bytes) is split at paragraph breaks, and is never cut short. Each item gets a single mention dated 60 days before the import. A bulk import then sits below what the owner said recently, and rises only when mentioned again. A test checks that importing 50 entries leaves the owner's top items as they were. Where an item came from goes in the report, not in a term: a given term replaces the derived ones and would break the near-repeat match. |
| `SOUL.md` | a pinned memory item, "How to talk with me: …" | Hermes writes a stock `SOUL.md` on first run ("You are Hermes Agent, built by Nous Research…"). One equal to the stock text, or to the older template, is skipped. An edited one comes over only if it fits the cap. A longer one isn't imported: the report says to make it an `agents/main.md` by hand, and why (that file replaces harness's built-in instructions). |
| User skills (in `skills/`, apart from unedited ones in `.bundled_manifest`) | `skills/NAME/` | Flattened out of their category folders, with their support files. The Hermes-only fields stay in the file and are shown in the plan. Hub installs from GitHub keep their source, so `harness skill update` works on them. Other hub sources (clawhub, skills.sh's own copies, official) come over with no source line, and the plan says harness can't update them. |
| Skills harness can't take as they are | renamed, or not imported | A name with `.`, `_` or `--` is renamed: `.` and `_` become `-`, and runs of `-` collapse into one. The frontmatter `name` is rewritten to match, and the plan shows each rename. A skill over harness's limits (64 KB `SKILL.md`, 256 KB a file) isn't imported; the plan gives its sizes. A skill in `skills.disabled` isn't imported, since harness has no off switch for a skill. A name already used in harness is skipped. Hermes's bundled skills aren't imported unless edited; `--bundled` brings all of them. |
| `cron/jobs.json` | `tasks.ini` sections | See "Scheduled jobs" below. |
| `mcp_servers`, stdio | `mcp.ini` sections | `command`, with args quoted as `mcp.ini` reads them. A secret env value, or a `${VAR}` reference, becomes a `secret = ENV:NAME` line plus a `harness secret add NAME` line in the plan. Plain env values need a new `env = NAME=VALUE` key in `mcp.ini` (see below). |
| `mcp_servers`, URL | `mcp.ini` sections | `url`, and `header` for headers that hold no secret. `Authorization: Bearer …` becomes `token = NAME`, plus a `harness secret add` line. `auth: oauth` becomes `login = oauth`, and the plan names `harness mcp login NAME`. A server needing any other secret header (such as `X-API-Key`) comes over commented out, with the reason: `mcp.ini` has no secret header. `transport: sse` isn't imported, since harness speaks Streamable HTTP only. |
| `mcp_servers`, both kinds | | Excluded tools become `deny mcp SERVER/TOOL*` rules. An include list is listed for the owner, since we can't know the server's other tools offline. A disabled server comes over commented out. A name already in `mcp.ini` is skipped. |
| `approvals.deny` | `deny shell PATTERN` rules | These only narrow. They're written in a block that starts with `[all]` and the comment `# from Hermes`, since rules after a `[WHO]` line would belong to that section. Hermes's patterns may use `?` and `[…]`; each becomes `*`, which only widens the deny. Hermes matches case-insensitively and harness doesn't, so the plan notes it. |
| `command_allowlist` | `state/imports/hermes-TIME/rules.suggested` | Entries that are commands or command globs become commented-out `allow shell` lines, never active; the plan says they're the owner's to copy. Entries that are Hermes's pattern names (such as `recursive delete`) are listed in words instead: "Hermes always allowed: recursive delete. harness asks for every shell command unless a rule allows it." |
| `model`, `providers`, `custom_providers` | `[model]` and `[provider NAME]` | A provider that's one of harness's presets (anthropic, openrouter, openai, opencode, omnigate) maps by name. An OpenAI- or Anthropic-format custom endpoint becomes a `[provider NAME]` section with `api` and `url`. Anything else is listed. The keys are listed as `harness secret add` lines. The import doesn't change `[model]` when harness already has a provider set; it lists the difference instead. |
| `.env` and secret values in `config.yaml` | nothing copied | Key names fill in the `harness secret add` lines. Values are held in memory for one purpose: so the scrubber can mask them wherever they turn up in memory text, prompts or skills. They are never kept past the import, printed or written. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS` | not imported | The plan explains: one bot can't be read by two agents at once. Make a new bot for harness, or stop Hermes's gateway and add the token with `harness secret add`. Pair with `/pair` as usual. |
| Sessions, `state.db`, external memory, plugins, pairing, kanban, plans, skins, `workspace/` | not imported | Each is named in the report, with its path. |
| `skills.external_dirs` | listed | The owner can point harness at the same folders if they want (named in the report, never added on their own). |
| `skills.config` | listed | Settings for individual skills. harness has no such store, so the values are shown in the report. |

### Scheduled jobs

Each job in `jobs.json` becomes a section in `tasks.ini`, as follows:

- **Name:** the job's `name`, made into a valid section name. A clash
  gets `-hermes`, then a number.
- **Instructions:** `prompt` comes over whole, never cut and never joined
  into one line.
  - A prompt `tasks.ini` holds as it is becomes `do`. That means one line
    with no ` ;` or ` #`, which `tasks.ini` treats as the start of a
    comment, and no leading or trailing space.
  - Any other prompt goes to its own file, `tasks/NAME.md`, and the
    section says `do_file = NAME.md`. `do_file` is new.
  - The `tasks/` folder is guarded like `workflows/`, since it changes
    what runs unattended.
  - Attached `skills` start the instructions: "Use the skills a and b."
    The skills come over too, if they're among the user skills.
- **Schedule:**
  - an interval of 5 minutes or more becomes `every`, in minutes or
    hours;
  - a cron `expr` that says only "at TIME on DAYS" becomes `at` plus
    `days`;
  - `0 */N * * *` becomes `every = Nh`. The plan notes that harness's
    `every` isn't aligned to the clock hour, and varies by up to 10%;
  - anything else (other cron forms, an interval under 5 minutes, a
    `once` job) isn't imported. The plan shows it with its prompt and the
    reason.
- **Time zone:** harness has one fixed `utc_offset`; Hermes has an IANA
  zone, globally and per job.
  - An `at` time is taken in the job's zone, at that zone's offset on the
    day of the import.
  - When that offset isn't harness's, the time is converted, and the plan
    says so.
  - The plan always notes that harness's offset doesn't follow daylight
    saving. That's harness's existing limit, added to the gaps list, not
    fixed here.
- **Delivery:**
  - These go to the main conversation: `origin`, the home channels,
    `telegram`, `telegram:CHAT[:THREAD]`, and a list (`all`, or
    comma-joined) that includes one of them. The plan notes a chat or
    thread it couldn't keep.
  - A job delivered only where harness can't reach (`local`, `bot-chat`,
    `room:ID`, other platforms) comes over commented out. `local` meant
    "save, don't send", and harness sends a task's answer. The plan says
    so.
- **Paused jobs** (`enabled: false`) come over commented out.
- **Not carried over, each shown in the plan:**
  - a `repeat` limit (harness's tasks run until removed);
  - a `model`, `provider` or `base_url` pin;
  - `workdir`;
  - `enabled_toolsets`. Hermes's toolsets don't map one-to-one onto
    harness's tools. The owner can add deny rules under `[schedule:NAME]`;
  - `context_from`, `continuity`, `attach_to_session`, `monitor_script`
    and `monitor_url`.
- **`script` or `no_agent` jobs** aren't imported. They run a script
  unattended, and that's for the owner to set up as a trigger by hand.

Scheduled runs are unattended: every question becomes a refusal. So the
plan states once that the imported tasks run with harness's rules, and
that a job which worked in Hermes because a command was always allowed
there will be refused here until the owner adds a rule.

### The plan, the copies, the report

**The plan** has three groups, in this order:

1. **Will import:** a count per kind, then one line per item.
2. **Needs you:** the `harness secret add` lines, the Telegram note, and
   the allow suggestions.
3. **Not imported:** one line per item, with its reason.

Paths are the owner's own. Values are never shown, apart from:

- the memory entries' text and the jobs' prompts, which the owner should
  see;
- any of Hermes's secret values inside them, which the scrubber masks
  using the values read from `.env` and `config.yaml`.

**`--dry-run`** prints the plan and exits 0. With no terminal and no
`--yes`, it prints the plan and exits 2, saying to add `--yes`.

**Before writing**, the import copies every harness file it will change
(`tasks.ini`, `mcp.ini`, `rules`, `config.ini`) into
`state/imports/hermes-TIME/before/`. It then writes each file whole, as
harness does elsewhere.

**After writing**, it leaves the report at `state/imports/hermes-TIME/report.md`:

- the plan, as carried out;
- the ids of the new memory items;
- the names of the new skills, tasks and servers;
- how to undo it: the copies to put back, and `harness memory forget ID`
  for each item.

**Running it again** adds nothing twice: the same memory entries, a skill
with the same hash, and a task with the same name and prompt are each
"already there".

**While `harness run` is running**, the import refuses, as `harness undo`
does, and says to stop it first. Two reasons:

- the running instance numbers memory items from those it has loaded,
  and would write over the imported ones;
- settings changes would wait for `/reload` in any case.

`--dry-run` works while harness runs.

## `harness skill`: installing from agentskills.io sources

### Sources

- **A folder** holding a `SKILL.md`, or a folder of skill folders (`--skill NAME`
  picks one; without it the plan lists them all and installs all).
- **GitHub**: `OWNER/REPO[/PATH][@REF]` or a `https://github.com/...` link.
  - The repo is fetched as a tar.gz from GitHub's codeload, read with
    std's gzip and tar. No `git` is needed.
  - REF defaults to the default branch. It is pinned to the commit the
    archive itself names: the pax global header's comment, and the top
    folder `REPO-COMMIT`. So there's no second host to ask.
  - The archive is read as a stream. Only the files under PATH are kept,
    and the download stops past 50 MB.
  - These are the same names skills.sh lists.
- **A link to a `SKILL.md`** over https. Only that file is fetched; a
  skill with support files needs the repo form, and the plan says so
  when the file refers to others.

Fetching is the owner's command, not the agent's, so it doesn't pass the
gate. It does keep these limits:

- https only, apart from the test override;
- for the skill kept: at most 300 files, 10 MB in all, and harness's own
  limits of 64 KB for `SKILL.md` and 256 KB a file;
- no links, absolute paths or `..` in the archive;
- the executable bit kept for files under `scripts/` on Linux and macOS.

### What `add` shows before asking

Each item on its own line:

- the name and description;
- the source, with the commit or the URL;
- the number of files and their total size;
- the scripts under `scripts/`, each listed;
- `license` and `compatibility`, when given;
- `allowed-tools`, shown as "The skill asks for: … harness's rules decide
  instead.";
- Hermes's `platforms`, when the skill isn't for this system;
- Hermes's `required_environment_variables`, as "This skill expects: … ".
  harness doesn't put secrets into commands' environments, and says
  which settings would.

The full `SKILL.md` is printed by `harness skill show NAME`, and `add`
says so.

**Checks:**

- The name must be valid and match its folder.
- A skill whose `SKILL.md` doesn't read is refused, with the reason
  `skills.zig` gives.
- A name already installed is refused, and `update` is named instead.

### Keeping the source

`skills/.sources` holds one line per skill installed by `add` or the
import: name, source, commit or URL, the hash of its files, and the time.
Skills the agent saved with `skill_save` have no line.

- **`skill update [NAME]`** fetches each source again. It shows the
  changed files, then asks before replacing the skill.
- **A skill edited since it was installed** (its hash differs) isn't
  updated without `--force`. The plan says it was edited.
- **`skill rm NAME`** removes the folder and its line.
- **`skill list`** shows each skill's source, or "saved by the agent".

### Skills and the gate

- An installed skill's instructions reach the model like any skill's. Its
  scripts run only through `shell`, which the gate decides.
- Following the injection design, a skill the owner installed doesn't
  mark the conversation, any more than the owner's workspace files do.
- The injection catalog gains one case, added when both pieces have
  landed: a skill installed from a repo tells the model to send memory
  out. The call is asked, or refused unattended, as any call.

## Small changes this needs elsewhere

- **`mcp.ini`:** `env = NAME=VALUE`, for plain environment values.
  - A name containing TOKEN, KEY, SECRET, PASSWORD or AUTH is refused
    there, with a pointer to `secret =`. So is a value equal to a stored
    secret.
  - The importer sends every `${VAR}` reference, and every value that is
    in `.env`, to `secret =`.
- **`tasks.ini`:** `do_file = NAME.md`, read from the guarded `tasks/`
  folder, whole.
- **`skills.zig`:** a closing `---` fence followed by spaces reads as a
  fence, as Hermes writes it.
- **The help text and README:** the new commands.
- **The gaps list:** harness's `utc_offset` doesn't follow daylight saving.

## Constraints

- Zig 0.17.1, std only.
- YAML: a small reader for the block subset Hermes writes:
  - mappings, sequences, quoted and plain scalars, `|` and `>` blocks, and
    flow lists such as `["-y", "x"]`;
  - only for the keys listed above.

  A part it can't read is listed as "couldn't read config.yaml near line
  N: add by hand", never guessed. The frontmatter reader in `skills.zig`
  may be the place to start.
- `jobs.json` and `lock.json` are read with `std.json`, and unknown fields
  are ignored.
- **Tests use fixture Hermes homes**, one per case:
  - every schedule form;
  - every MCP server shape;
  - literal secrets in `config.yaml`, `.env` and MCP env;
  - categories;
  - bundled and hub skills;
  - a profile;
  - Windows line endings.

  Every test checks that no secret value from the fixture appears in any
  harness file, any output, or the log.
- **`skill add` from GitHub is tested against `harness-fake`,** which
  serves a tar.gz. The codeload base can be overridden for tests, the way
  the smoke points other services at the stand-in. There's one smoke check
  for each command.
- **Windows:**
  - Hermes's home is `%LOCALAPPDATA%\hermes`;
  - joined paths use `sep_str`;
  - a listed dir is opened with `.iterate = true`;
  - there's no executable bit;
  - the tar reader refuses names Windows can't hold (`CON`, `:` and the
    like).
- **Copy follows CLAUDE.md:** plain labels, short lines, no slogans.
- **Docs:** update the gaps list, the ledger and the Windows handoff.

## Left to the builder

- Where the import code lives (e.g. `src/hermes.zig`), and the shared
  pieces with `skill add`.
- The exact plan and report wording, within the shape above.
- How the YAML subset reader is built, and its limits.
- The name test for secret env values, beyond the words listed above.

## Calls I made (the owner can overrule)

- **No secrets are copied.** The import lists `harness secret add` lines
  instead. That's a few more steps for someone switching, but a secret
  never passes through a file the importer wrote.
- **Narrowing comes in, widening doesn't.** `approvals.deny` and excluded
  tools become deny rules. `command_allowlist` becomes a suggestions file.
  `allowed-tools` is ignored.
- **The Telegram bot isn't moved.** Two agents can't read one bot, so the
  plan explains the choice.
- **Conversations aren't imported.**
- **`SOUL.md` becomes a pinned memory item** when it fits, rather than
  replacing harness's built-in instructions.
- **Imported memory counts as the agent's words,** and is dated 60 days
  back. It never crowds out what the owner said recently.
- **Hermes's stock `SOUL.md` is skipped.** Only an edited one comes over.
- **The import refuses while `harness run` is running**, as undo does.
- **Prompts that don't fit one `tasks.ini` line go to their own files**
  (`do_file`). They're never squeezed into one line.
- **Time zones:** `at` times are converted at today's offset when the
  zones differ. harness's lack of daylight saving goes on the gaps list.
- **Jobs harness can't deliver** (`local`, other platforms) come over
  commented out.
- **Skill names Hermes allows and harness doesn't** are renamed and shown
  in the plan. Skills over harness's size limits, and disabled ones,
  aren't imported.
- **URL MCP servers with a secret header other than a bearer token**
  come over commented out. `mcp.ini` gets no secret-header key this
  round.
- **Hermes's bundled skills are skipped** unless edited, or the owner
  passes `--bundled`.
- **Skills are installed from the terminal only** this round. A chat
  command can come later.
- **No skill scanner**, consistent with the injection design.
