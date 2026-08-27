# 00 — Codebase map

**Produced 25 Aug 2026 on `dev` @ `b5f72c5`, for Prompt 0 of the operating-system
build pack.** Read-only survey: nothing in the repo was changed to produce it, and
nothing was read from or written to the live Supabase project.

Its job is threefold: say what every file in this repo is for, say whether each SQL
file has been applied, and — the part that changes what later prompts should do —
**list where the repo contradicts `docs/data-model-and-impact.md`**. Section 6 is
the one to read if you read only one.

---

## 1. How to read the "applied?" column

> **Superseded by [`00-live-schema-snapshot.md`](00-live-schema-snapshot.md) §10.**
> That file was taken read-only against the live project on 25 Aug 2026 and states
> per-file fact rather than inference. Where the two disagree, the snapshot wins.
> The graded scale below is kept because it records how the survey was done before
> live access, and because the snapshot's §10 uses the same vocabulary.

The repo has **no migration ledger**. Migrations are applied by hand in the Supabase
SQL editor against a shared dev/prod project; nothing records which ran or when.
There is no `supabase/migrations/` directory and no `schema_migrations` equivalent.

So "applied?" here is an **inference**, graded:

| Grade | Means |
|---|---|
| **live** | An object it creates is named in `docs/data-model-and-impact.md`'s live inventory, or `CLAUDE.md` / `BUILD-NOTES.md` records the apply explicitly |
| **live (superseded)** | Was applied, but a later file replaced its functions; the file is kept for history |
| **likely** | The feature is live on the site and this is the only file that creates it, but no direct record |
| **read-only** | A diagnostic or verification script — never "applied" in the migration sense |
| **unknown** | Cannot be determined from the repo |

**This is the single biggest gap in the repo** and it is worth fixing before M1
lands — see §6, C5.

---

## 2. Pages

### 2.1 The four role interfaces

| File | Size | Role | Notes |
|---|---|---|---|
| `index.html` | 518 KB | Member portal + **the auth entry point for everyone** | Holds `kwRouteByRole()`, `kwAvailableInterfaces()`, `kwGetInterface()`/`kwSetInterface()`, `kwShowInterfaceChooser()`, `kwRenderRoleSwitcher()`. Every staff role signs in here and is routed out. Prompt 3 changes this file |
| `admin.html` | 246 KB | Key Wellness admin | Organisations, units and sites, departments, roles and access, advisor roster, attribution queue, the account file, report publishing, headcount, thresholds. **Being retired screen by screen into `ops.html`** |
| `advisor.html` | 236 KB | Advisor portal | Caseload, consultation assessments, session diary, team-lead views |
| `employer.html` | 99 KB | HR / employer dashboard | Aggregate org reporting, unit-scoped |
| `ops.html` | — | **Does not exist yet.** The single staff workspace, built from Prompt 3 |

All four are subject to the fork check in `CLAUDE_CONTEXT.md` §3.1.

### 2.2 Assessment and booking

| File | Size | Role |
|---|---|---|
| `wellness_assessment.html` | 101 KB | 8-dimension financial wellness assessment |
| `booking_form_v2.html` | 34 KB | Standalone "Book a Session" form. **Not listed in `CLAUDE.md`'s file structure.** Touches `bookings` — relevant to M1's `session_type` / `session_format` cleanup |

### 2.3 Standalone tool pages

Thirteen are listed in `CLAUDE.md`; **three more exist that are not**:

| File | Size | In `CLAUDE.md`? |
|---|---|---|
| `budget_planner.html` | 86 KB | yes |
| `goal_planner.html` | 64 KB | yes |
| `debt_management_planner.html` | 56 KB | yes |
| `financial_stress_tracker.html` | 57 KB | yes |
| `dti_calculator.html` | 56 KB | yes |
| `expense_tracker.html` | 50 KB | yes |
| `retirement_calculator.html` | 43 KB | yes |
| `loan_calculator.html` | 36 KB | yes |
| `rent_vs_buy.html` | 34 KB | yes |
| `affordability_calculator.html` | 30 KB | yes |
| `investment_calculator.html` | 24 KB | yes |
| `net_worth_tracker.html` | 19 KB | yes |
| `life_insurance_calculator.html` | 44 KB | **no** |
| `lifestyle_inflation_calculator.html` | 40 KB | **no** |
| `education_savings_calculator.html` | 40 KB | **no** |

