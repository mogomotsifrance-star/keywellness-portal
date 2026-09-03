# Debt Rehab Plan — build record

**Status: BUILT, 3 Sep 2026 — files in the repo, nothing applied live.** The plan
in §0–§7 was approved by Tshenolo on 3 Sep on the basis "go with the
recommendations; the prompt's author amends later". §8 records the decisions
taken, §9 the build and its verification, §10 the deploy note, §11 a security
finding made on the way that affects the live project today.
Governing document: `docs/build/debt-rehab-plan-spec.md` (spec v2). Architecture
mirrored from `docs/build/advance-recommendation.md`.

---

## 0. Baseline read before planning

| Checked | Result |
|---|---|
| Branch base | `claude/new-session-eim0oo` reset onto `origin/dev` (58b1b3e). `origin/main` carries nothing `dev` lacks beyond the merge commit. |
| AR unit suite on this machine | `node tests/advance-recommendation.test.mjs` → 17 checks pass (Node 22.22, type-stripping). This is the baseline the shared-module extraction must reproduce. |
| esbuild / Chromium / psql | esbuild 0.28.2 via npx; Chromium at `/opt/pw-browsers/chromium`; psql 16.13 client. PostgreSQL 17 via `tests/run-advance-db-pg17.sh` (npm binaries). |
| Live project | Not reachable from this environment (`*.supabase.co` blocked). Nothing will be applied live by the session; a deploy note is delivered instead. |
| `advisor.html` touch-points | `panelReport()` at ~L3694 (two-button switch, `offers_advances` gate), `AR` state object L3691, `calcTotals()` L4023 (net-based DTI), `kwDtiBand()` L1685, `kwLendingNorm()` L1716, `fmt()` L1181, `EXPENSE_GROUPS` L2718, assets/savings row shapes L2606–2627. |
| AR liabilities shape | `item, institution, loanAmount, interestRate (free text), balance, monthlyInstalment`. **No term field.** This matters for RENEGOTIATE (see §4.2). |

---

## 1. What is built (files)

| File | Purpose |
|---|---|
| `supabase/functions/_shared/kw-finance.ts` | **New.** Everything `compute.ts` has above `compute()` that is not AR-specific — see §3. Both Edge Functions import it. |
| `supabase/functions/advance-recommendation/compute.ts` | Slimmed to `Prep`/`Computed`/`compute()` + AR-only constants; **re-exports** the shared names so `tests/advance-recommendation.test.mjs`, `tests/ar-entry.ts`, `index.ts` and `report.ts` keep their imports unchanged. |
| `supabase/functions/debt-rehab-plan/compute-rehab.ts` | Pure. Per-liability action, budget correction, shortfall, levers, phase bands, triggers, gaps, REFER. No I/O, no `Date.now()`. |
| `supabase/functions/debt-rehab-plan/report-rehab.ts` | Pure. Content skeleton (ten sections of spec §6), checkable actions list, deterministic fallback narrative. Shared with the browser suite via esbuild. |
| `supabase/functions/debt-rehab-plan/index.ts` | Edge Function. Same three rules as the AR (caller authenticated; authorisation in the DB as the caller; nothing the model says is data). Modes `preview` / `generate`. |
| `supabase_debt_rehab_plan.sql` | One table, six RPCs. Migration comment states the internal-only rule. |
| `migrations/rollback-debt-rehab-plan.sql` | Drops all of it. Leaves the timeline notes, as the AR rollback does. |
| `advisor.html` | Third switch option; `DRP` state object + `drp*` functions; a handful of `.drp-*` CSS rules on top of the existing `.ar-*` block. Old `panelReportPFA()` untouched. |
| `tests/debt-rehab-plan.test.mjs` | Unit checks on `compute-rehab.ts` (§6). |
| `tests/drp-entry.ts`, `tests/smoke-rehab.js`, `tests/run-rehab.sh` | Browser suite, same stub pattern as `smoke-advance.js`. |
| `tests/rehab-fixture-extra.sql`, `tests/rehab-db-tests.sql`, `tests/run-rehab-db.sh` | RLS-enforced DB suite on top of `tests/advance-fixture.sql`; the extra fixture adds `employers`, `employer_org()`, an HR user and an admin user. |
| `tests/run-advance-db-pg17.sh` | Gains an optional `SUITE` variable (default: the AR suite) so the same throwaway 17.6 cluster runs the rehab suite. One-line change. |
| `docs/build/debt-rehab-plan.md` | This file. |
| `package.json` | `test:rehab` script; `test` chain gains it. No dependencies added. |

