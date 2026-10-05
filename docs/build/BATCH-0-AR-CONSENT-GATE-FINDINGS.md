# Batch 0 findings: consent before an Advance Recommendation goes final (4 Oct 2026)

Read-only discovery. Nothing changed. **Status: waiting at the GO/NO-GO gate.**

## What exists

- **No employer-sharing consent is recorded anywhere.** The only consent
  fields in the database are:
  - `profiles.advisor_data_consent` / `_at`: the member lets their advisor see portal data
  - `profiles.consent_accepted` / `consent_date`: the portal's Data Protection statement

  Neither covers sharing with an employer. Both live on `profiles`, and **none
  of the 13 Hollard clients has a portal account** (`member_user_id` is null
  for all), so they have no profile row at all.
- **Going final has exactly one path.** `advance_recommendation_finalise(p_id)`
  (SECURITY DEFINER, executable by `authenticated`) is the only code that sets
  `status = 'final'`. The table has RLS on with a single SELECT policy, so
  `authenticated` cannot update rows directly despite the table grants. There
  are no triggers. The Edge Function never finalises.
- **Nothing to grandfather.** `advance_recommendations` holds 6 drafts and 0 finals.
- Advisors already upload client documents into
  `advisor_clients.assessment->documents` (name, mime, size, dataUrl,
  uploadedAt). A signed consent form can be uploaded there today.

**Conclusion: a schema change is needed.** There is nowhere to record the consent.

## Proposal (for GO)

**New table `advance_share_consents`** (additive):

| column | meaning |
|---|---|
| `id` uuid pk | |
| `client_id` uuid → `advisor_clients(id)` | whose consent |
| `scope` text, check = `'advance_recommendation_to_employer'` | what it covers |
| `method` text, check in (`signed_form`, `in_portal`) | how it was given |
| `evidence_ref` text not null | e.g. the uploaded document's name / id, or "in-portal" |
| `granted_on` date not null | date on the form |
| `recorded_by` uuid (auth uid), `recorded_at` timestamptz | who captured it |
| `withdrawn_at` timestamptz null, `withdrawn_by` uuid null | withdrawal, never deletion |

- RLS on. One SELECT policy: `can_manage_advisor(advisor of client)`. No
  insert/update/delete policies; writes only through two RPCs.
- `advance_consent_record(p_client_id, p_method, p_evidence_ref, p_granted_on)`
  and `advance_consent_withdraw(p_consent_id)`, both gated by
  `can_manage_advisor()`, each writing a timeline system note.
- **The gate itself:** `advance_recommendation_finalise()` raises
  `'Member consent to share this report with the employer is not recorded'`
  unless an un-withdrawn consent exists for the client. The consent id relied
  on is stored on the report (new nullable column
  `advance_recommendations.consent_id`).
- **Defence in depth:** a BEFORE UPDATE trigger on `advance_recommendations`
  refusing `status → 'final'` without that consent. It also catches service-role
  and any future code path.
- Drafts, generate, edit, discard: unchanged.
- Advisor page: a "Consent to share with employer" panel on the Advance
  Recommendation view (record / withdraw, shows method, date and evidence).
  "Mark final" is disabled with the reason until consent exists. The database
  enforces it regardless.
- Security sweep: the two new RPCs are gated by `can_manage_advisor`, which is
  already in the sweep's regex. No `_` helpers.

**Rejected:** columns on `advisor_clients`. Advisors write that table directly
from the browser (`flushSaves`), so consent fields there would be settable with
no RPC, no audit and no withdrawal history.

**Rollback (to be written first):** drop the trigger, restore
`advance_recommendation_finalise` from `kw_fn_backup`, drop
`advance_recommendations.consent_id`, drop the RPCs and the table.

## Questions for the gate
1. **Evidence:** is a reference to an uploaded signed form enough, or must
   the form itself be uploaded before consent can be recorded (enforced)?
2. **Who may record it:** the client's own advisor, team leads and admins
   (the `can_manage_advisor` set)? Or admins only?
3. **Scope:** one consent per client covering all future Advance
   Recommendations, or one per report version?
4. **Withdrawal after a report went final:** record only (the report was
   already shared), or also flag the final report as "consent withdrawn"?