### 2.4 Internal / review

| File | Role |
|---|---|
| `kw-lesson-posters-review.html` | Internal LMS lesson-poster review page. Not part of any role interface |

---

## 3. Shared front-end assets

| Path | Role |
|---|---|
| `css/kw-theme.css` | The design tokens `CLAUDE.md` documents (navy/gold/cream). **This is the financial-portal language, not the ops language** |
| `css/kw-pathways.css` | Learning Pathways styling |
| `js/kw-reveal.js` | Scroll-reveal |
| `js/kw-lms-posters.js`, `js/kw-lms-thumbs.js` | LMS poster / thumbnail rendering |
| `js/certificate-template.js` | Certificate rendering |
| `kw-badges.js` | Badge definitions and award logic |
| `kw-profile-sync.js` | Profile sync between pages |
| `kw-report-charts.js` | Chart.js wrappers for HR reporting |
| `browser_rls_test.js` | Ad-hoc in-browser RLS probe |
| `assets/img/` | `kw-logo-horizontal.{png,svg}`, `kw-icon.{png,svg}`, `sedimosa-logo.png`, `pathways/` |
| `assets/fonts/`, `assets/certificates/` | Certificate assets |
| `email-templates/auth/` | Supabase Auth email templates |

**Note for Prompt 3:** there is no shared JS module for the Supabase client, auth or
the role probe — each page constructs its own. `ops.html` will need a deliberate
answer to this (the prompt asks for one) because copying `index.html`'s boot
sequence a fifth time is how the fork hazard spreads.

---

## 4. Supabase SQL — all 79 root files

Grouped by feature stream, newest stream last. Tables created by each file are
named where it creates any.

### 4.1 Multi-tenancy and organisations

| File | Creates | Applied? |
|---|---|---|
| `supabase_multitenancy.sql` | `organizations`, `employers` | **live** — `organizations` = 3 rows |
| `supabase_fix_employers_pk.sql` | — | **live** |
| `supabase_employer_email.sql` | — | **live** |
| `supabase_employer_dashboard.sql` | — | **live (superseded)** by the `org_overview` chain |
| `supabase_org_overview_fix.sql` | — | **live (superseded)** |
| `supabase_org_overview_scoped.sql` | — | **live** |
| `supabase_fix_org_overview_authz.sql` | — | **live** |
| `supabase_seed_test_org.sql` | — | **likely** (seed) |
| `supabase_verify.sql` | — | **read-only** |

### 4.2 Company units and departments

| File | Creates | Applied? |
|---|---|---|
| `supabase_org_units.sql` | `org_units`, `hr_unit_scope` | **live** — `org_units` = 11 rows |
| `supabase_org_units_hr_scope.sql` | — | **live** |
| `supabase_verify_org_units.sql` | — | **read-only** |
| `supabase_sedimosa_phase2_batch1.sql` | `unit_departments`, `notifications`, `webinar_views` | **live** — `unit_departments` = 161 rows |
| `supabase_verify_invite_code.sql` | — | **live** |

### 4.3 HR reporting — the `org_report_data()` chain

**Five versions of the same function live in the repo.** M2 must know which is
current. See §6, C6.

| File | Applied? |
|---|---|
| `supabase_org_reports.sql` (`org_reports` table) | **live** — 4 rows |
| `supabase_program_activities.sql` (`program_activities` table) | **live** — 1 row |
| `supabase_publish_org_report.sql` | **live** |
| `supabase_org_report_data.sql` (v1) | **live (superseded)** |
| `supabase_org_report_data_v2.sql` | **live (superseded)** |
| `supabase_org_report_data_v3.sql` | **live (superseded)** |
| `supabase_org_report_data_v4.sql` | **live (superseded)** |
| `supabase_org_report_data_v5_departments.sql` | **live** — the current version, additive over v4 |
| `supabase_suppress_count_bigint_fix.sql` | **live** |
| `supabase_org_stress_summary.sql` | **live** |
| `supabase_financial_indicators.sql` | **live** |
| `supabase_live_wellness.sql` | **live** |
| `supabase_utilisation_rpcs.sql` | **live** |

