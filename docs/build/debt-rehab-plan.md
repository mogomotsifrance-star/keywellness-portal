# Debt Rehab Plan — build record

**Status: PLAN, awaiting approval (3 Sep 2026). Nothing built, nothing applied.**

Third view on the advisor portal's Report tab — *Personal Financial Assessment ·
Advance Recommendation · Debt Rehab Plan* — an internal working document for the
advisor. Governing document: `docs/build/debt-rehab-plan-spec.md` (spec v2).
Architecture: the Advance Recommendation's, exactly — **compute decides, the model
describes** — see `docs/build/advance-recommendation.md`.

This file is the plan the prompt asked for. Once approved it becomes the build
record: the sections below are kept, and "what was built / verified / not done"
is appended.

---

## 0. What the research found before planning (read this first)

1. **Olorato Maliko's live record reproduces spec §7 to the cent.** Gross
   P 16,200.00, PAYE P 1,887.50, other deductions P 6,512.50, net P 7,800.00,
   business P 4,500.00 → total income **P 12,300.00**. FNB instalment P 5,500.00
   → DSR **44.72%**. Budget 7,400 / 1,200 / 2,400 / 4,850 → **60.16 / 9.76 /
   19.51 / 39.43%**, spend P 15,850.00, **shortfall P 3,550.00**. Assets
   P 140,000.00 (Audi A3 P 100,000.00 + an empty plot in Kasane P 40,000.00),
   liabilities P 273,000.00 → net worth **−P 133,000.00**. The unit-test fixture
   will be her record, as the AR's fixture is Tumelo's.
2. **Her FNB rate is blank.** So the RENEGOTIATE target *at the captured rate*
   cannot be computed for the worked example; only the 35% cap (P 4,305.00) can.
   Spec §7's "target ≤ P 4,305.00" is consistent with that, and the missing rate
   is a printed gap. Her two motshelo rates are stored as "30" and "25" with no
   period text; the Prepare screen confirms them as per-month, as it does on the
   AR.
3. **There is no Advance Recommendation row on live — for anyone.** The table has
   zero rows; the AR's first live run has still not happened. The "AR of 28 Aug
   2026, P 23,000.00" in spec §7 is a paper document, not a stored row. So the
   worked example must be tested both ways: with a synthetic final AR row
   (cross-reference path) and without one ("size a consolidation via an Advance
   Recommendation" path). Her organisation is Hollard with `offers_advances`
   on, so an AR *can* be generated for her once someone does.
4. **Spec §7's phase bands are prose, not arithmetic.** "DSR 44.72% → high-30s
   band (mid-30s if FNB renegotiation lands)" does not follow from any DSR
   definition on these figures. With the FNB instalment at the 35% cap and
   nothing else changed, DSR is exactly 35.00%; with a P 23,000.00 advance over
   24 months added, DSR *rises* to 52.51% (the AR's own rising-DSR effect:
   unserviced informal debt becomes a cash obligation). §4 of the spec is the
   rule ("computed as scenarios, never free-styled"); §7's bands are replaced by
   the scenario table in §5 below. **Decision needed** — see §9.
5. **Her budget carries no debt repayments.** `debt_min` and `debt_extra` are
   empty while liabilities carry P 5,500.00/month. Spec §4's shortfall (spend −
   income = P 3,550.00) is therefore not the cash position; income − spend −
   debt service is **−P 9,050.00**. The plan prints both and flags the missing
   category as a gap. **Decision needed** — §9.
6. `threshold_config.indicator.dti` says "÷ gross monthly income"; the portal
   and the AR compute on net. Known, pre-existing, not touched here — the plan
   uses the AR's net-based DSR, as spec §1 decides.

---

## 1. Files

