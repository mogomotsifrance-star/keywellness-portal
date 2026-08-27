# CLAUDE_CONTEXT.md — read this with `CLAUDE.md` at the start of every session

`CLAUDE.md` describes the **financial portal as built**. This file describes the
**operating system being built on top of it**, and the rules that govern that work.
Where the two disagree, the governing documents in `docs/` win — and say so in the
build record.

---

## 1. The governing documents

Four documents govern this programme of work. They live in `docs/` and they are the
source of truth for scope, sequence and shape. Read them before doing anything.

| File | What it settles | Status |
|---|---|---|
| `docs/charter.md` | The 29-seat AI team and its domains, the design directive (§4), design-before-code (§5–§6), the information model, the §17 distinctiveness test. Appendix A carries rev 1's decisions and scope; Appendix C records the chosen design direction | Present (**Rev 2**, 25 Aug 2026) |
| `docs/operating-model.md` | How Key Wellness actually operates today — people, the Tuesday rhythm, the five journeys, the work plan as the spine, the assumptions index A1–A36 | Present (draft 2, 25 Aug 2026) |
| `docs/data-model-and-impact.md` | What exists in Supabase, what changes, migrations M1–M7, their order and risk, the confidentiality boundary | Present (draft 1 + 25 Aug corrections) |
| `docs/design-directions.md` | The four directions explored, the chosen language (§3), the two screens `ops.html` builds first (§4), and the pre-ship checklist (§6) | Present (25 Aug 2026) |

If a task conflicts with these documents, stop and say so rather than resolving it
silently.

### The design authority — settled

**`docs/design-directions.md` §3 (the language) and §4 (the two screens) govern all
`ops.html` work, together with charter rev 2 §4 (the design directive).** Charter
rev 1's §5 design section — bento grid, sand/oatmeal, sage, teal, terracotta — is
**withdrawn**. Do not build to it.

The language in one line: Public Sans throughout; paper `#FBFAF7`, ink `#1C1D1F`,
ink-2 `#4A4C52`, grey `#808185`, rule `#D8D7D3`; Key Wellness green `#397E2B` for
**only** the psychosocial marker and the current position; Key Wellness yellow
`#F0C90A` for **only** "needs a decision". No other colour, no status scale, nothing
red. Three columns (230px · fluid · 340px). Rows separated by 1px rules, never
boxed. Service line is a 9px square — filled green psychosocial, outlined grey
financial — never a pill. No cards, KPI tiles, rounded containers >2px, shadows,
gradients, sidebar shell, heading icons, emoji, or "Welcome back".

**Run the §6 checklist before shipping any ops screen**, including its last
question: would another model produce this screen from the same prompt? If yes,
redesign before delivering.

---

## 2. What is being built

**One platform, two service lines** — Financial Wellbeing (advisors) and
Psychological Wellbeing (counsellors). Not a fork, not a second portal: a
`service_line` dimension across bookings, activities, reports and content.

**`ops.html` is the single staff workspace.** New staff capability is built there
from the start, in the ops design language. The admin functions Lone and Michelle
need migrate into it release by release, and `admin.html` is **retired** when the
last one moves — not maintained in parallel. Its primary user is Lone, not Tshenolo
or France.

**Admins land on `ops.html`, not `admin.html`.** `kwRouteByRole()` offers
`ops` where it used to offer `admin`, and a stored `kw_interface` of `'admin'`
maps forward to `'ops'` so live sessions do not land on the page being retired.
`admin.html` is reachable only from the "Other interfaces" link inside ops.

**Known inconsistency, fixed in Prompt 11:** `admin.html` and `employer.html`
keep their own role switchers, which still point at `admin.html`. They also
still lack the CDN-failure guard that `index.html` and `advisor.html` have —
if jsdelivr fails they render blank with no explanation. Neither is fixed in
Prompt 3; both go when those pages are rebuilt.