### 4.4 Rewards, points, thresholds

| File | Creates | Applied? |
|---|---|---|
| `supabase_points_ledger.sql` | `points_catalog`, `points_events` | **live** |
| `supabase_points_integrity_fix.sql` | — | **live** |
| `supabase_rewards_categories.sql` | — | **live** |
| `supabase_reward_thresholds.sql` | `reward_thresholds` | **live** |
| `supabase_rewards_reshape.sql` | `reward_fulfilments`, `org_headcount_reports` | **live** |
| `supabase_reward_fulfilment.sql` | `reward_fulfilments` | **live** |
| `supabase_my_reward_fulfilments.sql` | — | **live** |
| `supabase_org_headcount.sql` | `org_headcount_reports` | **live** |
| `supabase_org_rewards_v2.sql` | — | **live** |
| `supabase_org_rewards_stress_scoped.sql` | — | **live** |
| `supabase_leaderboard.sql` | — | **live (superseded)** — leaderboard removed by product decision |
| `supabase_leaderboard_optin.sql` | — | **live (superseded)** |
| `supabase_drop_leaderboard.sql` | — | **live** — the removal |

### 4.5 Learning Pathways (LMS)

| File | Creates | Applied? |
|---|---|---|
| `supabase_lms_storage.sql` | — (`Videos` bucket) | **live** |
| `supabase_lms_schema.sql` | `pathways`, `content_items`, `content_progress`, `quizzes`, `quiz_questions`, `quiz_attempts`, `certificates` | **live** — `content_items` holds the 10 webinar rows |
| `supabase_lms_rpcs.sql` | — | **live** |
| `supabase_lms_pathway1_update.sql` | — | **live** |
| `supabase_lms_pathway2_seed.sql` · `..._quiz_seed.sql` · `..._activate.sql` | — | **live** |
| `supabase_lms_pathway3_seed.sql` · `..._quiz_seed.sql` · `..._activate.sql` | — | **live** |
| `supabase_learn_intro_video.sql` | — | **live** |

### 4.6 Webinars and thresholds

| File | Creates | Applied? |
|---|---|---|
| `supabase_webinars_thresholds_schema.sql` | `threshold_config`, `tool_usage_events`, `video_watch_progress`, `video_watch_credits` | **live** |
| `supabase_webinar_learning_rpcs.sql` | — | **live** |
| `supabase_webinar_thumbnails.sql` | — | **live** |

### 4.7 Advisor portal

| File | Creates | Applied? |
|---|---|---|
| `supabase_advisor_portal.sql` | `advisors`, `advisor_clients`, `advisor_notes` | **live** — also creates 4 `bookings` policies |
| `supabase_advisor_rpcs.sql` | — | **live** |
| `supabase_advisor_team_lead.sql` | — | **live** — re-creates `bookings_advisor_select`, adds `bookings_lead_update` |
| `supabase_advisor_ux.sql` | — | **live** |
| `supabase_fix_france_advisor.sql` | — | **live** |

### 4.8 Admin dashboard RPCs

| File | Applied? |
|---|---|
| `supabase_admin_orgs_rpcs.sql` | **live** |
| `supabase_admin_units_rpcs.sql` | **live** |
| `supabase_admin_depts_rpcs.sql` | **live** |
| `supabase_admin_roles_rpcs.sql` | **live** |
| `supabase_hr_france_sedimosa.sql` | **live** |

### 4.9 Organisation account view (the most recent stream)

| File | Applied? |
|---|---|
| `supabase_org_account_phase0.sql` | **live** — has DB tests + rollback |
| `supabase_org_account_phase0a_picker.sql` | **live** — has DB tests + rollback |
| `supabase_org_account_phase1_indicators.sql` | **live** — has DB tests + rollback |
| `supabase_org_account_phase1a_lock_internal_helpers.sql` | **live** — `CLAUDE.md` records the 2026-08-24 fix |

