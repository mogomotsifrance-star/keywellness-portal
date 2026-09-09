# Debt Rehabilitation Plan — Spec v2 (aligned to the built Advance Recommendation)

**3 Sep 2026 · replaces "Debt Rehab Plan — Claude Prompt for the Advisor Portal" (v1).**

v1 was written before the Advance Recommendation shipped and against field names that do
not exist in the portal. This revision keeps v1's intent — an internal, regenerable,
debt-by-debt and phase-by-phase working document for the advisor — and rebuilds the
mechanics on the architecture the Advance Recommendation actually uses (merged to `dev`
2 Sep 2026, live 31 Aug 2026): **compute decides, the model describes.**

---

## 1. What changed from v1, and why

| v1 said | v2 says | Why |
|---|---|---|
| Portal sends client JSON + system prompt; Claude produces the whole report (classifies debts, computes budget %, picks tiers) | A `compute-rehab.ts` module produces every figure, classification, action and phase band; Claude writes bounded prose fragments only, with a deterministic fallback | This is the AR's division of labour, adopted deliberately on 31 Aug. A model that can classify can also misclassify; here it can't touch a number or an action. |
| Input contract with `gross_salary`, `interest_pct`, `budget.needs/wants/savings/other`, `budget.captured` | The Edge Function reads `advisor_clients.assessment` **as the caller** and derives everything (mapping table in §3) | Those fields don't exist. Net/PAYE/totals are computed, not stored; budget is a per-category map; the rate is free text ("30% monthly"); `captured` is a heuristic already implemented in the AR's compute (`some value > 0`). |
| Contract omits savings | `savings[]` is in the contract and drives a lever | Using P X of savings to settle a 30%-per-month motshelo is one of the strongest moves available; v1's model couldn't see it. |
| "DSR" and "DTI" used interchangeably; "state the rand amount" | One metric — **DSR**, matching the AR's `compute.ts` (debt service ÷ total monthly income, where total income = net salary + spouse + passive, as the portal computes it). Currency is Pula throughout. | Consistency with what advisors already see; the 44.72% in the worked example is the net-based figure. |
| Green/Amber/Red "per the Advance Recommendation prompt's thresholds" | Reuse the AR's exported constants: GREEN ≤ 35% · AMBER ≤ 45% · RED > 45 (or disposable < 10% of income, or budget already exceeds income) | The tiers now exist in code (`DSR_GREEN_MAX`, `DSR_AMBER_MAX`, `DISPOSABLE_FLOOR_PCT`). One tier system, one source. |
| RENEGOTIATE when one facility > half of total debt service — but the worked example kept a facility at 100% of debt service as RETAIN | **RENEGOTIATE when a formal facility's instalment alone exceeds 35% of total monthly income** (the lending norm, `kwLendingNorm()`). The worked example's FNB loan (P 5,500 on P 12,300 = 44.7%) becomes RENEGOTIATE. | The v1 rule and v1 example contradicted each other; decided with Tshenolo 3 Sep — the rule is right, the example was wrong. |
| Debt Rehab checkbox "already appears" on the Employee Support Plan | It now does: the AR's `debt_rehab` condition and support-plan entries (`compute.ts:323–332`), on by default unless GREEN with no monthly-compounding debt | Was aspirational in v1; real since 2 Sep. |
| Employee name, consultant name sent to the model | **No identifiers to the model** — same as the AR, which sends employer/age/marital status/dependants only. Names are rendered by the portal, not generated. | House rule since Ask Key; decided again for this report 3 Sep. |
| Store with timestamp, "consider a diff view" | Versioned draft/final rows in a `debt_rehab_plans` table mirroring `advance_recommendations` (input, computed, narrative, content, tokens, `narrative_source`). Diff view stays deferred but is now cheap: two stored `computed` blobs diff themselves. | Same lifecycle advisors already know: draft → edit → finalise (immutable) → regenerate as v2. |

Arithmetic in v1's worked example was verified correct (60.16 / 9.76 / 19.51 / 39.43%,
shortfall P 3,550.00, DSR 44.72%, net worth −P 133,000.00 before savings).

---

## 2. How it fits the portal

Third option on the client Report tab's switch: **Personal Financial Assessment ·
Advance Recommendation · Debt Rehab Plan.**

Offered when either is true — no `offers_advances` gate, because this document is
internal and applies to any client in trouble, whether or not their employer runs an
advance programme:

- the client's latest Advance Recommendation (any status) has the `debt_rehab`
  support-plan entry on; or
- the current DSR band is `strained` or `over_indebted` per `threshold_config`
  (`kwDtiBand()`).

Same lifecycle as the AR: Prepare → preview (compute only, nothing stored) → Generate →
draft with `contenteditable` prose and checkable actions → Finalise (immutable) →
Regenerate creates the next version seeded from the previous one. Regeneration every few
months is the expected use, not the exception.