**The work plan is the spine.** Per client, per period, a list of activities each
tagged financial or psychosocial, each with a state (planned → scheduled →
delivered → reported → cancelled). Tuesday walks the work plans. Utilisation,
reports, flyers and invoices all hang off it.

### The organisations — know these before writing a test fixture

`organizations` holds **three** rows, and they are not the client list:

| Org | Members | Bookings | Reports | Note |
|---|---|---|---|---|
| **BOPEU** | 2 | — | — | A real client |
| **Sedimosa** | 8 | 7 | — | A real client |
| **Test Co** | 22 | 13 | **all 4 issued** | A test organisation. **Must be excluded from every ops list** |

**Hollard, LEA, Morula Capital Partners and Debswana are real clients that do not yet
exist as organisations** — they appear in reports and prose only. Prompt 6 creates
them through `admin_org_create()` with codes from `admin_org_suggest_code()`, never
raw inserts.

So "the four organisations" is wrong wherever it appears: regression baselines run
over **three organisations and the four issued Test Co report periods**.

Decisions already taken (25 Aug 2026), not open for re-litigation:

- HR sees psychosocial aggregates only, **minimum base 5, always** — no internal
  no-floor view, unlike the financial indicators.
- Psychosocial admin is done by Lone and Michelle. **France keeps admin but must not
  see who booked counselling** — M3 needs an admin split and must recommend the
  mechanism.
- **No Clinical Lead is assigned.** `is_clinical_lead` is false for everyone;
  counselling notes are author-only until one exists, and a risk flag creates a
  content-free action for Lone.
- Invoices are **prepared by the system and handed to accounts by Lone**.
  Nothing is sent automatically, and nothing is sent by hand from inside the
  platform either. **Superseded by M4 as built (26 Aug 2026):** the earlier
  wording said "produced by Laone", which was true of the business and false of
  the system — Laone does not use the platform, has no account, owns nothing
  and uploads nothing. There is no accountant user anywhere in the schema. See
  `docs/build/m4-contracts-workplans-invoices.md` section 2.
- Flyers go to the organisation's HR contact by default.

### Not every client is on retainer — this shapes M4

Recorded 26 Aug 2026, ahead of M4. The pack and the operating model both read
as though every client is on a monthly retainer. **They are not.** Some are
incidental, billed **per session or per engagement**.

- `org_contracts` gains **`contract_kind ('retainer' | 'per_engagement')`**.
- Per-engagement prices are **known in advance**, so each contract carries a
  **rate card**: `format × service_line → amount`. That is part of M4, not a
  later addition.
- **Engagement invoices are created when a per-engagement activity is marked
  `delivered`** — not on the first of the month. The monthly job stays, but it
  only sweeps `contract_kind = 'retainer'`.

Consequences worth seeing now: "retainer position (delivered vs expected)"
means nothing for a per-engagement client, so the Tuesday review's *Retainer*
section needs a second shape; and `contract_position()` from Prompt 5 has to
branch on `contract_kind` rather than assuming a period allowance.

### Three standing rules for applying a migration

Given 27 Aug 2026, after M1 went to live through the Supabase MCP. These are
not guidance; they are the procedure.

**1 · Migrations go through the MCP, to live, one at a time.** Not the SQL
editor by hand. The one exception is rule 3.

**2 · Baseline and prediction BEFORE. Verification AFTER. In that order.**

Before touching anything: save the baseline to
`docs/build/deploy-<date>/NN-<phase>-before.txt`, and write the expected diff
into the migration header — what will change, what will not, what breaks if it
is wrong, how to undo it. *Then* apply. Then diff the result against the saved
baseline and report whether reality matched the prediction.

The reason this is a rule and not a preference: **a description written after
the fact is not verification, it is a restatement.** If the expected diff is
written once the result is already on screen, it can only agree with it, and
the check has proved nothing. M1 is the reference — its header predicted
"every gained mode_split key is withheld, no figure moves", the run produced
exactly that, and the prediction was on paper first.