---

## 2. Table DDL and RPC signatures

```sql
-- ============================================================
-- Key Wellness — Debt Rehab Plan (advisor portal, INTERNAL ONLY)
-- ============================================================
-- INTERNAL-ONLY BY STRUCTURE. This table has NO SELECT policy at all:
-- every read goes through debt_rehab_plan_list()/_get(), which are gated
-- on can_manage_advisor(). There is no member policy, no employer/HR
-- policy, and no RPC that an employer role can reach. Do not add any of
-- them. The Advance Recommendation is a document the employer sees; this
-- one never is — the print header says so and the schema enforces it.
-- ============================================================
create table if not exists public.debt_rehab_plans (
  id               uuid        primary key default gen_random_uuid(),
  client_id        uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id       uuid        null references advisors(id) on delete set null,
  created_by       uuid        null references auth.users(id) on delete set null,
  version          int         not null,
  status           text        not null default 'draft' check (status in ('draft','final')),
  input            jsonb       not null,   -- record subset + prep confirmations + rehab_context + note excerpts
  computed         jsonb       not null,   -- every figure, action, band, trigger, gap. Never edited.
  narrative        jsonb       null,       -- model output verbatim + error. Never edited.
  content          jsonb       not null,   -- the document as edited while draft
  actions          jsonb       not null default '[]'::jsonb,  -- checkable items (see note)
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
-- deliberately: no `create policy` for this table, of any kind.
```

Column-for-column with `advance_recommendations`, with one renamed column:
`conditions` → **`actions`**. The AR's checkables are operating conditions; the
rehab plan's are phase actions, lever opt-ins and review triggers. Same shape
(`[{key, label, on, group}]`), same `update` RPC semantics, so the browser code is
a copy with the name changed.

```sql
-- 40 per advisor per Gaborone day, counted on this table only (separate pool
-- from the AR's 40; see §7 Q3).
function debt_rehab_plan_can_generate() returns boolean

-- Store a generated plan as the caller. can_manage_advisor(owner) inside.
-- NO organisation / offers_advances gate. Writes the timeline note
-- 'Debt Rehab Plan v%s generated — %s.' from p_computed->>'headline'.
function debt_rehab_plan_create(
  p_client_id uuid, p_input jsonb, p_computed jsonb, p_narrative jsonb,
  p_content jsonb, p_actions jsonb, p_model text,
  p_input_tokens int, p_output_tokens int, p_narrative_source text default 'model'
) returns jsonb

-- Versions for one client, newest first, same columns the AR list query
-- selects. This is THE read path; there is no policy behind it.
function debt_rehab_plan_list(p_client_id uuid) returns jsonb

-- Drafts only. coalesce() each argument like the AR.
function debt_rehab_plan_update(p_id uuid, p_content jsonb, p_actions jsonb) returns void

-- Idempotent; second timeline note 'Debt Rehab Plan v%s marked final.'
function debt_rehab_plan_finalise(p_id uuid) returns void

-- Drafts only; finals are the audit trail.
function debt_rehab_plan_discard(p_id uuid) returns void
```