| File | What it is |
|---|---|
| `supabase/functions/_shared/kw-finance.ts` | **New.** The shared finance module: rate parser, BURS table, `liveLiabilities()`, `suggestClassification()`, `fmtP`/`fmtPct`, tier constants, income summary, budget grouping. Both Edge Functions import it. |
| `supabase/functions/advance-recommendation/compute.ts` | **Changed.** Loses the moved code, imports it from `_shared`, re-exports the moved names so `index.ts`, `report.ts`, `tests/ar-entry.ts` and the 17-check unit suite import exactly as before. `compute()` itself is untouched. |
| `supabase/functions/debt-rehab-plan/compute-rehab.ts` | **New.** Pure. Every figure, action, band, trigger and gap. |
| `supabase/functions/debt-rehab-plan/report-rehab.ts` | **New.** Pure. Content skeleton + deterministic fallback narrative. |
| `supabase/functions/debt-rehab-plan/index.ts` | **New.** The Edge Function. Same three rules as the AR (caller authenticated; authorisation in the database as the caller; nothing the model says is data). |
| `supabase_debt_rehab_plan.sql` | **New.** One table, five RPCs, one SELECT policy. |
| `migrations/rollback-debt-rehab-plan.sql` | **New.** Drops all of it; leaves timeline notes. |
| `advisor.html` | **Changed.** Third switch option, `DRP` JS block, `drp-*` CSS additions (the `ar-*` document styles are reused). |
| `tests/debt-rehab-plan.test.mjs` | **New.** Unit checks on `compute-rehab.ts`. |
| `tests/drp-entry.ts`, `tests/smoke-rehab.js`, `tests/run-rehab.sh` | **New.** Headless-browser suite, real modules bundled into the page. |
| `tests/rehab-fixture.sql`, `tests/rehab-db-tests.sql`, `tests/run-rehab-db.sh`, `tests/run-rehab-db-pg17.sh` | **New.** RLS-enforced database tests; PG 17.6 runner. |
| `tests/pg17-cluster.sh` | **New.** The throwaway-cluster bootstrap lifted out of `run-advance-db-pg17.sh` so both PG 17 runners share it. `run-advance-db-pg17.sh` becomes a wrapper; its behaviour is unchanged and re-proven. |
| `docs/build/debt-rehab-plan.md` | This file. |

Not touched: `index.html`, `admin.html`, `employer.html`, `ops.html`, any
existing SQL, any existing RLS policy, `advance_recommendations`.

---

## 2. Shared-module extraction — exactly what moves

Out of `advance-recommendation/compute.ts` into `_shared/kw-finance.ts`, **verbatim**:

| Moves | Notes |
|---|---|
| `DSR_GREEN_MAX`, `DSR_AMBER_MAX`, `DISPOSABLE_FLOOR_PCT`, `HIGH_COST_RATE_PA`, `DEFAULT_TERM_MONTHS`, `REPEATED_BORROWING_COUNT` | The tier constants and their neighbours. One source. |
| `FORMAL_HINTS`, `INFORMAL_HINTS`, `suggestClassification()` | The Prepare-screen pre-fill. The Debt Rehab Prepare screen uses the same suggestion, then adds the 35% rule on top (§5.1). |
| `parseRate()`, `liveLiabilities()` | The rate parser and the blank-template filter. |
| `pf()`, `isBlank()`, `round2()`, `fmtP()`, `fmtPct()` | Helpers and formatters. |
| `calcAnnualTax()`, `calcMonthlyPAYE()` | The BURS table. |
| Types `Classification`, `RatePeriod`, `Tier`, `RawLiability`, `Assessment` | `Assessment` gains optional `assets?`, `savings?`, `budgetOtherCustom?` — additive; the AR ignores them. |

**Added to the shared module** (new, used by the rehab compute; the AR does not
call them, so its output cannot change):