**3 · M3 goes to a Supabase branch first. Every other migration goes straight
to live.**

Apply M3 on a branch, run the full role x line x command matrix there, and
report it as a plain-language table — "France, psychosocial, SELECT: 0 rows
(was: all rows)" — never as SQL. Merge only once that table has been approved.

M3 is singular because **rollback does not undo the harm.** Every other
migration can be reversed: drop what was created, restore what was overwritten,
and the world is as it was. If M3's policies are wrong and a counselling
booking is read by someone who should not see it, dropping the policy afterwards
does not unread it. There is no rollback for a disclosure.

### Write in plain language, always

Tshenolo reads **what a migration does and what it will change**, not the SQL.
Migration headers, plans and verification reports must be readable on that
basis alone:

- what changes
- what does not
- what breaks if it is wrong
- how to undo it

If a decision genuinely cannot be made without reading SQL, **say so
explicitly.** Do not present the SQL and assume it was read — that is how a
decision gets recorded as approved when nobody actually made it.

### The fixture's `auth.jwt()` is not Supabase's

Recorded 26 Aug 2026, writing the Prompt 6 seed. A second face of "a fixture is
a reconstruction" (section 3.2), and one that bites files meant for the SQL
editor rather than the harness.

`tests/m1-fixture.sql` and `tests/phase0-fixture.sql` define `auth.jwt()` as a
stand-in reading a `test.email` session setting, so a test can act as anyone.
**Supabase's real `auth.jwt()` reads `request.jwt.claim` / `request.jwt.claims`
and knows nothing about `test.email`.**

So a file that authenticates the way live does —

```sql
perform set_config('request.jwt.claims',
                   json_build_object('email', v_admin)::text, true);
```

— is correct on Supabase and **silently unauthenticated against the fixture**,
which reports `is_admin() is false` for an address that is sitting in `admins`.
It is not a bug in either place; the two mechanisms simply do not meet.

Verify files (`*-verify-live.sql`) and seeds use the live mechanism, because
that is where they run. To exercise one locally, give the scratch database the
real shape first:

```sql
create or replace function auth.jwt() returns jsonb
language sql stable as $j$
  select coalesce(
    nullif(current_setting('request.jwt.claim',  true), ''),
    nullif(current_setting('request.jwt.claims', true), ''),
    json_build_object('email', coalesce(current_setting('test.email', true), ''))::text
  )::jsonb
$j$;
```

That form honours both, so the existing suites keep passing.

**And note the shape of the failure.** `is_admin()` is a check on *identity*,
not privilege: being superuser in the SQL editor does not satisfy it, and
`admin_org_create()` raises `not authorised` for the person who owns the
database. Every admin-gated RPC behaves this way.

### No Clinical Lead

Still true, and load-bearing for M3: **`is_clinical_lead` stays false for
everyone.** Counselling notes are author-only until France appoints one, and a
risk flag creates a content-free action for Lone. Do not seed a clinical lead
to make a test pass — invert the test instead.

---

## 3. Rules that apply to every task

### 3.1 The fork check — non-negotiable

Never replace an existing file wholesale. Before touching `admin.html`,
`advisor.html`, `index.html` or `employer.html`, run the diff check and account for
every line it prints:

```bash
git diff origin/dev -- index.html
```

**The version in the build pack is broken on Windows.** This —

```bash
diff <(git show origin/dev:index.html) index.html | grep '^<'
```

— reports **every line of the file**, because the working tree is CRLF and
`git show` emits LF. It is a 100% false positive, so it cannot tell real drift
from none. Use `git diff` above, or normalise first:

```bash
diff <(git show origin/dev:index.html | tr -d '
') <(tr -d '
' < index.html) | grep '^<'
```

These four files are large and hand-maintained — `index.html` is 518 KB,
`admin.html` 246 KB, `advisor.html` 236 KB, `employer.html` 99 KB. A regenerated
file silently drops work.

