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
- Invoices are **prepared by the system, produced by Laone**. Nothing is sent
  automatically.
- Flyers go to the organisation's HR contact by default.

---

## 3. Rules that apply to every task

### 3.1 The fork check — non-negotiable

Never replace an existing file wholesale. Before touching `admin.html`,
`advisor.html`, `index.html` or `employer.html`, run the diff check and account for
every line it prints:

```bash
diff <(git show origin/dev:index.html) index.html | grep '^<'
```

These four files are large and hand-maintained — `index.html` is 518 KB,
`admin.html` 246 KB, `advisor.html` 236 KB, `employer.html` 99 KB. A regenerated
file silently drops work.

### 3.2 Migration discipline

Every migration is **one idempotent SQL file in the repo root**, named
`supabase_<phase>.sql`, with:

- a rollback in `migrations/rollback-<phase>.sql` that leaves **zero** leftover
  objects, and
- tests in `tests/<phase>-tests.sql` run locally against **PostgreSQL 16 with RLS
  enforced** — `tests/run-phase0.sh` is the harness and the model to copy.

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

Extend the existing smoke suites — `tests/smoke-account.js`, `tests/smoke-picker.js`
— rather than starting a new framework. They drive the real page in Chromium via
Playwright against a stubbed Supabase client, loaded over `file://`.

**Caveat:** there is no `package.json` and Playwright is not installed. The suites
cannot run on a clean clone until that is fixed. See `docs/build/00-codebase-map.md`
§5.

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

## 5. Before you start: read the codebase map

`docs/build/00-codebase-map.md` inventories every page, every SQL file, every test
suite, and — importantly — **lists where the repo contradicts
`docs/data-model-and-impact.md`**. Several of those contradictions change what a
task should do. Read it.