### 4.10 Ask Key (member AI chat)

| File | Creates | Applied? |
|---|---|---|
| `supabase_ai_chat_usage.sql` | `ai_chat_usage` | **live** — feature live since 2026-08-03 |

### 4.11 Bookings, email, RLS fixes, diagnostics

| File | Applied? |
|---|---|
| `supabase_bookings_missing_columns.sql` | **live** |
| `supabase_booking_notify_payload.sql` | **live** — `CLAUDE.md` records the 2026-08-25 relay fix |
| `supabase_rls_admins_self_read.sql` | **live** — `CLAUDE.md` records `admins_read` scoping |
| `supabase_cleanup_policies.sql` | **unknown** — drops legacy duplicate policies; whether it ran is not recorded |
| `supabase_inspect_policies.sql` | **read-only** |
| `supabase_diagnose_magiclink.sql` | **read-only** |
| `supabase_diagnose_magiclink_logs_explorer.sql` | **read-only** — runs in Logs Explorer, not the SQL editor |

### 4.12 Rollbacks

`migrations/` holds **24 rollback files** and `rollback-notes.md` (21 KB of prose
notes per batch). Coverage is partial: the recent streams (org-account phases,
advisor portal, admin RPCs) have rollbacks; the older streams (LMS pathway seeds,
`org_report_data` v1–v5, multi-tenancy) largely do not.

### 4.13 Edge Functions

| Path | Role |
|---|---|
| `supabase/functions/ask-claude/` | Ask Key member AI chat (`index.ts`, `corpus.ts`, `build-corpus.mjs`) |
| `supabase/functions/send-booking-email/` | Booking confirmation mail |
| `supabase/functions/phone-signup/` | Pseudo-email phone accounts |
| `supabase/functions/_shared/kw-email.ts` | Shared mail helper |

Prompt 4's support function joins these. `supabase/.temp/` is gitignored.

---

## 5. Tests

### 5.1 Database suites — PostgreSQL 16, RLS enforced

| File | Covers |
|---|---|
| `tests/run-phase0.sh` | **The harness.** Creates `kwtest`, loads the fixture, applies phase 0 → 0a → 1 twice each (idempotency), runs each suite, then rolls all three back twice and asserts **zero leftover objects** by counting columns, functions, constraints, triggers and `threshold_config` rows |
| `tests/phase0-fixture.sql` | Local reconstruction of the live schema — `organizations`, `profiles`, `bookings`, `admins`, `assessments`, `emergency_fund`, `stress_logs`, `advisor_clients` and more |
| `tests/phase0-tests.sql` | 47 assertions |
| `tests/phase0a-tests.sql` | Picker assertions |
| `tests/phase1-tests.sql` | Indicator assertions |
| `tests/phase0-verify-live.sql` | Read-only, for the Supabase editor |

This is the discipline every new migration copies. It is genuinely good: idempotency
both ways, and a rollback-cleanliness gate that fails the run.

### 5.2 Browser suites — Playwright/Chromium, stubbed Supabase

| File | Covers |
|---|---|
| `tests/smoke-account.js` (44 KB) | The org account file in the real `admin.html`: drill-in, all four panels, period and site scope, client-safe view. Stubs four RPCs and can fail each independently (`__indFail`, `__repFail`, `__finFail`, `__adminOnly`) |
| `tests/smoke-picker.js` (15 KB) | The advisor add-client org picker in the real `advisor.html` |

Both load the page over `file://` — no dev server needed, and both now abort the
jsdelivr supabase-js request so the stub is not overwritten (see §6, C3). Run them
with `npm install && npm test`.

`smoke-account.js` carries a long comment explaining that an earlier fixture used
plain numbers where `org_report_data()` returns `{value, suppressed}` jsonb, so every
panel assertion passed while the page rendered `[object Object]`. **Copy that lesson
into any new fixture** — and note that the CDN bug is the same class of failure: a
suite that reports success while testing something other than what it claims.