| Added | What it does |
|---|---|
| `monthlyIncome(income)` | gross → PAYE → net, spouse, rentals + business + dividends, total. The same seven lines `compute()` runs inline today, extracted so the two functions cannot drift. `compute()` is switched to call it — the 17 checks prove the figures are identical. |
| `budgetCaptured(budget)` | `some value > 0`. The AR's heuristic, named. `compute()` is switched to call it. |
| `budgetGroups(budget)` | Sums the map into needs / wants / savings / other by the category ids of `EXPENSE_GROUPS` in `advisor.html` (`needs`: housing, utilities, food, transport, health, childcare, insurance, debt_min; `wants`: entertain, dining, shopping, personal, subscript, travel; `savings`: emfund, retirement, invest, goals, motshelo, debt_extra; anything else → other, which is where the page puts `custom_id_*` rows). Mirrors the page like `calcAnnualTax()` does — **if `EXPENSE_GROUPS` changes, change this in the same commit.** |

Stays in `advance-recommendation/compute.ts`: `compute()`, `Prep`,
`PrepLiability`, `LiabilityView`, `Computed`. It re-exports every moved name, so
no import outside the two function directories changes.

**Proof required before anything else is built:** `node
tests/advance-recommendation.test.mjs` → 17/17; `tests/run-advance.sh` → 28/28,
zero JS errors; `tests/run-advance-db.sh` → 20/20 and clean double rollback. The
extraction is one commit on its own, so the diff that moves code is separable
from the diff that adds the feature.

Deployment consequence: **the `advance-recommendation` function must be
redeployed (v3)** after the migration, because its imports now cross into
`_shared/`. Supabase bundles `_shared` with each function; Deno and Node 22 both
resolve the relative `.ts` import (Node 22.22 is what ran the AR suite here).

---

## 3. Table DDL

```sql
create table if not exists public.debt_rehab_plans (
  id               uuid        primary key default gen_random_uuid(),
  client_id        uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id       uuid        null references advisors(id) on delete set null,
  created_by       uuid        null references auth.users(id) on delete set null,
  version          int         not null,
  status           text        not null default 'draft' check (status in ('draft','final')),
  input            jsonb       not null,   -- record subset + Prepare confirmations + rehab_context + notes, enough to re-run compute byte-for-byte
  computed         jsonb       not null,   -- every figure, action, band, trigger, gap. Never edited.
  narrative        jsonb       null,       -- model output verbatim + error. Never edited.
  content          jsonb       not null,   -- the document as rendered; advisor edits saved here while draft
  actions          jsonb       not null default '[]'::jsonb,  -- checkable items (phase actions, levers, gaps, triggers), editable while draft
  model            text        null,
  input_tokens     int         null,
  output_tokens    int         null,
  narrative_source text        not null default 'model' check (narrative_source in ('model','fallback')),
  generated_at     timestamptz not null default now(),
  updated_at       timestamptz null,
  finalised_at     timestamptz null,
  finalised_by     uuid        null references auth.users(id) on delete set null,
  unique (client_id, version)
);
create index if not exists debt_rehab_plans_client_idx      on public.debt_rehab_plans (client_id, version desc);
create index if not exists debt_rehab_plans_advisor_day_idx on public.debt_rehab_plans (advisor_id, generated_at);
alter table public.debt_rehab_plans enable row level security;

-- The ONLY policy. Read under the caseload test; no INSERT/UPDATE/DELETE policy.
create policy debt_rehab_plans_read on public.debt_rehab_plans
  for select using (exists (select 1 from advisor_clients ac
                            where ac.id = debt_rehab_plans.client_id
                              and can_manage_advisor(ac.advisor_id)));
```

Nineteen columns, matching `advance_recommendations` position for position
(verified against live: `id … finalised_by`), with one rename: `conditions` →
`actions`, because what is checkable here is a list of actions, not operating
conditions.

The table comment and the migration header both carry, in words: *internal-only
by structure — no member, HR or employer read path exists and none may be
added; the only read is `can_manage_advisor()`.* The migration header follows
the house form: what changes, what does not, what breaks if wrong, how to undo.

---

