# Batch 1 discovery: what a linked member can read in `advisor_clients` (14 Oct 2026)

Read-only. Live project `tarmpqxsabbehgjaonfz`, plus a search of every page,
script and Edge Function in the repo.

## How a member reaches the row

| Path | What it is | Member access? |
|---|---|---|
| Policy `advisor_clients_member_read` | `SELECT ... USING (member_user_id = auth.uid())` | **Yes: the whole row**, every column and the whole `assessment` JSON |
| Policies `advisor_clients_own*`, `_lead_all`, `_admin_all` | advisor / team lead / admin | No |
| Other tables' policies that sub-query `advisor_clients` (`advance_*`, `advisor_notes`, `bookings`, `document_access_log`) | all gated on `can_manage_advisor()`, `current_advisor_id()`, `is_admin()` or `is_team_lead()` | No, and none depends on the member policy |
| SECURITY DEFINER RPCs that read the table | all advisor/admin-gated (`advisor_*`, `admin_*`), or triggers | No |
| Edge Functions `advance-recommendation`, `debt-rehab-plan` | read the row **as the caller** | Through the member policy, yes: a linked member could call `debt-rehab-plan` preview with their client id. `advance-recommendation` v7 already refuses them at `advance_override_effective()` |

Table privileges are the Supabase defaults (anon and authenticated hold
SELECT etc.); RLS is what decides, as everywhere else in the project.

## What member pages use from the row

**Nothing.** No member page (`index.html`, the tool pages, `kw-*.js`, `js/`)
queries `advisor_clients` or calls an RPC that returns it. The advisor-related
call the member portal makes is `advisor_me()` (am I an advisor?), which does
not touch the table.

## Field classification

All 26 rows are `source = 'advisor_added'`: the advisor creates the record
and types it during the consultation. 2 are linked to a member account
(`member_user_id`), 1 of those has documents.

| Field | Who writes it | Class |
|---|---|---|
| `assessment.notes` (debt, income, expense, general, lifestyle) | advisor | **advisor-authored notes** (4 rows non-empty) |
| `assessment.consultationNotes` | advisor | **advisor-authored notes** (0 rows non-empty today) |
| `assessment._owner`, `assessment._org` | advisor portal | advisor metadata |
| `assessment.personal`, `income`, `liabilities`, `budget`, `assets`, `savings`, `businesses`, `kids`, `risk`, `lifeVision`, `email`, `phone` | advisor, typed in session | advisor's consultation record of the member |
| `assessment.documents` | advisor (Documents tab upload) | advisor-uploaded; members have no upload path |
| columns `first_name`, `last_name`, `email`, `phone`, `status`, `source`, `org_*`, `advisor_id`, `created_by`, `linked_at` | advisor / triggers | advisor record |

**Member-authored fields in this table: none.** A member's own submitted
answers live in `profiles`, `assessments`, `checkins` and `tool_data`, which
this change does not touch. There are no member-uploaded documents anywhere in
the portal.

## Consequence for the change

The brief asks for a member-safe SECURITY DEFINER RPC, then removal of member
SELECT on the raw row. With no member-authored field and no member page
reading the row, that RPC would return nothing a member page uses. **Decision:
do not build it** (an RPC nobody calls is one more gated surface to keep right).
Turn the member policy off instead; member pages need no switch, so the
"page first, policy second" ordering is satisfied trivially.

If a member page ever needs to show the member something from the advisor's
record, build the RPC then, returning named fields only.