Every one: `security definer`, `set search_path = public`,
`revoke execute ... from public, anon; grant execute ... to authenticated;`,
gated inside on `can_manage_advisor()` (names the sweep's regex already knows).
`_list` is the one deviation from the AR, which lists by plain `select` under a
policy: with no policy, a future "HR export" cannot be added by accident with one
`create policy`, and the RLS test can assert `select count(*)` is zero **for the
owner too** — the strongest available proof of "no read path of any kind".

Migration has no SQL dependency on `advance_recommendations`; the AR is read by
the Edge Function as the caller, so the deploy order is still AR first.

---

## 3. Shared-module extraction — exactly what moves

Into `supabase/functions/_shared/kw-finance.ts`, moved verbatim from
`advance-recommendation/compute.ts` (no behaviour change):

| Moves | Why the rehab needs it |
|---|---|
| `DSR_GREEN_MAX`, `DSR_AMBER_MAX`, `DISPOSABLE_FLOOR_PCT` | Phase 3 exit line, REFER line, snapshot tier |
| `HIGH_COST_RATE_PA`, `REPEATED_BORROWING_COUNT` | CONSOLIDATE rule (≥ 20% p.a.), REFER rule (≥ 3 informal lenders) |
| `DEFAULT_TERM_MONTHS` | AR term when `rehab_context` carries an advance without a term |
| `pf`, `isBlank`, `round2`, `fmtP`, `fmtPct` | All formatting/parsing |
| `calcAnnualTax`, `calcMonthlyPAYE` | BURS table → net salary → total income |
| `parseRate` | Free-text rate → value + period |
| `liveLiabilities` | Drops the four blank template rows |
| `suggestClassification`, `FORMAL_HINTS`, `INFORMAL_HINTS` | CONSOLIDATE = informal/high-cost, so the action suggestion builds on the same classification |
| Types `RawLiability`, `Assessment` (extended with `assets?`, `savings?`), `Classification`, `RatePeriod`, `Tier` | Shared contract |
| **New**: `totalIncome(a)` returning `{gross, paye, other, net, spouse, rentals, business, dividends, total}` | The AR inlines this; both need it identically |

Stays in `compute.ts`: `PrepLiability`, `Prep`, `LiabilityView`, `Computed`,
`compute()`. `compute.ts` adds one line:
`export { ...every moved name } from "../_shared/kw-finance.ts"` so nothing that
imports from `compute.ts` changes. Proof required before anything else is built:
`node tests/advance-recommendation.test.mjs` → 17 pass; `tests/run-advance.sh`
→ 28 browser checks pass; `tests/run-advance-db.sh` → 20 pass (untouched by the
extraction, re-run for the record).

Deno resolves `../_shared/kw-finance.ts` (the `send-booking-email` function already
imports `../_shared/kw-email.ts`); Node 22 type-stripping and esbuild both follow
relative `.ts` imports, which is how the AR suites already run.

---

## 4. Compute rules, restated (compute-rehab.ts)

All arithmetic on `total_monthly_income` = net salary + spouse + rentals + business
+ dividends, i.e. what `calcTotals()` shows the advisor. Percentages `round2`.
"Income" below means that figure.

### 4.1 Per-liability action (suggested by code, confirmed on Prepare, stored in `input.prep`)
1. Classification comes from `suggestClassification()` unless the advisor's prep
   overrides it (same as the AR).
2. **CONSOLIDATE** — classification `informal` (hint list, monthly-period rate, or
   ≥ 20% p.a. equivalent).
3. **RENEGOTIATE** — classification `formal` and `instalment / income × 100 > 35`
   (`kwLendingNorm()`, held as a shared constant `LENDING_NORM_PCT = 35` that must
   match `threshold_config.indicator.dti.bands[manageable].max`; see §7 Q5).
4. **RETAIN** — everything else, printed as such.
5. The advisor may set any row to any action. What is confirmed is what is computed.

### 4.2 RENEGOTIATE target
- `cap = round2(income × 35 / 100)` — the 35% line (P 4,305.00 for Olorato).
- The record has no term field, so the remaining term is **derived** when balance,
  rate and instalment are all captured: `n = ceil( −ln(1 − r·B / I) / ln(1 + r) )`
  with `r` = monthly rate (annual ÷ 12 unless period is monthly). Not derivable
  (missing balance or rate, or `r·B ≥ I` i.e. the instalment does not cover
  interest) → gap "Remaining term cannot be derived", advisor enters a term on
  Prepare.
- New term = derived (or entered) + `extension_months` (Prepare field, default 24).
- `amortised = B·r / (1 − (1+r)^−new_term)`. Printed as a band
  `amortised … cap`, labelled "target band, not a promise". If `amortised > cap`
  compute the smallest extension that gets under the cap; if none exists
  (`B·r > cap`, interest alone exceeds the line) say so — that is a REFER input.
- Without a rate: only the cap prints; the rate gap becomes an action.

### 4.3 Consolidation and its vehicle
- `informal_balance` = sum of captured balances of CONSOLIDATE rows; rows with no
  balance are gaps that block sizing (never zero).
- Vehicle, in priority order — the plan states which applies, never invents one:
  1. `rehab_context.advance` from the latest AR **whose decision starts with
     "Proceed"** — amount, term, instalment (= amount ÷ term) cross-referenced with
     its date and version. A declined AR's amount is printed for reference,
     labelled with its decision, and is not a vehicle.
  2. A savings lever: any `savings[]` balance ≥ an individual informal balance →
     "P X at Y would settle Z outright" (largest balance first, each balance used
     once).
  3. An asset lever: candidate assets (below) whose value ≥ remaining informal
     balance.
  4. None → action "Size a consolidation via an Advance Recommendation"; no amount.
- Consolidation adds an instalment only when the vehicle is an advance; a savings
  or asset settlement removes the debt with no new instalment.

### 4.4 Budget correction
- Groups from `EXPENSE_GROUPS` (needs / wants / savings / other; custom "other"
  items included). `captured` = any value > 0.
- Targets: needs ≤ 50%, wants ≤ 30%, savings ≥ 20%. **Other has no 50/30/20
  target**: its cut is the balance of the shortfall after the needs and wants
  cuts, floored at zero — so the printed cuts always sum to the shortfall.
- `shortfall = round2(total spend − income)`; positive → the single most urgent
  item, printed first.
- **All-in cash gap.** The budget's `debt_min` + `debt_extra` lines are compared
  with the liabilities' debt service; when they fall short, the plan also prints
  `cash_gap = shortfall + (debt service − budgeted debt lines)` labelled as the
  gap once loan instalments are counted. Olorato's live budget carries no debt
  line, so her shortfall P 3,550.00 sits beside an all-in gap of P 9,050.00.
  Both figures print; neither replaces the other (§7 Q8).
- Not captured → action one is "Capture the household budget"; no target prints.
- `budget.motshelo > 0` **and** a CONSOLIDATE row whose label matches
  `/motshelo|metshelo|moraka/` → flag "motshelo repayment is debt service, not
  saving" (passed to the model as a fact, printed in section 5).

### 4.5 Levers
- Asset candidates: `status === 'Personal Use'`, `monthlyIncome == 0`,
  `potentialIncome == 0`, `value > 0`. Each is on by default; the advisor unticks
  off-limits ones on Prepare (`prep.levers[{asset_index, on}]`). Coverage printed
  as a multiple of the informal balance (AUDI: 4.35×).
- Savings matches per 4.3 (2).
- Income concentration: `spouse_income == 0` → "single earner"; a Diagnostics
  note matching `/declin|drop|fall|down/` against `businessIncome > 0` → "business
  income reported declining" (stated as from the advisor's notes).

### 4.6 Phase trajectory — scenario bands, both ends computed
Let `DS` = current debt service, `adv` = advance instalment (0 unless vehicle 1),
`reneg_cap`/`reneg_amort` from 4.2, `cons_inst` = instalments of CONSOLIDATE rows.
- **Phase 1 (0–3 months)** — consolidation lands:
  low = `(DS − cons_inst) / income` (settled by lever, no new instalment),
  high = `(DS − cons_inst + adv) / income`.
- **Phase 2 (3–12 months)** — renegotiation lands, budget corrected:
  low = `(DS − cons_inst − reneg_current + reneg_amort) / income`,
  high = `(DS − cons_inst + adv − reneg_current + reneg_cap) / income`.
  Surplus after correction = `income − (spend − cuts)`, printed alongside.
- **Phase 3 (12–24 months)** — exit criteria: DSR ≤ 35.00% and surplus ≥ 0. Printed
  as the target, with the gap from Phase 2 low to 35% in points.
- Each phase carries 1–2 checkable actions assembled from 4.1–4.5.

### 4.7 REFER (plan-level headline)
Either: Phase 2 **low** (every lever applied) > 45%; or informal lenders ≥ 3 with
no vehicle from 4.3 (1)–(3) or with any informal balance uncaptured. Headline
becomes "Refer to formal debt counselling"; the rest of the plan still prints.

### 4.8 Review triggers (3–5, all observable)
Always: new informal borrowing; DSR unmoved at the Phase 2 checkpoint. Conditional:
missed advance/consolidation instalment (vehicle 1); lever asset unsold at 60
days (any asset lever on); income falls below `round2(income × 0.9)` (P 11,070.00
for Olorato). Review date = `prep.plan_date + 30 days`, date arithmetic on the
string passed in, so compute stays pure.

### 4.9 Gaps
Same discipline as the AR: rate not captured, balance not captured, remaining
term not derivable, budget not captured, savings not captured (no `savings[]`
rows), assets not captured. Every gap prints and becomes an action.

### 4.10 Olorato, reconstructed — what the unit test pins

The record is not in the repo, so the fixture reconstructs it from spec §1/§7:
income P 12,300.00 (net salary + BNO business income, `spouseIncome` 0); FNB
personal loan instalment P 5,500.00, balance **P 210,000.00** (derived from the
spec's net worth −P 133,000.00 with AUDI P 100,000.00 and P 23,000.00 informal),
rate **blank on the live record** (a sibling session with live access confirmed this
on 3 Sep; the vault has the note), so the worked example takes the cap-only path
and the derived-term arithmetic is pinned by a separate synthetic case; motshelo P 16,000.00
"30% monthly" instalment 0; mother P 7,000.00 "25% monthly" instalment 0; budget
needs 7,400 / wants 1,200 / savings 2,400 / other 4,850; AUDI A3 P 100,000.00
Personal Use, no income; no savings rows; AR context v1 of 28 Aug 2026, advance
P 23,000.00 over 24 months.

| Figure | Value the test asserts |
|---|---|
| Debt service / DSR | P 5,500.00 / **44.72%** (band `strained` → view offered) |
| FNB action / cap | **RENEGOTIATE**, cap **P 4,305.00**; rate blank → "Interest rate not captured" gap + action, no amortised figure |
| FNB variant (synthetic, 12% p.a., balance P 210,000.00) | derived remaining term 49 months; +24 → 73; amortised **P 4,067.08** ≤ cap |
| Motshelo, mother | **CONSOLIDATE**, informal balance P 23,000.00, cross-ref AR v1 28 Aug 2026 |
| Budget | 60.16 / 9.76 / 19.51 / 39.43%; cuts needs P 1,250.00, wants P 0.00, other P 2,300.00; **shortfall P 3,550.00** |
| Levers | AUDI covers informal balance 4.35×; savings not captured → gap + action; single earner |
| Phase 1 band | 44.72% (lever settles) … 52.51% (P 958.33 advance instalment) |
| Phase 2 band | **35.00%** (cap, lever settles) … **42.79%** ((4,305.00 + 958.33) / 12,300, advance + cap); the 12% variant gives 33.07% … 42.79% |
| Phase 3 | target ≤ 35.00%, surplus ≥ 0 |
| REFER | no (Phase 2 low ≤ 45%, 2 informal lenders) |
| Triggers | 5: new informal borrowing; AUDI unsold at 60 days; missed advance instalment; income below P 11,070.00; DSR unmoved at Phase 2 |
| Net worth | −P 133,000.00 (savings none) |

**Spec §7 says Phase 2 is "high-30s (mid-30s if the FNB renegotiation lands)".**
No DSR arithmetic on the stated figures produces high-30s without the
renegotiation: budget correction changes surplus, not DSR, and the advance
instalment raises DSR. The bands above are what the rules in §4 actually give.
See §7 Q2 — this needs a decision before the test is written.

---

## 5. Edge Function and model contract

`index.ts` reads, **as the caller**: `advisor_clients` (id, advisor_id, first_name,
last_name, org_id, assessment); the latest `advance_recommendations` row for the
client (version, status, generated_at, `computed->tier`, `->decision`,
`->advance`, `->term_months`, `conditions` for the `debt_rehab` flag) — absent
or refused → `rehab_context = null`; `advisor_client_notes(client_id)` filtered
`origin != 'system'`, newest 5, each clamped to 400 chars; the five
`assessment.notes.*` clamped to 600 each. Browser sends `client_id`, `mode`, and
`prep = { plan_date?, consultation_date?, extension_months?, liabilities:[{index,
action, classification, rate_period, term_months?}], levers:[{asset_index, on}] }`
only. Quota, model, store — same sequence as the AR.

Model: `claude-sonnet-4-5`, same secret, temperature 0.2, `max_tokens` 2200,
formatted figures only, no name, no consultant name. Returns exactly:
`root_causes[≤3]`, `debt_lines[]` (one per liability, in order), `budget_paragraph`,
`lever_bullets[]`, `phase_paragraphs[3]`, `trigger_lines[]`, `closing_sentence`.
Hard rules copied verbatim from the AR prompt. Missing or malformed → the
deterministic fallback in `report-rehab.ts`, `narrative_source = 'fallback'`.

`content` = the ten sections of spec §6 with names rendered client-side from the
record. `actions` = phase actions + lever opt-ins + triggers as
`{key, label, on, group ∈ phase1|phase2|phase3|lever|trigger}`.

---

## 6. Tests

**Unit — `tests/debt-rehab-plan.test.mjs`** (target ≈ 20 checks)
1. Olorato: every row of the table in §4.10, to the cent.
2. Budget not captured → action one, no targets, shortfall `null`.
3. No informal debt → no CONSOLIDATE rows, no vehicle section, Phase 1 band collapses to current DSR.
4. Three informal lenders, no balances, no AR → plan-level REFER, three balance gaps.
5. Savings balance ≥ one informal balance → savings lever names it, no advance instalment for that debt, Phase 1 low reflects it.
6. Rate text "prime plus two" → rate `null`, "Not captured", gap + action; classification from the hint list.
7. Formal loan at exactly 35.00% of income → RETAIN (strict `>`).
8. Renegotiation where interest alone exceeds the cap → "extension cannot reach the line", REFER input.
9. Motshelo in budget savings + motshelo debt → flag present; either alone → absent.
10. Advisor override: CONSOLIDATE row forced to RETAIN is not sized.
11. Declined AR with an amount → printed with its decision, not used as vehicle.

**Browser — `tests/smoke-rehab.js`** (target ≈ 30 checks, zero JS errors)
Offer rule both ways (DSR band on/off, AR flag on/off, no `offers_advances`
involvement); Prepare shows actions pre-filled and the AUDI lever ticked;
changing an action recomputes live; unticking the lever changes the vehicle text;
generate → ten sections in order with the CONFIDENTIAL — INTERNAL header; edit
saves through `debt_rehab_plan_update`; ticking a phase action saves; print hides
toolbar and unticked items; two-step finalise; immutable; regenerate seeds v2
from v1's confirmations; error path shows the server message.

**Database — `tests/rehab-db-tests.sql` on 16.13 and 17.6** (target ≈ 24 assertions)
Owner creates v1, reads via `_list`; owner's direct `select` returns **zero**
rows (no policy); another advisor: create refused, `_list` refused, select 0;
**member**: `_list` refused, select 0, can_generate false; **HR/employer** (new
fixture user with an `employers` row on Olorato's org): `_list` refused, select 0;
team lead reads and edits the draft; admin reads; finalise idempotent, final
immutable, discard draft-only; regenerate v2; timeline notes; anon has no
execute on any `debt_rehab_plan_%`; migration twice; rollback twice → zero
functions, zero tables, zero policies.

**Regression** — after the extraction and again at the end: AR unit 17/17,
AR browser 28/28, AR DB 20/20 on 16 and 17.

**Sweep** — the CLAUDE.md ungated-`SECURITY DEFINER` query run against the local
migration; the six new functions must not appear.

---

## 7. Decisions needed before building (see chat)

**A sibling session planned the same feature today** with live database access
(its vault entries: `decisions/2026-09-03-debt-rehab-plan-compute-decides.md` and
the 3 Sep open-issues block in the knowledge vault). Its plan file was not pushed
to this repository. The two plans agree on everything except: read path (it keeps
an AR-style SELECT policy and rejects a list RPC; this plan removes the policy and
adds `_list`) and the 35% line (it recommends `threshold_config` with a fallback;
this plan holds a shared constant asserted against the config). Both are Q4/Q5.


Q1 FNB rate and balance for the fixture · Q2 Phase 2 band vs spec §7 "high-30s" ·
Q3 quota pool (separate 40/day recommended) · Q4 `_list` RPC with no SELECT policy
(recommended) vs AR-style policy · Q5 the 35% RENEGOTIATE line as a shared constant
vs read from `threshold_config` at request time · Q6 `conditions` → `actions`
rename · Q7 whether a declined AR's amount should appear at all · Q8 print the
all-in cash gap beside the budget shortfall.

---

## 8. Decisions taken (every recommendation adopted; amend by editing the code that carries it)

| Q | Decision | Where it lives |
|---|---|---|
| Q1 | Olorato fixture: FNB balance P 210,000.00 (from the spec's net worth), rate **blank** as on live; the amortised path is pinned by a synthetic 12% variant | `tests/debt-rehab-plan.test.mjs` |
| Q2 | Phase bands are the computed scenarios: Phase 1 44.72–52.51%, Phase 2 35.00–42.79%. Spec §7's "high-30s" is superseded; the spec file is left as received | `compute-rehab.ts` §4.6 rules |
| Q3 | Separate quota: 40 plans per advisor per Gaborone day, counted on `debt_rehab_plans` only | `debt_rehab_plan_can_generate()` |
| Q4 | **No SELECT policy**; the only read path is `debt_rehab_plan_list()` | `supabase_debt_rehab_plan.sql` |
| Q5 | The 35% line is read from `threshold_config.indicator.dti` (manageable band's `max`) by the Edge Function and passed into compute; `LENDING_NORM_PCT = 35` in `_shared/kw-finance.ts` is the fallback. Stored in `computed.lending_norm_pct` | `index.ts` §3a |
| Q6 | `conditions` → `actions` | table, RPCs, `advisor.html` |
| Q7 | A declined AR's amount prints for reference with its decision; only a "Proceed…" AR is a consolidation vehicle | `compute-rehab.ts` §4.3 |
| Q8 | Both figures print: budget shortfall and the all-in cash gap once debt service is counted | `report-rehab.ts` section 5 |
| Output | This file keeps the plan and carries the record beneath it | — |

---

## 9. Build record

### Files

| File | What it is |
|---|---|
| `supabase/functions/_shared/kw-finance.ts` | **New.** The shared helpers listed in §3, moved verbatim, plus `totalIncome()`, `LENDING_NORM_PCT`, `EXPENSE_GROUP_IDS` and the asset/saving types. |
| `supabase/functions/advance-recommendation/compute.ts` | Slimmed; imports and **re-exports** every moved name. 120 lines removed, 15 added, no behaviour change. |
| `supabase/functions/debt-rehab-plan/compute-rehab.ts` | Pure compute: actions, renegotiation target band (annuity arithmetic), consolidation vehicle, budget cuts + shortfall + all-in cash gap, levers, phase bands, REFER, triggers, gaps, checkables. |
| `supabase/functions/debt-rehab-plan/report-rehab.ts` | Content skeleton (ten sections), fallback narrative, `checkableActions()`. |
| `supabase/functions/debt-rehab-plan/index.ts` | Edge Function. Reads the client, `threshold_config`, the latest AR and `advisor_client_notes()` **as the caller**; `preview` / `generate`. |
| `supabase_debt_rehab_plan.sql` · `migrations/rollback-debt-rehab-plan.sql` | One table, six RPCs, zero policies. Gates written `is distinct from true` (see §11). |
| `supabase_fix_can_manage_advisor_null.sql` · `migrations/rollback-fix-can-manage-advisor-null.sql` | **Separate, independent** one-function fix for §11. Apply first. |
| `advisor.html` | Third switch option; `DRP` state + `drp*` functions; `.drp-*` CSS on top of `.ar-*`. Fork check: exactly two removed lines, both inside `panelReport()` — the `offers_advances` early return (now feeds an `advance` flag) and the Advance Recommendation button (now conditional). `panelReportPFA()` and the whole `AR` block untouched. |
| `tests/debt-rehab-plan.test.mjs` | 28 unit checks. |
| `tests/drp-entry.ts` · `tests/smoke-rehab.js` · `tests/run-rehab.sh` | 33 browser checks against the real `advisor.html` with the real modules bundled in. |
| `tests/rehab-fixture-extra.sql` · `tests/rehab-db-tests.sql` · `tests/run-rehab-db.sh` | 34 RLS-enforced assertions + double migration + double rollback. |
| `tests/can-manage-fix-tests.sql` · `tests/run-can-manage-fix.sh` | Proves the §11 hole, the fix, and that rollback restores the original. |
| `tests/run-advance-db-pg17.sh` | Gains `SUITE=` so any suite runs on the throwaway 17.6 cluster. |
| `tests/smoke-advance.js` | Check 1 no longer asserts exactly two switch buttons (Tumelo's DSR now also offers the rehab view). |
| `package.json` · `.gitignore` | `test:rehab`; the two esbuild bundles ignored. |

### Verified on this machine (Node 22.22, Chromium via Playwright, PostgreSQL 16.13 and 17.6)

| Suite | Result |
|---|---|
| AR unit — before and after the extraction | 17 / 17 |
| AR browser — after the extraction and the switch change | 32 / 32, zero JS errors |
| AR database, 16.13 and 17.6 | 22 pass, rollback clean (3 timeline notes kept) |
| Rehab unit | 28 / 28 — Olorato to the cent (§4.10), 12% variant, budget not captured, no informal debt, three lenders → REFER, savings settles a debt, unparseable rate, exactly-35% edge, advisor override, unreachable renegotiation, motshelo flag, declined AR |
| Rehab browser | 33 / 33, zero JS errors — offer rule three ways, Prepare, live recompute, lever opt-out, generate, ten sections, edit, toggle, print, two-step finalise, immutable, regenerate seeded from v1, error path |
| Rehab database, 16.13 and 17.6 | 34 pass: zero policies; owner/team lead/admin read via RPC; owner's direct select is **zero rows**; another advisor, the member and an HR/employer user all refused; final immutable; discard draft-only; anon no execute; rollback twice → zero functions, tables, policies |
| `can_manage_advisor` fix, 16.13 and 17.6 | hole reproduced → fix applied twice → member refused → rollback twice → hole back |
| Sweep (CLAUDE.md ungated `SECURITY DEFINER` query) on the local migrated DB | zero rows; all six `debt_rehab_plan_*` are `anon = false, authenticated = true` |
| `deno check` on the five pure modules | clean. The two `index.ts` files cannot be checked here: the proxy refuses `deno.land` / `esm.sh`. |

### Not verified from this environment

`*.supabase.co` and the Anthropic API are unreachable, so the deployed function
has not been called end-to-end. **First live run:** sign in on the dev site as an
advisor, open Olorato Maliko → Report → Debt Rehab Plan → Generate, then
`select version, status, narrative_source, model, input_tokens, output_tokens from debt_rehab_plans`
and the function logs. `narrative_source = 'fallback'` means the log line
`model narrative unusable` says why. Note the sibling session's finding that
`advance_recommendations` is empty on live: until an AR is generated and
finalised for Olorato, her plan takes the "size a consolidation via an AR" path.

---

## 10. Deploy note (in this order; nothing was applied by the build session)

1. `supabase_fix_can_manage_advisor_null.sql` in the SQL editor — **do this today
   regardless of the rest**, see §11.
2. `supabase_debt_rehab_plan.sql` in the SQL editor. Verify:
   `select proname from pg_proc where proname like 'debt_rehab_plan_%'` → 6 rows;
   `select policyname from pg_policies where tablename='debt_rehab_plans'` → 0 rows.
3. `supabase functions deploy debt-rehab-plan` **and**
   `supabase functions deploy advance-recommendation` — the AR now imports
   `_shared/kw-finance.ts`, so it must be redeployed with the shared file or its
   next cold start fails to resolve the import. Both use the existing
   `ANTHROPIC_API_KEY`.
4. Merge the branch into `dev`; confirm the Cloudflare build goes green
   (Deployments → Build history) before testing.
5. Re-run the CLAUDE.md sweep against the live project; expect the ten known rows.

Rollback: `migrations/rollback-debt-rehab-plan.sql`, `supabase functions delete
debt-rehab-plan`, revert the `advisor.html` commit. The `_shared` extraction is
safe to leave in place. Roll back the gate fix only if it broke something —
its rollback reopens §11.

---

## 11. Security finding — `can_manage_advisor()` returns NULL for non-advisors (live today)

Found by the rehab RLS suite ("member: list is refused — it was allowed").
`can_manage_advisor(p)` is `p is not null and (p = current_advisor_id() or
is_team_lead() or is_admin())`. For a caller with no `advisors` row —
a member, an HR user, any signed-in non-advisor — `current_advisor_id()` is
NULL, `p = NULL` is NULL, and the whole expression is **NULL, not FALSE**.
Policies treat NULL as false, so the SELECT policies hold. But seventeen RPCs
gate with `if not can_manage_advisor(v_owner) then raise`, and `if not NULL`
does not raise. So today a member who knows their own `advisor_clients.id`
(readable under `advisor_clients_member_read`) can call
`advisor_client_notes()` and read the advisor's private notes on themselves,
call `advisor_note_add()`, and call `advance_recommendation_create()` in their
own name. `tests/run-can-manage-fix.sh` reproduces the last of these.

Fix: `supabase_fix_can_manage_advisor_null.sql` wraps the gate in
`coalesce(…, false)`. One function, same signature and grants, every call site
covered. The rehab RPCs are additionally written `is distinct from true` so
they are safe with or without it. Recorded in the vault open issues.