### 3.1a A function that writes must never appear in a predicate

**PostgreSQL evaluates a volatile function once per row scanned.** A function
that logs, inserts or sends therefore must never appear in a `WHERE` clause,
a `JOIN` condition, a `CHECK`, or any other predicate — it will fire once per
row the planner touches, not once.

```sql
-- WRONG: support_log() runs for every row scanned
select actor from support_actions where id = support_log('lookup','ok');

-- RIGHT: capture the result, then query
v_id := support_log('lookup','ok');
select actor into v_actor from support_actions where id = v_id;
```

**The incident.** `tests/support-tests.sql` had exactly the wrong form. It
wrote one audit row per existing row, tripped the burst rate limit, and made
**four later, unrelated rate-limit assertions fail** — so the visible symptom
pointed at the rate limiter, not at the assertion that caused it. Recorded in
`docs/build/admin-support.md` §5.

The same trap applies to anything with a side effect: a notifier, a counter, a
mailer. If it does something, put it on its own line.

### 3.2 Migration discipline

Every migration is **one idempotent SQL file in the repo root**, named
`supabase_<phase>.sql`, with:

- a rollback in `migrations/rollback-<phase>.sql` that leaves **zero** leftover
  objects, and
- tests in `tests/<phase>-tests.sql` run locally **with RLS enforced** —
  `tests/run-phase0.sh` is the harness and the model to copy.

**Version: PostgreSQL 17.** Production is 17.6.1. Both harnesses now read
`server_version_num` and **exit 1 below 17** rather than passing on the wrong
major. A local 17.6 cluster is installed — binaries in
`C:\Users\Tshenolo M\pgsql17\pgsql\bin`, data in `C:\Users\Tshenolo M\pgdata17`,
listening on `127.0.0.1:5433`. Portable: nothing in PATH, the registry or
Windows services, and deleting those directories removes it.

```bash
export PATH="/c/Users/Tshenolo M/pgsql17/pgsql/bin:$PATH"
pg_ctl -D "C:/Users/Tshenolo M/pgdata17" -o "-p 5433 -h 127.0.0.1" -l "C:/Users/Tshenolo M/pgdata17/pg.log" start
PGUSER=postgres bash tests/run-phase0.sh 127.0.0.1 5433
PGUSER=postgres bash tests/run-m1.sh     127.0.0.1 5433
```

**Three Windows details**, all handled inside the harnesses — do the same in any
new one:

- `PGCLIENTENCODING=UTF8` is exported. Every `.sql` file here is UTF-8, and psql
  on Windows otherwise takes `client_encoding` from the console codepage, which
  re-encodes the em dash in `kw_unit_label()` and fails phase0 `8b` and phase0a
  `9h` with a mojibake label.
- `PGUSER` falls back to `whoami`: `$USER` is empty in Git Bash, and an empty
  `-U` swallows the next argument.
- Connect over TCP. Windows builds have no Unix sockets, so the `-k` socket
  directory in the Linux recipe does not apply.

**A fixture is a reconstruction, not the schema.** The `tests/*-fixture.sql`
files are hand-written stand-ins built from `00-live-schema-snapshot.md` at a
point in time. A green local run proves logic, idempotency and rollback
completeness; it does **not** prove the migration meets the real schema. Close
that at deploy time with a `*-verify-live.sql` before/after diff. For **M3** —
which rewrites the `bookings` RLS policies and carries the confidentiality
boundary — a Supabase branch (a real schema copy) is the right tool and is
budgeted for; see `docs/build/m1-service-line.md` §5.

**Nothing is applied to the live Supabase project by Claude.** Deliver files and a
deploy note; Tshenolo applies through the SQL editor. The project is shared
dev/prod and live.

RLS policies you create or change **must also exist in a repo file**. Nothing lives
only in the Supabase dashboard.

### 3.3 The REVOKE rule (inherited from `CLAUDE.md`, still binding)

