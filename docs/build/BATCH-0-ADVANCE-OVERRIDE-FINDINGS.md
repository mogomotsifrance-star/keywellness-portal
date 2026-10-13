# Batch 0: advisor document viewer + advance override (13 Oct 2026)

Read-only discovery. Nothing was changed in the database, the Edge Functions or
any page. Live reads were `select` only, against `tarmpqxsabbehgjaonfz`.

**Gate: NO-GO.** One gate condition is met (section 1, "the generator"), and
the document feature rests on a premise that does not hold (section 3).

---

## 1. The Advance Recommendation report

**Calculated** by the Edge Function `advance-recommendation` (live v5), in
`supabase/functions/advance-recommendation/compute.ts:119-320`. It is pure code,
and the model writes prose only. The formula (`compute.ts:192-229`):

- amount = the lower of (a) the captured balances of every debt the advisor
  confirmed as informal or high-cost and (b) the cap, 4 x gross monthly salary
- term fixed at 24 months, 0%, instalment = amount / 24, kept to the cent
  (`round2`, so P 1,535.42, not rounded to the pula)
- when the cap binds, the dearest debts are settled first and the rest
  part-pays the next one
- DSR after, tier (GREEN/AMBER/RED) and decision line are all computed **from
  that amount**

**The 4 x gross cap is already applied**, at `compute.ts:199`.

**Stored** in `public.advance_recommendations` (`supabase_advance_recommendation.sql:38`,
plus `consent_id` from the consent build). Columns: `id, client_id, advisor_id,
created_by, version, status, input, computed, narrative, content, conditions,
model, input_tokens, output_tokens, narrative_source, generated_at, updated_at,
finalised_at, finalised_by, consent_id`. One row per generated **version** per
client. `id` is a stable uuid. Live today: **8 drafts, 0 finals.**

**Rendered** in the browser, not by a generator: `advisor.html:4141`
`arRenderDoc(rep)` draws the stored `content` jsonb. Print / Save as PDF is
`window.print()`. `content` is built once, at generation, by
`report.ts:80` `buildContent()`, and drafts are then edited in place
(`contenteditable`, saved through `advance_recommendation_update`).

**Sent to the employer:** there is no send step. No email, no Edge Function, no
Resend, no "sent" column. The advisor prints or saves a PDF and hands it over.
The only recorded milestone is `status = 'final'` + `finalised_at`, which since
5 Oct needs a recorded consent form. BUILD-NOTES says a final "goes to Hollard
HR", so `finalised_at` is the nearest thing to a "sent" date.