## 4. RPC signatures

All `security definer`, `set search_path = public`, `revoke … from public,
anon`, `grant … to authenticated`; the gate is `can_manage_advisor()` /
`current_advisor_id()` inside each body — names the CLAUDE.md sweep already
knows, so the sweep stays clean.

```sql
debt_rehab_plan_can_generate()                              returns boolean
  -- 40 per advisor per Gaborone day, counted on debt_rehab_plans (separate from the AR's 40)

debt_rehab_plan_create(p_client_id uuid, p_input jsonb, p_computed jsonb,
                       p_narrative jsonb, p_content jsonb, p_actions jsonb,
                       p_model text, p_input_tokens int, p_output_tokens int,
                       p_narrative_source text default 'model')  returns jsonb
  -- can_manage_advisor(owner); next version; system note on the timeline:
  -- "Debt Rehab Plan v1 generated — RENEGOTIATE 1 · CONSOLIDATE 2 · RETAIN 0; shortfall P 3,550.00."
  -- NO offers_advances gate and no "offered" gate: any client the caller may manage.

debt_rehab_plan_update(p_id uuid, p_content jsonb, p_actions jsonb)  returns void   -- drafts only
debt_rehab_plan_finalise(p_id uuid)                                  returns void   -- idempotent; system note "…v1 marked final."
debt_rehab_plan_discard(p_id uuid)                                   returns void   -- drafts only
```

**List** is the RLS SELECT policy, exactly as the AR lists versions (a plain
`select … where client_id = … order by version desc`). The prompt names a list
RPC; I recommend against one: it would be a sixth `SECURITY DEFINER` function
duplicating the policy the tests already prove. See §9.

**What the Edge Function reads as the caller** (RLS decides, no new grants):
`advisor_clients` (id, advisor_id, first_name, last_name, assessment),
`advisors.full_name` via `current_advisor_id()`, `advisor_client_notes(p_client_id)`,
`advance_recommendations` (latest row for the client — `version, status,
generated_at, computed, conditions, input`), and `threshold_config`
(`indicator.dti`, already readable by the page).

---

## 5. Compute rules, restated (`compute-rehab.ts`)

Pure. No I/O, no `Date.now()`; the generation date comes in on `prep`. Input is
the assessment subset, the Prepare confirmations, `rehab_context` (or null), and
the DTI bands (or null → shared constants).

### 5.1 Per-liability action — suggested by code, confirmed on Prepare

Suggestion, in this order, over `liveLiabilities()`:

1. **CONSOLIDATE** if `suggestClassification()` says informal (lender hints,
   monthly period, or ≥ 20% p.a. equivalent).
2. else **RENEGOTIATE** if `instalment > lending_norm% × total income` — 35% from
   `threshold_config` (the `manageable` band's ceiling, what `kwLendingNorm()`
   reads), falling back to `DSR_GREEN_MAX`.
3. else **RETAIN**.

What the advisor confirms is what is computed and stored (`input.prep`). A
Prepare row is `{ index, action, rate_period, months_remaining, extension_months }`.
`action` doubles as the classification: CONSOLIDATE ⇔ informal/high-cost.

**RENEGOTIATE target.** `cap = round2(norm% × income)` — P 4,305.00 for Olorato.
When the rate and a remaining term are known, the payment at the extended term
is `PMT(rate/12, months_remaining + extension, balance)` (rate converted to
p.a. when the period is monthly; `months_remaining` defaults to NPER from
balance, rate and instalment when solvable, else blank → gap; `extension`
defaults to 24). Printed as a band:

- payment at extended term ≤ cap → "**P <pmt> – P <cap>** over <n> months";
- payment at extended term > cap → "≤ P <cap>; a <n>-month extension alone
  reaches only P <pmt> — a longer term or a rate change is needed";
- rate not captured (the worked example) → "**≤ P 4,305.00**" and the gap
  *"Interest rate not captured for Personal Loan – FNB: the term needed to reach
  the 35% line cannot be computed"*.

