# Advance Recommendation Report — build record (31 Aug 2026)

A second view on the advisor portal's **Report** tab that generates the
Hollard Employee Financial Wellness Program "Advance Recommendation
Report" for one client. Requested as a Claude-prompt integration; built
so that **the model writes prose and nothing else** — every figure,
classification, risk tier and decision comes from deterministic code
whose input and output are stored with the report.

## Files

| File | What it is |
|---|---|
| `supabase_advance_recommendation.sql` | One table (`advance_recommendations`) + five gated RPCs. **Applied to the live project 31 Aug 2026.** |
| `migrations/rollback-advance-recommendation.sql` | Drops all of it. Leaves the timeline notes. |
| `supabase/functions/advance-recommendation/compute.ts` | Pure arithmetic + classification + tier. No I/O. Runs under Deno and Node. |
| `supabase/functions/advance-recommendation/report.ts` | Pure content assembly + the deterministic fallback narrative. |
| `supabase/functions/advance-recommendation/index.ts` | The Edge Function. **Deployed (v2) 31 Aug 2026.** Uses the existing `ANTHROPIC_API_KEY` secret. |
| `advisor.html` | Report tab gains a Personal Financial Assessment / Advance Recommendation switch; the `ar-*` CSS block and the `AR` JS block. The old `panelReport()` is now `panelReportPFA()` and is otherwise untouched. |
| `tests/advance-recommendation.test.mjs` | 17 unit checks on `compute.ts` — the Tumelo worked example plus six edge cases. |
| `tests/smoke-advance.js` | 28 headless-browser checks against the real `advisor.html`, with the real compute/report modules bundled into the page. |
| `tests/run-advance.sh` | Runs both. |
| `tests/advance-fixture.sql`, `tests/advance-db-tests.sql`, `tests/run-advance-db.sh` | 20 database checks with RLS enforced (`set role authenticated`): owner / other advisor / member / team lead access, draft edit, finalise idempotent, final immutable, discard draft only, timeline notes, anon has no execute. Then rollback twice → zero objects. Run on local PostgreSQL 16 here; the house standard is 17 — re-run on 17 before trusting it further. |

## How a report is produced

1. **Prepare.** The advisor sees every live liability (the four blank
   template rows are dropped) pre-classified Formal / Informal-high-cost,
   with the rate period defaulting to per-year and switchable to per-month,
   plus term (default 24), consultation date and an optional context note.
   Figures update live via `mode: "preview"` (compute only, nothing stored).
2. **Generate.** `mode: "generate"`: the function re-reads the client
   **as the caller** (RLS decides whether they may), computes, checks the
   daily allowance (40 per advisor), asks Claude Sonnet 4.5 for eight prose
   fragments as JSON, builds the content, and stores it through
   `advance_recommendation_create()` — which re-checks `can_manage_advisor()`
   and writes a system note to the client's timeline.
3. **Edit.** While a version is a draft, every paragraph, bullet and
   condition label is `contenteditable`; the three operating conditions
   and the support-plan / follow-up items are checkboxes. Edits save
   through `advance_recommendation_update()` (800 ms debounce).
4. **Mark final** (two-step button) locks the row. A final is immutable;
   **Regenerate** creates a new version seeded from the previous
   classification. **Discard** removes a draft only.
5. **Print / PDF** uses the existing print stylesheet; unticked conditions
   and the client hero are hidden, checkboxes become ■ glyphs.

## The rules that were decided, not defaulted

- **Arithmetic is code, not model.** The spec asked Claude to sum, divide
  and pick the tier. It now cannot: it never sees a raw number it can
  change, only formatted figures to describe. If its answer is missing or
  malformed the deterministic fallback prose is used and the row says so
  (`narrative_source = 'fallback'`; the toolbar shows a note).
- **Tier.** GREEN ≤ 35% DSR after; AMBER 35–45%; RED if > 45%, or
  disposable income after < 10% of income, or a captured budget already
  exceeds income, or there is nothing to consolidate. **A rising DSR alone
  is never RED** — the spec's STEP 4 and STEP 5 contradicted each other on
  this; resolved 31 Aug with Tshenolo. It is stated plainly in the DSR
  paragraph instead.
- **"Not captured" is not zero.** A blank rate prints "Not captured"; a
  zero balance on an informal debt is a gap that blocks sizing, not a
  settled debt; no budget on file is reported as "shortfall cannot be
  ruled out", never as "no shortfall".
- **Classification is confirmed by a human.** `suggestClassification()`
  only pre-fills the Prepare screen. What the advisor confirms is what is
  computed and what is stored in `input.prep`.
- **Conditions are defaults.** Proof-of-payment is on whenever an advance
  is proposed; Debt Rehab is on unless GREEN with no monthly-compounding
  debt; the HR-letter hold is on for RED or ≥ 3 informal lenders. All
  three are checkboxes the advisor may untick; unticked ones do not print.
- **Decision lines** are the spec's four plus two honest declines:
  "Decline – No Consolidation Opportunity" and "Decline – Insufficient Data".

## Verified

- `compute()` reproduces the spec's worked example exactly: DSR 45.43% →
  42.75%, advance P 36,850.00, instalment P 1,535.42, AMBER, Conditional
  Approval. Tumelo's live record produces the same numbers.
- Rising-DSR-stays-AMBER, crosses-45-goes-RED, monthly-rate parsing,
  nothing-to-consolidate, budget shortfall, and informal-without-balance
  each have a unit check.
- Browser: Prepare → live recompute on reclassification and term change →
  generate → nine sections in order → edit saves → toggle saves and
  strikes through → print hides it → two-step finalise → immutable →
  regenerate → v2 → error path surfaces the server message → zero JS errors.
- Fork check before touching `advisor.html`: the only removed line is the
  `panelReport` → `panelReportPFA` rename.
- Migration: all five RPCs `anon_can = false`, `authenticated_can = true` on the live project. Locally: forward migration applied twice without error, 20 RLS-enforced assertions pass, rollback applied twice leaves zero functions and zero tables (system notes kept by design).

## Not verified from this environment

The build sandbox cannot reach `*.supabase.co`, so the deployed function
has not been called end-to-end with a real advisor session. **First live
run:** sign in to the dev site as an advisor, open Tumelo Kgamayane →
Report → Advance Recommendation → Generate, then check
`select version, status, narrative_source, model, input_tokens, output_tokens from advance_recommendations`
and the function logs. If `narrative_source` is `fallback`, the log line
`model narrative unusable` says why (most likely the model id or the
secret).

## Rollback

1. `migrations/rollback-advance-recommendation.sql` in the SQL editor.
2. `supabase functions delete advance-recommendation`.
3. Revert the `advisor.html` commit on `dev`.

Nothing else was touched. The `advisor_notes` system rows stay as a record
that generations happened.

## Open items

- Other employers: `PROGRAMME`, `ADVANCE_TYPE`, the "Hollard (payroll)"
  line and the confidentiality text are constants in `report.ts`; the
  employer name in the header is the client's. Making this per-employer
  needs a small config table, not a rewrite.
- The Liabilities tab still has no per-month/per-year field; the Prepare
  screen compensates. If a field is added, `parseRate()` and
  `suggestClassification()` should read it first.
- Consultation date defaults to today; it could default to the latest
  completed booking.