`.claude/static-server.js` exists locally but `.claude/` is gitignored in full, so it
is not available on a clean clone. Neither smoke suite needs it.

---

## 6. Contradictions and gaps

Twelve were found. **Six were resolved the same day** by prompt-pack rev 2, charter
rev 2, the corrected `docs/data-model-and-impact.md` and the supply of
`docs/design-directions.md`. Each entry below keeps the original finding and records
what happened to it — the finding is the evidence, the resolution is the decision.

| | Finding | Status |
|---|---|---|
| C1 | Bookings policies *are* partly in the repo | **Resolved** — data model corrected; Prompt 7 now starts from `supabase_advisor_team_lead.sql:108-123` |
| C2 | `smoke6.js` never existed | **Resolved** — Prompt 3 now builds `tests/smoke-routing.js` fresh |
| C3 | No `package.json`; Playwright unresolvable | **Resolved by Prompt 0b** — Task B adds it |
| C4 | Core tables have no DDL in the repo | **Confirmed serious, then mitigated.** The fixture defines `bookings` with 10 columns; live has 24, and **both columns M1 migrates are missing from it**. Prompt 1 builds the fixture from the snapshot instead (snapshot §11, F3) |
| C5 | Applied state unrecorded | **Resolved** — snapshot §10 states it per file. One file, `supabase_cleanup_policies.sql`, was never applied |
| C6 | Five repo versions of `org_report_data()` | **Resolved** — only **two** overloads are live; the five files are a version history. M2 actually has **eight** signatures to extend (snapshot §5) |
| C7 | "The four organisations" | **Resolved** — three orgs (BOPEU, Sedimosa, Test Co); the four reports are all Test Co's |
| C8 | Design language had no source document | **Resolved** — `docs/design-directions.md` supplied; charter rev 1 §5 withdrawn |
| C9 | Charter §6 vs data model on `session_type` | **Resolved** — charter rev 2 drops the rev-1 sketch |
| C10 | Stale file sizes | **Resolved** — data model now records 246 KB / 518 KB |
| C11 | Charter's Phase A prototype gate skipped | **Accepted deliberately** — pack rev 2 records the choice |
| C12 | `supabase_cleanup_policies.sql` state unknown | **Resolved — it was never applied.** All four duplicate `bookings` policies are still live, predicates captured in snapshot §6 |
| C13 | Data model §2.5 still says "`smoke6.js` extends to guard it" | **Open** — residual staleness; the pack is correct, the doc is not |
| C14 | `docs/build/org-account-phase2b.md` does not exist | **Open** — the preamble's build-record style reference has no referent |

### C1 — "None of the bookings policies are in the repo" is wrong

`docs/data-model-and-impact.md` §2.3, housekeeping paragraph.

**Four bookings policies are in the repo as executable DDL:**
`bookings_advisor_select`, `bookings_advisor_insert`, `bookings_advisor_update`,
`bookings_member_respond` — `supabase_advisor_portal.sql:384–419`. And
`supabase_advisor_team_lead.sql:108–123` re-creates `bookings_advisor_select` (this
is the current definition, the one that grants `is_team_lead()` the read the doc
correctly identifies as the confidentiality problem) and adds `bookings_lead_update`.

What is genuinely absent as executable DDL is the **four legacy policies**:
`bookings_admin`, `bookings_admin_all`, `bookings_own`, `bookings_self`. They exist
only as a **comment inventory** at `supabase_org_account_phase0.sql:656–677`, which
already diagnoses both duplicate pairs and recommends dropping `bookings_admin` and
`bookings_self` "in their own change, with their own rollback".

**Consequence for M3 (Prompt 7):** the policy rewrite starts from
`supabase_advisor_team_lead.sql`'s version, not from nothing. And "capture ALL
bookings policies in the migration file" means capturing four that are already in
version control plus four that are only described in a comment — the second group
needs their live definitions read out of the database first, because the comment
records the predicate in prose, not as SQL.

### C2 — `smoke6.js` does not exist