**CONSOLIDATE source.** If `rehab_context` carries a **final** AR with an advance,
its amount, term, instalment and date are the consolidation figures — copied,
never re-derived. A draft AR is named as pending, not used. No AR, or an AR with
no advance → no amount anywhere; the Phase 1 action is *"Size a consolidation
through an Advance Recommendation"* and the informal balances stay outstanding
in every scenario. (Strict reading of the prompt's "never invents an amount" —
§9 asks whether an explicitly labelled illustrative sizing is wanted instead.)

**REFER — plan level.** Headline action becomes referral to formal debt
counselling when either: DSR after every lever (consolidation settled at its
instalment, renegotiation at cap, budget corrected) still `> DSR_AMBER_MAX`; or
`informal_count ≥ 3` and there is nothing to consolidate them with — no final AR
advance, and no included asset or savings balance that covers the informal
total.

### 5.2 Budget correction

`captured = budgetCaptured()`. Not captured → the single action *"Capture the
household budget"* and no numeric target prints. Captured:

| Group | Target | Cut printed |
|---|---|---|
| needs | 50% of income | `max(0, needs − 0.5 × income)` |
| wants | 30% | `max(0, wants − 0.3 × income)` |
| savings | 20% | none — under target is reported as *"saving P X below the 20% line"*, not cut |
| other | none | the residual: `min(other, max(0, shortfall − needs_cut − wants_cut))`, labelled *"not a 50/30/20 group; every Pula here is discretionary until named"* |