**Gross monthly salary** is `advisor_clients.assessment -> 'income' ->> 'monthlySalary'`
(text inside jsonb, edited on the advisor's Income tab). It can be read server
side. 1 of the live client records has none.

### Why this is the NO-GO

The portal's figure is not one value the report looks up. It is written into
the stored `content` in at least seven places when the report is generated:

| Where | What it holds |
|---|---|
| `content.meta.recommended_amount` | "P 22,000.00" |
| `sections.reasoning.close` | model prose: "The recommended advance is P 22,000.00, sized to..." |
| `sections.dsr.rows[*].after` | debt service and DSR **after**, worked out on the portal amount |
| `sections.dsr.paragraph` | prose on the DSR before and after |
| `sections.ability.paragraph` | prose quoting the instalment (amount / 24) and disposable income after |
| `sections.debt_position.rows` | "New advance" row with the amount and instalment; "Settled by advance" / "Part-paid" status per debt |
| `sections.risk` + `recommendation.decision` | tier and decision, decided on the portal amount |

The prose is free text written by the model and then edited by the advisor, so
it cannot be reliably find-and-replaced. If the report shows the advisor's
P 55,000 in the header and override section, the rest of the same report still
says P 22,000, and the DSR after, tier and decision describe an advance that is
not being recommended. That breaks D1 ("the portal's original calculation does
not appear on the report") and would hand HR a report that contradicts itself.

That is the gate's fourth condition: a stored override cannot be injected
without changing how the report is produced.

## 2. Liabilities

There is **no liabilities table**. Liabilities are a jsonb array at
`advisor_clients.assessment -> 'liabilities'` (132 rows across all clients).
Keys: `item, institution, loanAmount, interestRate, balance, monthlyInstalment, fixed`.
**No per-row id.** The report refers to them by index into the "live" list
(`kw-finance.ts liveLiabilities()`), which moves when the advisor adds or
deletes a row. The loan term mentioned in BUILD-NOTES 4 Oct is held in the
JSON too. RLS is that of `advisor_clients` (below).

D5's "linked to a liability" cannot be a foreign key. It would have to be an
index plus a snapshot of lender and balance taken at save time.

## 3. Uploaded documents

**There is no documents bucket.** Storage holds one bucket, `Videos` (public,
40 objects, LMS videos only). Member documents are not in Supabase Storage.

They are **base64 data URLs inside the client record**:
`advisor_clients.assessment -> 'documents'` = `[{id, name, mime, size, uploadedAt, dataUrl}]`
(`advisor.html:1314`, upload at `:3666`, Download link at `:3646` is a plain
`<a href="data:..." download>`). The page's own notice (`:3663`) says this was
meant to be temporary. Live: 16 documents on 7 clients.

| Type | Count | Average size (base64) |
|---|---|---|
| PDF | 8 | 317 KB |
| PNG | 1 | 654 KB |
| Excel (.xlsx) | 4 | 22 KB |
| Word (.docx) | 2 | 19 KB |
| Email (.eml) | 1 | 1.2 MB |

What that means for Batch 1 as written:
- There is nothing to sign, so `get_document_url()` returning a 5-minute signed
  URL has nothing to point at.
- The bytes of every document reach the browser whenever the advisor portal
  loads its client list, because they are part of the `advisor_clients` row.
  A view or download log written by the page records what the page chose to
  report, not what the database released. **D11 cannot be enforced in the
  database on the current storage.**
- Who can read the documents today is whoever can read the row: the assigned
  advisor (`advisor_clients_own`), team leads, admins, **and the linked member
  (`advisor_clients_member_read`: `member_user_id = auth.uid()`)**. Members
  reading their own uploads is defensible. Note that the same policy gives
  them the advisor's whole consultation record.

Not public, so the "public bucket" NO-GO condition does not apply. But D10 and
D11 as designed assume Storage.

## 4. Advisor role in RLS

Helpers, all live: `current_advisor_id()`, `is_advisor()`,
`can_manage_advisor(owner_advisor_id)` (assigned advisor, any team lead, or
admin), `is_team_lead()`, `is_admin()`, `is_staff()`. Every advance RPC gates
on `can_manage_advisor(advisor_clients.advisor_id)`. The consent RPC is
narrower: assigned advisor or admin, not a team lead.

## 5. Utilities

- **No `stripAiDashes`** or equivalent exists anywhere in the repo.
- Existing report strings already contain dashes: "Decline – Insufficient Data",
  "Debt Service Ratio — Before vs After", "Other – Express Credit", the
  DATA GAPS line. The no-dash rule can only bind new strings unless the existing
  ones are changed too, which would alter the "no override" report (Batch 4
  requires that to stay byte-identical).
- Pula formatting: `fmtP()` in `_shared/kw-finance.ts` (server) produces
  "P 12,345.67". The page renders the stored strings.
- Report styles: the `.ar-*` block in `advisor.html`, shared with the Debt
  Rehab Plan.

## 6. Name collisions

Public tables matching `override|note|access_log|allocation`: `advisor_notes`,
`counselling_notes`. None of the proposed names exist.

`advisor_notes` is the client timeline. It is **not** append-only (policies
`advisor_notes_own`, `_lead_all`, `_admin_all` are `ALL`), so it cannot hold
D7's internal notes. A new table is right.

---

## Conflicts with D1 to D12

| | Conflict |
|---|---|
| **D1** | The portal figure is embedded in stored prose, the DSR-after table, the debt table, the tier and the decision. Overriding the header figure alone leaves it on the report. (NO-GO) |
| **D3** | Already met for the portal figure. For the override, gross salary is jsonb text the advisor can change at any time; the cap snapshot at save time is the binding value. |
| **D4** | The existing report shows the instalment to the cent; D4 says the nearest pula. Two roundings would sit side by side unless the existing figure changes too. |
| **D5** | No liabilities table and no liability ids. A link is an index + snapshot, not an FK. |
| **D9** | The id is per version. Regenerating (v2) does not carry v1's override. Drafts can be **discarded (row deleted)**; an override FK would have to block that or cascade, and cascading breaks D2/D7. |
| **D10** | No Storage, so no signed URLs. The viewer can render the data the page already holds via a `blob:` URL, which never leaves our systems. |
| **D11** | Logging cannot be enforced server side while documents ship inside the client row. |
| **D12** | There is no "sent" record. `finalised_at` is the only candidate, and 0 reports are final today. |
| Copy rule | No dash-stripping utility exists, and the existing report copy has dashes. |

## What would make it GO (options, for Tshenolo)

**Report (the NO-GO).** Pick one (A, B or C):

- **A. Recompute on the advisor's amount (recommended).** Teach `compute()` an
  advisor amount and allocations, so DSR after, the debt table, tier and
  decision all follow the advisor's figure, then rebuild the prose for the
  affected paragraphs from deterministic text (no model call). An overridden
  report is then internally consistent and never shows the portal figure.
  Costs an Edge Function change (redeploy, which is live at once) and a few
  more days.
- **B. Override replaces sections.** When an override is active, the report
  drops sections 02 to 05 and the risk/decision block, and shows the advisor's
  amount, repayment, justification and use-of-funds table in their place.
  Frontend only, quick. HR then loses the DSR before/after and the risk tier on
  overridden reports.
- **C. Override at generation.** The advisor sets the amount and use of funds
  on the Prepare screen, before generating. The report is generated once,
  consistently, on that figure. Simplest data model (no separate override of a
  stored report), but "change after sending" means generating a new version.

**Documents.** Pick one (E or F):

- **E. Viewer now, honest log.** Ship View (PDF/PNG in an in-page viewer
  from a `blob:` URL) and keep Download, log each click through a gated RPC,
  and document that the log is page-reported. Small, same day.
- **F. Move documents into a private bucket first.** Private bucket, a
  one-off copy of the 16 files, uploads go to Storage, and both buttons go
  through a gated RPC/Edge Function that logs and signs. Then D11 holds in the
  database, and documents stop travelling to every page load. Bigger, and it
  needs a decision on whether the linked member keeps access.
