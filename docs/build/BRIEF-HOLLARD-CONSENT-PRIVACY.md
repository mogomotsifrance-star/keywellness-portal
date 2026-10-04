# Claude Code Prompt: Hollard consent, privacy notice and what HR receives

## Read this first
- Key Wellness portal. Frontend on `dev` only; never `main`. One shared Supabase project, so SQL is live at once. Additive only; rollback written first.
- Edge Functions deploy straight to production. Record the version and ezbr hash before changing one.
- HR must never see more of a member's finances than the member agreed to share.
- Member-facing copy: no em dashes, en dashes or double hyphens.
- Stop at the GO/NO-GO gate.

## The problem (found 4 Oct 2026)
1. **The Advance Recommendation is written for the Hollard HR approver** (`supabase/functions/advance-recommendation/index.ts`, system prompt; `report.ts` confidentiality line). It lists every debt, lender, balance and instalment. Its own footer says "underlying financial details remain confidential between the employee and the Consultant". No consent to share with the employer is recorded anywhere.
2. **The 13 Hollard clients have no portal account** (`advisor_clients.member_user_id` is null for all of them). They never saw the portal's Data Protection statement (`index.html`, `#consent-statement`).
3. **That statement says data is "used exclusively for financial wellness coaching"**, which does not describe a report going to an employer to decide an advance.
4. Related safeguard, built separately: an Advance Recommendation cannot be marked final without a recorded consent (see the consent-gate batch). This brief covers the wording, the capture route and what HR receives.

## Batch 0: read-only discovery
1. How a member who **has** a portal account currently consents to anything advisor-related: tables, RPCs, and the `advisor_client_detail` consent gate. Can it be reused for "share with my employer"?
2. How consent can be recorded for a client **without** an account: a signed form captured by the advisor (who records it, when, what evidence).
3. The exact current wording of the Data Protection statement and the onboarding link to it; where a versioned notice would live.
4. What the Advance Recommendation contains today, section by section, and which parts HR actually needs to approve an advance. Proposal: the advance amount, term, instalment, the decision and conditions, and only the debts being settled (lender name, balance settled). Not the formal debts, rates, budget or full DSR detail.
5. How the report reaches HR today (manual print). Is there any in-platform path?
6. Botswana Data Protection Act points to raise with Tshenolo (consent, purpose limitation, cross-border AI processing already disclosed for Ask Key). Flag only; this is not legal advice.

**GO/NO-GO gate.** Present:
- the proposed consent record (fields, who can write it, RLS)
- the proposed notice wording change
- a trimmed "HR copy" of the report next to the full advisor copy

Tshenolo approves the wording.

## Batch 1+ (after GO), indicatively
- Consent record and capture UI (advisor records a signed form; a member with an account can consent in-portal).
- A versioned privacy notice with the new purpose.
- A trimmed HR version of the Advance Recommendation. The full version stays advisor-only.

**Checklist:**
- [ ] No HR-bound document contains formal debts, rates or the budget.
- [ ] Consent is recorded with who, when and the evidence.
- [ ] Old reports are unchanged.
- [ ] The dash check passes on new member copy.