`shortfall = spend − income`; positive → the plan's single most urgent item.
**Also computed:** `debt_service_in_budget = debt_min + debt_extra`; when that is
0 and debt service > 0, the gap *"Budget carries no debt repayments while
liabilities carry P 5,500.00 per month"* prints and `all_in_shortfall = spend +
debt service − income` (P 9,050.00) prints beside the spec's shortfall. Motshelo:
when `budget.motshelo > 0` and an informal liability's institution matches
`/motshelo|metshelo/`, a fixed sentence says the P 2,400.00 sitting under
Savings is debt service, not saving.

Olorato: cuts needs P 1,250.00, wants none, savings P 60.00 under target, other
residual P 2,300.00; shortfall P 3,550.00.

### 5.3 Levers

- **Assets:** every row with `status = 'Personal Use'`, `monthlyIncome = 0`,
  `potentialIncome = 0` is a candidate; the advisor unticks on Prepare
  (`prep.assets = [{ index, include }]`). Each included asset prints value,
  coverage of the informal total (`value ÷ informal_total`, "4.35×") and
  whether it settles them outright. Olorato: Audi A3 (4.35×) and the Kasane
  plot (1.74×) are both candidates; the human decides.
- **Savings:** rows with `currentBalance > 0`, matched greedily largest-first
  against informal balances → *"P X at Y would settle Z outright"*. None → gap
  *"Savings balances not captured"* (Olorato: two motshelo contributions, both
  with balance 0).
- **Income concentration:** `spouse_income = 0` → single earner; business share
  of total income printed (36.59%); "declining" comes only from the notes, and
  only the model may say it.

### 5.4 Phase trajectory — scenarios, not prose

All DSR = debt service ÷ total income, as the AR. Each phase carries a
`{ low, high, assumptions[] }` band and 1–2 actions.

| Phase | Debt service in the scenario | Olorato, no final AR | Olorato, with a final AR (P 23,000 / 24 mo) |
|---|---|---|---|
| 1 (0–3 mo) | formal instalments as captured, consolidated instalments replaced by the advance instalment (if a final AR), lever settlements not yet realised | **44.72%** | **52.51%** — stated plainly: the advance turns unserviced informal debt into P 958.33/month |
| 2 (3–12 mo) | low = renegotiation at cap **and** included levers realised (advance / informal settled); high = neither | **35.00 – 44.72%** | **35.00 – 52.51%** (42.79% if renegotiation lands but the Audi is unsold) |
| 3 (12–24 mo) | exit criteria: DSR ≤ `DSR_GREEN_MAX` and surplus > 0 — printed as what must be true | FNB ≤ P 4,305.00 · spend ≤ P 12,300.00 · debt repayments inside the budget | as left, plus the advance cleared |

Surplus per phase = income − (spend − cuts applied) − debt service not in the
budget. Phase 2 for Olorato closes the P 3,550.00 shortfall to P 0.00 and leaves
the P 5,500.00 outside the budget — which is why the "debt repayments inside the
budget" criterion is on the Phase 3 list.

### 5.5 Review triggers — assembled from facts, 3 to 5, in this priority

1. New informal borrowing (always).
2. A missed advance / consolidation instalment (when a final AR advance exists).
3. An included lever asset unsold at **60 days** (one line per asset).
4. Total income falling by more than 10% (P 1,230.00) — or, when business
   income > 0, business income falling below its captured figure.
5. DSR not below the Phase 2 band's upper bound at the month-3 checkpoint.

### 5.6 Gaps

Rate not captured (per liability); balance not captured; savings balances not
captured; budget not captured; budget carries no debt repayments; months
remaining not set for a RENEGOTIATE facility; no Advance Recommendation to size
a consolidation. Every gap prints in the document and becomes an `actions` row
in group `gap`.

### 5.7 What the Edge Function derives (spec §3) — as the caller

Age, marital status + regime, dependants from `personal` / `kids`; employer from
the organisation name (fallback `personal.employer`); the **name never enters
the model payload** — `content.meta.client_name` comes from the record. Income
via `monthlyIncome()`. Liabilities, assets, savings, budget as above. Advisor
context: the five Diagnostics notes (each clamped to 600 chars) plus the latest
five timeline notes with `origin != 'system'` (300 chars each) — 4,500 chars
maximum, labelled as context, never as instruction. `rehab_context` from the
latest `advance_recommendations` row; the seed for Prepare's `rate_period` and
action comes from that row's `input.prep.liabilities` **only when the live
liability list still matches it by count and institution**, otherwise from the
suggestion. Generation date = Gaborone today, as the AR. Browser sends
`client_id`, `mode`, `prep` — nothing else.

---

## 6. The model's job (`index.ts`, `report-rehab.ts`)

Same call shape as the AR: `claude-sonnet-4-5`, `temperature 0.2`, cached system
prompt, JSON out, every field clamped, `narrative_source = 'fallback'` with the
deterministic narrative when anything is missing. Payload = formatted strings
only (`fmtP`/`fmtPct`), the per-liability action and target band, the budget
table, levers, phase bands, triggers, gaps, advisor context. Fragments exactly as
spec §5: `root_causes[]` (≤ 3), `debt_lines[]` (one per live liability, matched
by index), `budget_paragraph`, `lever_bullets[]`, `phase_paragraphs[3]`,
`trigger_lines[]`, `closing_sentence`. Hard rules carried verbatim from the AR
prompt, plus: root causes describe behaviour and figures, never character or
motive; the motshelo-under-savings sentence and every number are given, not
inferred.

Fallback narrative: terse, deterministic, built from `computed` — e.g. *"FNB
Personal Loan: RENEGOTIATE — P 5,500.00 is 44.72% of income on its own; the
target is at or below P 4,305.00."*

---

## 7. UI (`advisor.html`)

Fork check before the first edit: `git diff origin/dev -- advisor.html`
(CLAUDE_CONTEXT §3.1). Expected removed lines: the `panelReport()` switch block
(rewritten to build the button list from two independent tests) — nothing else.
Every removed line is accounted for in the build record.

- **Offer test**, per spec §2, independent of `offers_advances`: sync —
  `kwDtiBand(calcTotals(c).dti)` ∈ {strained, over_indebted}; async — the
  latest AR row (any status) has a `debt_rehab` condition or support entry on
  (cached per client as `c._rehab`, loaded when the Report tab opens; the button
  appears on re-render). The switch renders PFA + (AR if `offersAdvances`) +
  (Debt Rehab Plan if either test passes). A client who qualifies for neither
  sees the tab exactly as today.
- **`DRP` block** mirrors `AR` function for function (`drpInit`, `drpLoadList`,
  `drpInvoke`, `drpStartPrepare`, `drpSchedulePreview`, `drpGenerate`,
  `drpOnInput`, `drpToggle`, `drpSaveNow`, `drpFinalise`, `drpDiscard`,
  `drpRegenerate`, `drpRender*`). Prepare: per-liability action segment
  (Retain / Consolidate / Renegotiate) with the suggestion reason, rate period,
  months remaining + extension for RENEGOTIATE rows, per-asset include
  checkbox, review date (default +30 days), context textarea; live preview strip
  (DSR now · Phase 2 band · shortfall · headline). Regenerate seeds from the
  previous version's `input.prep`.
- **Document**: the ten spec §6 sections, `ar-doc` styling reused; new
  `drp-top` banner — red, uppercase: *CONFIDENTIAL — INTERNAL DEBT REHAB PLAN
  (Key Wellness use only — not for distribution to employer or employee)* — on
  screen and in print; phase blocks with the band and checkable actions;
  Consultant Notes verbatim, labelled with the advisor's name. Currency via the
  page's `fmt()`.
- Print: unticked actions hidden, toolbar/switch hidden, banner kept.

---

## 8. Tests

**Unit — `tests/debt-rehab-plan.test.mjs`** (Node 22, imports the `.ts`
directly like the AR suite):

1. Olorato: income P 12,300.00, PAYE P 1,887.50, DSR 44.72%.
2. FNB → RENEGOTIATE, cap P 4,305.00, band "≤ P 4,305.00", rate gap printed.
3. Motshelo + mother → CONSOLIDATE, 360% / 300% p.a. equivalents.
4. Budget 60.16 / 9.76 / 19.51 / 39.43%, spend P 15,850.00, shortfall
   P 3,550.00, needs cut P 1,250.00, other residual P 2,300.00.
5. No debt repayments in budget → gap + all-in P 9,050.00.
6. Motshelo-under-savings sentence present.
7. Levers: Audi 4.35×, Kasane 1.74×; unticking Kasane drops it; savings gap.
8. Phases, no AR: 44.72 / 35.00–44.72 / exit criteria list.
9. Phases, synthetic final AR P 23,000 over 24: 52.51 / 35.00–52.51 / advance
   cleared on the Phase 3 list; consolidation figures copied, not derived.
10. Draft AR → named as pending, no amount.
11. Triggers: exactly five, in priority order, Audi at 60 days.
12. Headline not REFER; net worth −P 133,000.00.
13. Edge: budget not captured → capture is action one, no targets.
14. Edge: no informal debt → no CONSOLIDATE, no lever coverage line.
15. Edge: ≥ 3 informal lenders, no AR, no lever → plan-level REFER.
16. Edge: savings balance ≥ an informal balance → settles-outright line.
17. Edge: rate "thirty percent" → parses null → "Not captured" + gap.
18. Edge: DSR after every lever still > 45% → REFER.
19. Thresholds from config (norm 40) change the cap; null config → constants.

**Shared module:** the AR's 17 checks unchanged, plus 3 on `budgetGroups()`
(custom ids → other; empty map → not captured; ids match the page's list).

**Browser — `tests/smoke-rehab.js`** (~30 checks, real modules bundled): offer
test on/off both ways · Prepare shows 3 live liabilities with the suggested
actions · toggling Kasane off recomputes · switching FNB to Retain removes the
band · generate → ten sections in order, banner text, client name from the
record · edit saves through `debt_rehab_plan_update` · untick an action → off
and hidden in print · two-step finalise → immutable · regenerate seeds v2 ·
error path surfaces the server message · **the AR view still passes its own 28
checks** · zero JS errors.

**Database — `tests/rehab-db-tests.sql`** (RLS enforced, fixture extends the AR
fixture with an `admins` row, an `employers` row + `employer_org()` stub, and a
member): owner creates/reads · team lead reads and edits the draft · **admin
reads** · another advisor: no rows, create/update refused · **member: sees the
caseload row, zero plans, cannot generate** · **HR/employer user: zero plans,
cannot generate** · finalise stamps, idempotent, then update/discard refused ·
regenerate v2, discard draft only · no anon execute on any
`debt_rehab_plan_*` · policy count is exactly one and it is SELECT · forward
migration twice, rollback twice → zero objects, notes kept. Run on 16 and, via
`run-rehab-db-pg17.sh`, on 17.6.

---

## 9. Decisions needed before building

| # | Question | Recommendation |
|---|---|---|
| 1 | Consolidation with no **final** AR: print nothing (strict) or an illustrative sizing labelled as such? | **Strict.** A number on the page gets acted on; the AR exists to size it. |
| 2 | Phase bands: accept the §5.4 scenario definitions and the Olorato figures they produce (44.72 / 35.00–44.72 / ≤ 35.00; 52.51 / 35.00–52.51 with an advance) in place of §7's "high-30s / mid-30s"? | **Yes.** §7's bands cannot be reproduced; the spec's own §4 says scenarios, never free-styled. |
| 3 | Thresholds: read `threshold_config` (page parity, `kwLendingNorm()`) with the AR constants as fallback, or AR constants only? | **Config with fallback.** The offer test already uses config; a 40% norm in config would otherwise contradict the 35% line on the same screen. |
| 4 | Print the all-in gap (P 9,050.00) beside the spec's shortfall (P 3,550.00) when the budget carries no debt repayments? | **Yes.** Otherwise the most urgent number on the page is wrong by P 5,500.00. |
| 5 | List: RLS SELECT (as the AR) or a sixth RPC? | **RLS SELECT.** |
| 6 | Quota: own 40/day counter or a pool shared with the AR? | **Own counter.** Same shape, no cross-table count. |
| 7 | `months_remaining` on Prepare (NPER default) for RENEGOTIATE rows? | **Yes.** Without it the "term the advisor sets" has no base. |
| 8 | Test fixture: Olorato's real figures under her name (as Tumelo's are), or a pseudonym? | Her name, as the AR does — but this is Tshenolo's call. |
| 9 | First live run of the **AR** is still outstanding (zero rows). Generate Olorato's AR live before the plan's first live run, so the cross-reference path is exercised? | **Yes**, and it is a one-minute job in the portal. |

---

## 10. Deploy note (draft)

1. `supabase_debt_rehab_plan.sql` — via the MCP, one migration, baseline saved
   to `docs/build/deploy-<date>/` first, prediction in the header (the three
   standing rules).
2. Re-run the CLAUDE.md `SECURITY DEFINER` sweep: ten expected rows, no more.
3. `supabase functions deploy advance-recommendation` (**v3 — imports moved**),
   then `supabase functions deploy debt-rehab-plan`. Same `ANTHROPIC_API_KEY`.
4. `advisor.html` to `dev` → confirm the Workers build is green before testing.
5. First live run: Olorato → Report → Debt Rehab Plan → Generate; check
   `narrative_source` and the function log, as the AR note says.

Rollback: `migrations/rollback-debt-rehab-plan.sql`, `supabase functions delete
debt-rehab-plan`, redeploy `advance-recommendation` from the pre-extraction
commit if the shared module must go too, revert `advisor.html`.

---

*Plan written 3 Sep 2026. Build record continues below once approved.*