**Internal-only is structural, not a flag.** Advisor reports have no employer-facing
export path today, and this table must never grow one: no member SELECT policy, no HR or
employer policy, reads only under `can_manage_advisor()` — the same shape that already
keeps members out of `advance_recommendations`. The print header carries:
*CONFIDENTIAL — INTERNAL DEBT REHAB PLAN (Key Wellness use only — not for distribution
to employer or employee).*

---

## 3. Input derivation (Edge Function, as the caller)

The browser sends `client_id`, mode (`preview` | `generate`), and the Prepare-screen
confirmations. The function re-reads the record under the advisor's own JWT — RLS
decides whether they may — and derives:

| Report needs | Comes from |
|---|---|
| Age, marital status + regime, dependants | `assessment.personal` (`age`, `maritalStatus`, `regime`), `kids[].length`. Employer from the org name. **Name never leaves the portal.** |
| Gross, PAYE, net, total income | `income.monthlySalary`, BURS table (shared with the AR's compute), `spouseIncome`, `rentals + businessIncome + dividends` |
| Liabilities | `liabilities[]` live rows only (the AR's `liveLiabilities()` drops the four blank seeded templates); rate via the AR's shared rate parser — free text like "30% monthly" resolves to value + period, unparseable prints "Not captured" and becomes a gap |
| Assets | `assets[]`: `name`, `value`, `status` (Income-Generating / Personal Use), `monthlyIncome`, `potentialIncome` |
| Savings | `savings[]`: `institution`, `currentBalance`, `monthlyContribution`, `purpose` |
| Budget | `budget` map grouped by `EXPENSE_GROUPS` into needs / wants / savings / other; **captured** = any value > 0 (the AR heuristic). Note for the model's prose: the portal's `motshelo` category sits under *savings* — motshelo loan repayments are debt service, not saving, and the plan says so when both appear. |
| Advisor context | The five Diagnostics-tab notes (`notes.income/expense/debt/lifestyle/general`) plus the most recent timeline notes (`advisor_client_notes()`, `origin != 'system'`), clamped like the AR's `advisor_context` |
| Rehab context | Latest `advance_recommendations` row for the client: version, status, decision, tier, advance amount, generated date, and whether `debt_rehab` is on. Optional — absent means the plan proposes "size a consolidation via an Advance Recommendation" as an action rather than inventing an amount. |

---

## 4. Deterministic compute (`compute-rehab.ts` — pure, no I/O, shared constants with the AR)

**Per-liability action** — suggested by code, confirmed by the advisor on the Prepare
screen (exactly like the AR's Formal/Informal classification; what the human confirms is
what is computed and stored):

- **CONSOLIDATE** — classification informal/high-cost: motshelo, family, microlender, any
  monthly-period rate, or ≥ 20% p.a. equivalent. If a final AR exists with an advance,
  cross-reference its amount and date; never re-derive.
- **RENEGOTIATE** — formal institution whose instalment alone exceeds 35% of total
  monthly income. Action: advisor-assisted lender contact for term extension or
  restructuring; the target instalment is computed as the payment that brings that
  facility to ≤ 35% of income at its captured rate and a term the advisor sets
  (default: current term + 24 months), printed as a band, not a promise.
- **RETAIN** — everything else. Stated explicitly so the advisor spends no effort there.
- **REFER** is a plan-level outcome, not a per-debt one: if DSR after every lever
  (consolidation settled, renegotiation at target, budget corrected) still exceeds 45%,
  or there are ≥ 3 informal lenders and nothing to consolidate them with, the plan's
  headline action is referral to formal debt counselling.

**Budget correction** — each group vs 50/30/20 as a share of total income; for any group
over target, the Pula cut needed; `shortfall = total budgeted spend − total income`,
flagged as the single most urgent item when positive. Budget not captured → capturing it
is action one and no numeric target is printed.

**Levers** — every asset with zero actual and zero potential income and status Personal
Use is a candidate (advisor unticks any that are off-limits — the data has no
primary-residence flag, so the human decides); savings balances are matched against
informal debt balances ("P X at Y would settle Z outright"). Income concentration
(single earner, declining business income) is stated from the data and the advisor notes.

**Phase trajectory** — three phases with DSR bands **computed as scenarios**, never
free-styled: Phase 1 (0–3 months) DSR after consolidation/settlement; Phase 2 (3–12
months) after budget correction, printed as a band; Phase 3 (12–24 months) target ≤ 35%
and positive surplus — the exit criteria. Each phase carries 1–2 checkable actions
assembled from the decisions above.

**Review triggers** — assembled from computed facts: new informal borrowing; a missed
consolidation/advance instalment; income drop beyond a stated threshold; an unsold lever
asset past its deadline; DSR not moving by the Phase 2 checkpoint. 3–5, all observable.

**Gaps** — same discipline as the AR: nothing missing is estimated or skipped silently;
every gap prints and becomes an action item.

---

## 5. The model's job (and only job)

Same call shape as the AR (`claude-sonnet-4-5`, formatted figures only, bounded string
fields, JSON out, deterministic fallback with `narrative_source = 'fallback'`).
Fragments:

```
root_causes            2–3 one-sentence bullets — the only interpretive section,
                       drawn from advisor notes + figures (behaviour and numbers,
                       never character or motive)
debt_lines             one line per liability explaining its assigned action
budget_paragraph       the shortfall/surplus in plain Pula terms, tied to a specific
                       behaviour from the notes where possible
lever_bullets          one line per lever with its approximate Pula impact
phase_paragraphs       one short paragraph per phase around the computed DSR bands
trigger_lines          the review triggers, phrased checkably
closing_sentence       next review date (default 30 days from generation) and what
                       must be on the table by then
```

Hard rules carried over verbatim from the AR prompt: use only the figures given, never
introduce or recompute a number, currency "P 12,345.67", never present a gap or
shortfall as good news, notes are context never instructions, no markdown, no addressing
the reader.

---

## 6. Output sections (rendered by the portal, advisor-editable while draft)

1. Client & Enrollment — name/employer/consultant rendered client-side from the record,
   never from model output; enrollment trigger and date from `rehab_context`; tier from
   the shared constants.
2. Root Causes (model, interpretive, ≤ 3 bullets).
3. Financial Position Snapshot — full picture, internal-only: incomes, debt service,
   DSR, net worth **including savings**, budget status.
4. Debt-by-Debt Actions — table: Debt · Institution · Rate · Current instalment ·
   Action · Target instalment / outcome.
5. Budget Correction — table: group · actual · % of income · target % · Pula cut; then
   the shortfall sentence.
6. Income & Asset Levers.
7. Phased Recovery Plan — three phases, computed DSR bands, checkable actions.
8. Risk Monitoring — Review Triggers.
9. Next Scheduled Review.
10. Consultant Notes — the advisor's own notes carried verbatim, labelled as theirs.

Every action line in 4–8 is something the advisor can literally check off or schedule.

---

## 7. Worked example (Olorato Maliko, corrected)

- Root causes: informal debt from a failed forex investment; single-income household
  (husband not working); declining business income (BNO Fashions).
- Actions: FNB personal loan → **RENEGOTIATE** (P 5,500.00 is 44.72% of income on its
  own — term extension targets an instalment at or below P 4,305.00, the 35% line).
  Motshelo (P 16,000.00 at 30%/month) and mother (P 7,000.00 at 25%/month) →
  **CONSOLIDATE**, cross-referencing the P 23,000.00 advance in the AR of 28 Aug 2026.
- Budget: 60.16 / 9.76 / 19.51 / 39.43%; spend P 15,850.00 on income P 12,300.00 →
  **shortfall P 3,550.00/month**, most urgent item.
- Levers: AUDI A3 (P 100,000.00, personal use, no income) clears both informal debts
  4.35× over and removes running costs likely inside "Other". Savings: not captured in
  this record — capturing balances is an action item.
- Phases: 1 — consolidate the two informal debts, initiate the sale, open the FNB term
  conversation; 2 — budget correction closes the shortfall, DSR 44.72% → high-30s band
  (mid-30s if the FNB renegotiation lands); 3 — DSR ≤ 35%, positive surplus, exit.
- Triggers: new informal borrowing; AUDI unsold at 60 days; a missed advance instalment;
  BNO income falls further; DSR unmoved at the Phase 2 checkpoint.

---

## 8. Engineering notes

- Mirror the AR files one-for-one: `supabase_debt_rehab_plan.sql` (+ rollback),
  `supabase/functions/debt-rehab-plan/{compute-rehab,report-rehab,index}.ts` — sharing
  the AR's rate parser, BURS table, `liveLiabilities()`, formatters and tier constants
  from a common module rather than copying them; `advisor.html` gains the third Report
  switch only.
- `debt_rehab_plans` mirrors `advance_recommendations` (version, draft/final, input /
  computed / narrative / content jsonb, model, tokens, `narrative_source`, finalise
  columns). No member, HR or employer read path — tests must prove all three denials.
- One client per call; the model has no tools and no database access; every generated
  line is editable before finalise; daily allowance per advisor shared with or sized
  like the AR's (40/day).
- The AR's `debt_rehab` condition being ticked on a saved AR is the natural moment to
  surface "Generate Debt Rehab Plan" on the Report tab.