`docs/data-model-and-impact.md` §2.5 says "`smoke6.js` extends to guard it"
(the counsellor route in `kwRouteByRole()`). Prompt 3 repeats the instruction.

The only smoke suites are `smoke-account.js` and `smoke-picker.js`. `smoke6.js`
appears exactly once in the whole repo — `docs/build/ADVISOR-PORTAL-HANDOVER.md:310`
describes it as "a dedicated regression suite (`smoke6.js`, 12 checks)" — and it was
never committed. **The instruction to extend it has no target.** The routing guard
has to be written new, presumably as `tests/smoke-ops.js` (which Prompt 3 also asks
for).

### C3 — The smoke suites cannot run on a clean clone

There is no `package.json` and no `node_modules`. Both suites `require('playwright')`
and it does not resolve. The build preamble's rule 5 ("extend the existing smoke
suites") assumes a working harness.

**Resolved by Prompt 0b — and it uncovered something worse.** Adding the manifest
made the suites runnable, at which point both *failed*, crashing on
`window.showTab is not a function`.

Cause: every role page loads supabase-js from jsdelivr in `<head>`.
`page.addInitScript()` installs the stub before page scripts run — but the CDN
library lands *after* and overwrites `window.supabase`. The page then builds a real
client against production, finds no session, and redirects to `index.html`. Every
subsequent assertion fails, because the suite is no longer on the page it thinks it
is. Proven by loading `admin.html` twice, once with the CDN reachable and once with
it aborted:

| | `window.supabase` is the stub | lands on | `typeof showTab` |
|---|---|---|---|
| CDN reachable | false | `index.html` | `undefined` |
| CDN blocked | true | `admin.html` | `function` |

So the suites only ever passed **when the network happened to be down**. Both now
abort that one request:

```js
await page.route('**cdn.jsdelivr.net/npm/@supabase/**', route => route.abort());
```

Chart.js is deliberately left reachable — the pages degrade without it and nothing
asserts on a canvas. Verified on a fresh `git clone` → `npm install` → `npm test`:
95 + 37 assertions, zero failures, exit 0. **Any new suite must block the CDN the
same way.**

### C4 — Core tables have no DDL anywhere in the repo

`checkins`, `badges` and `tool_data` have **no `CREATE TABLE` in any file**.
`bookings`, `profiles`, `assessments`, `admins`, `emergency_fund` and `stress_logs`
appear only in `tests/phase0-fixture.sql` — a local reconstruction written for
testing, not authoritative DDL.

**M1 (Prompt 1) alters `bookings`.** The repo contains no baseline definition of the
table it is altering, so the fixture is the only local statement of its shape and it
was never checked against live column-for-column. If the fixture is missing a column
or a constraint, M1's local tests will pass against a table that is not the real one.

### C5 — Applied state is unrecorded, and this blocks the discipline the pack assumes

79 root SQL files, 24 rollbacks, no ledger, manual SQL-editor apply against a shared
dev/prod project. Nothing in the repo says which files ran.

The pack's migration discipline — idempotent file, rollback, local tests, deploy
note — is sound going forward but has no baseline. Recommendation: before M1, run one
read-only inventory against live (tables, functions with argument signatures,
policies) and commit it as `docs/build/00-live-schema-snapshot.md`. Every later
"is this applied?" question then has an answer, and M2's "list every call site"
gains something to check against. This is read-only and does not violate the
no-apply rule.

### C6 — `org_report_data()` exists in five repo versions; M2 must target one

`org_report_data.sql` (v1) → `_v2` → `_v3` → `_v4` → `_v5_departments`. Same pattern
on `org_overview` (base → `_fix` → `_scoped` → `_authz` fix) and `org_rewards`
(`_v2` → `reshape` → `_stress_scoped`).

M2 (Prompt 8) adds `p_service_line` to six reporting RPCs as new overloads, and asks
for a list of every call site in `admin.html`, `employer.html` and `advisor.html`.
That list is only meaningful against the **live** signatures — five superseded repo
versions will produce a wrong answer. Depends on C5 being fixed.