Postgres grants `EXECUTE` on every new function to `PUBLIC`. Every `_`-prefixed
`SECURITY DEFINER` helper needs an explicit
`revoke execute ... from public, anon, authenticated;` in the same migration that
creates it. See `CLAUDE.md` → *Roles & Interfaces* for the sweep query; re-run it
after adding any phase.

### 3.4 Browser checks

Extend the existing smoke suites — `tests/smoke-account.js` (95 assertions) and
`tests/smoke-picker.js` (37) — rather than starting a new framework. They drive the
real page in Chromium via Playwright against a stubbed Supabase client, loaded over
`file://`.

```bash
npm install && npm test
```

**When you write a new suite, block the CDN.** Every role page loads supabase-js
from jsdelivr in `<head>`. `addInitScript` installs the stub *before* page scripts,
but the CDN library lands *after* and overwrites `window.supabase` — the page then
builds a real client, finds no session, and redirects to `index.html`, so every
assertion fails with "`window.showTab` is not a function". Both suites now abort
that request:

```js
await page.route('**cdn.jsdelivr.net/npm/@supabase/**', route => route.abort());
```

Without it a suite passes only when the network happens to be down. Chart.js is
left reachable — the pages degrade without it and nothing asserts on a canvas.

### 3.5 Build records

Finish every phase with `docs/build/<phase>.md`: what was built, decisions, what the
tests prove, what is **not** done, deploy order. Existing records are in
`docs/build/`; the long-running chronological log stays at `BUILD-NOTES.md`.

---

## 4. Migration sequence

From `docs/data-model-and-impact.md` §4, as scheduled in the build pack:

| # | Migration | Risk | Note |
|---|---|---|---|
| M1 | `service_line` + `session_format` columns; backfill `'financial'` | Low | Additive, defaulted, no behaviour change |
| M5 | `meetings`, `actions`, reminders via `notifications` | Low | Ships early — it is what fixes "nobody records Tuesday" |
| M4 | `org_contracts`, `org_contacts`, `work_plans`, `work_plan_activities`, `invoices` | Medium | Extends `program_activities`; `org_report_data()` must count identically |
| M3 | `counsellors`, notes, themes; **rewrite the `bookings` select policy by service line** | **High** | The confidentiality boundary. Tests prove it or it does not ship |
| M2 | Reporting RPCs gain `p_service_line default 'financial'` | Low–Medium | New overloads; old signatures unchanged. Check for positional call sites |
| M6 | `topics`, `topic_tips`, `flyers`, `flyer_sends` | Low schema | The renderer is the work |
| M7 | `practitioner_availability`, capacity ceilings | Low | |

M5 before M3 because the action ledger needs no confidentiality machinery.
M3 before M2 because psychosocial figures must never reach a report before the
row-level boundary is proven.

---

## 5. Before you start: two reference files

**`docs/build/00-live-schema-snapshot.md`** — the live database as of 25 Aug 2026:
38 tables with columns and row counts, 111 functions with signatures and ACLs, all
77 RLS policies with predicates, triggers, extensions. Re-runnable read-only from
`tests/live-schema-snapshot.sql`. Its §10 says which repo SQL files are actually
applied, and its §11 lists four things that change the build:

- production is **PostgreSQL 17.6**, the tests target 16;
- **`pg_cron` is not installed** — M5's reminders and M4's invoice rows need a
  decision, not a preference;
- `tests/phase0-fixture.sql` defines `bookings` with 10 columns where live has 24,
  **missing both columns M1 migrates**;
- **permissive RLS policies OR together**, so M3 cannot exclude France from
  psychosocial rows by rewriting one policy — `bookings_admin` and
  `bookings_admin_all` must be *replaced*, in the same transaction.

**`docs/build/00-codebase-map.md`** — every page, every SQL file, every test suite,
and the fourteen points where the repo contradicted the governing documents, with
what happened to each.