### C7 — "the four organisations" is a mis-transcription; there are three

`docs/data-model-and-impact.md` §2.1 records `organizations` = **3 rows**
("The three orgs are the pilot set") and `org_reports` = **4 rows**. Its §4 M4 row
correctly says "regression test against the **four issued reports'** figures".

The build pack turns this into "identical figures for the **four organisations**" in
**Prompt 1**, and again in **Prompt 5**. That is wrong twice, and it is the
acceptance criterion for M1's regression test. The fixture should capture
before-figures for **three organisations and four issued reports**.

Compounding it: the four clients whose work plans Prompt 6 seeds — BOPEU, Hollard,
LEA, Morula Capital Partners — are **not** the organisations in the database.
`Sedimosa` and `Debswana` are the names that appear throughout the production SQL.
`BOPEU` appears only in test fixtures; `Hollard`, `Morula` and `LEA` appear nowhere
as organisation names. So Prompt 6 will be creating organisations, not just work
plans for existing ones — and Prompt 1's regression baseline is over a different set
of orgs than the ones the Tuesday review will show.

**Resolved.** The three organisations are **BOPEU** (2 members), **Sedimosa**
(8 members, 7 bookings) and **Test Co** (22 members, 13 bookings, **all four issued
reports**). Hollard, LEA, Morula and Debswana do not exist as organisations; Prompt 6
creates them through `admin_org_create()`. Test Co is a test organisation and must be
excluded from every ops list. Prompt 1's baseline is therefore the three orgs plus the
four Test Co report periods — note that the only issued reports belong to the org that
ops screens will hide, which is worth remembering when the regression test is written.

### C8 — The design language has no source document

The build preamble cites "`docs/charter.md` Appendix C" and "the charter's section 4"
for the ops design language. **The charter has no Appendix C**, and its §4 is the
module list. Its only design section, **§5**, prescribes a materially different
system — bento-grid home, oatmeal/sand/stone neutrals, sage psychosocial green, deep
teal-blue financial, terracotta accent — and the preamble explicitly forbids the card
and bento grids that §5 endorses.

`docs/operating-model.md` §5 adds a third pointer: "Card grids are excluded by the
charter §4" — again citing a section that does not say that.

The missing `docs/design-directions.md` is the likely home of the real design
appendix, and Prompt 3 depends on it doubly (it cites "direction C" from it).

**Resolved.** `docs/design-directions.md` supplied, and charter **rev 2** replaces
rev 1 — its §4 is now the design directive, and Appendix C records the chosen
direction (**C · The Round**) with the same language. `docs/design-directions.md` §1
states plainly that charter rev 1 §5 "is withdrawn". The authorities are now charter
rev 2 §4 and `docs/design-directions.md` §3–§4, with the §6 checklist before any
screen ships. `docs/operating-model.md` §5's "card grids are excluded by the charter
§4" is correct against rev 2 (it was wrong against rev 1). Recorded in
`CLAUDE_CONTEXT.md` §1.

### C9 — The charter and the data model disagree on booking fields

`docs/charter.md` §6 lists `bookings.session_type` as the one-on-one/group/webinar
field. `docs/data-model-and-impact.md` §2.3 says the opposite: stop overloading
`session_type`, add `session_format`, and migrate `session_type`'s mode values into
`session_mode`. Prompt 1 follows the data model. The charter §6 sketch is superseded
— it is explicitly labelled "sketch, for Security and Engineering review".

### C10 — `admin.html` is bigger than the doc records, and `index.html` is the real hazard

`docs/data-model-and-impact.md` §2.4 sizes `admin.html` at 205 KB and uses that to
argue the fork hazard. Actual sizes: `admin.html` **246 KB**, `advisor.html` 236 KB,
`employer.html` 99 KB, and `index.html` **518 KB** — more than double `admin.html`.

The conclusion (build `ops.html` as a new page) is right and unaffected. But the
file Prompt 3 actually has to edit is `index.html`, for `kwRouteByRole()` — the
largest and least-protected of the four. It has no smoke suite of its own.

### C11 — The charter's Phase A gate is skipped

`docs/charter.md` §7 phases A–F open with "Design system + clickable HTML prototype
of the ops workspace (all six modules)", gated on Tshenolo approving look, navigation
and module scope, **before** schema work in Phase B.

The build pack starts at M1 (schema) and reaches the first screen at Prompt 3, with
no prototype gate. This may well be deliberate — the pack post-dates the charter and
`docs/data-model-and-impact.md` §5 revises the sequencing decision. Flagging it so
the choice is explicit rather than accidental.

### C12 — `supabase_cleanup_policies.sql` has unknown state

It drops legacy duplicate RLS policies. Whether it was ever run is not recorded, and
it is directly relevant to M3, which must reconcile the duplicate bookings policies.
Resolve it with the C5 inventory.

### C13 — The data model still tells a session to extend `smoke6.js`

`docs/data-model-and-impact.md` §2.5 was not corrected along with §2.1, §2.3 and
§2.4: it still reads "`smoke6.js` extends to guard it". Prompt-pack rev 2 corrects
this (Prompt 3 builds `tests/smoke-routing.js` fresh), but a session reading the
governing document alone will chase a file that does not exist. **Open** — worth a
one-line fix in the doc.

### C14 — The build-record style reference does not exist

The preamble's rule 6 says build records go "in the style of
`docs/build/org-account-phase2b.md`". There is no such file, and no phase2b record
anywhere in the repo or in `BUILD-NOTES.md`. The nearest models are the Sedimosa
batch sections of `BUILD-NOTES.md` and `docs/build/RUNBOOK-SEDIMOSA-PHASE2.md`.
**Open** — the first real build record (M1) will have to establish the template.

---

## 7. What this map could not determine — all now answered

Every item below was open when this map was written and is settled in
[`00-live-schema-snapshot.md`](00-live-schema-snapshot.md):

| Was unknown | Now |
|---|---|
| Which SQL files are applied | Snapshot §10. One was not: `supabase_cleanup_policies.sql` |
| The four legacy `bookings` policy predicates | Snapshot §6, captured verbatim |
| Whether `phase0-fixture.sql` matches live | It does not — 10 columns vs 24 on `bookings` (§11, F3) |
| Live row counts | Snapshot §2, all 38 tables |
| The function inventory | 111 functions with signatures, `SECURITY DEFINER` flag and ACLs (§5) |

The pass also turned up four things nobody had asked about: production runs
**PostgreSQL 17.6** while the tests target 16; **`pg_cron` is not installed**, which
constrains M5 and M4; **permissive policies OR together**, so M3 cannot exclude France
by rewriting one policy; and the `SECURITY DEFINER` sweep returns five rows rather
than the expected zero, one of which touches a table. See snapshot §11.

---

## 8. What changed in the repo for Prompt 0

- All four governing documents added: `docs/charter.md` (**rev 2**),
  `docs/operating-model.md`, `docs/data-model-and-impact.md` (with the 25 Aug
  corrections) and `docs/design-directions.md`. The first pass of this map was
  written against charter rev 1 and the uncorrected data model; §6 records which of
  its findings the revisions resolved.
- `docs/build/` created. Ten build records moved into it with `git mv`, names
  preserved: `ADVISOR-PORTAL-HANDOVER.md`, `AUDIT-REPORT.md`,
  `RUNBOOK-SEDIMOSA-PHASE2.md` and the seven `BATCH-0-*-FINDINGS.md`.
- 23 inbound references to those files rewritten to `docs/build/<name>` across
  `BUILD-NOTES.md`, `CLAUDE.md`, `kw-report-charts.js`,
  `supabase/functions/_shared/kw-email.ts` and eight SQL files. Comment and prose
  lines only — no executable SQL changed.
- `BUILD-NOTES.md` stayed at the root: it is a single 256 KB append-only
  chronological log, not a per-phase record, and does not belong beside
  `docs/build/<phase>.md` files.
- `CLAUDE_CONTEXT.md` created — it did not previously exist.
- This map added.

Nothing committed. Nothing applied to Supabase.
