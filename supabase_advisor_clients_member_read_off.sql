-- ============================================================
-- Key Wellness: advisor notes are advisor-only (Batch 1, 14 Oct 2026)
-- ============================================================
-- Decision (Tshenolo, 13 Oct 2026): advisor notes are visible to advisors,
-- team leads and admins only. A member linked to a client record must not
-- read the advisor's consultation notes or any other advisor-authored content.
--
-- advisor_clients_member_read let a linked member SELECT the whole
-- advisor_clients row: the advisor's notes, the consultation figures, the
-- uploaded documents. Discovery (docs/build/BATCH-1-ADVISOR-NOTES-PRIVACY-
-- FINDINGS.md) found no member page that reads it and no member-authored field
-- in it, so nothing replaces it.
--
-- APPROVED EXCEPTION to additive-only: this changes one existing policy. It is
-- altered to USING (false), not dropped, so that (a) the Supabase MCP tool can
-- run it (it cannot run DROP) and (b) the rollback restores the exact old text
-- under the same name. A policy that grants nothing is equivalent to no policy
-- under RLS (policies are OR-ed; false contributes nothing).
--
-- Rollback: migrations/rollback-advisor-clients-member-read-off.sql
-- ============================================================

alter policy advisor_clients_member_read on public.advisor_clients
  using (false);

comment on policy advisor_clients_member_read on public.advisor_clients is
  'Disabled 14 Oct 2026 (USING false): advisor records are advisor/team lead/admin only. Was (member_user_id = auth.uid()). See supabase_advisor_clients_member_read_off.sql.';

-- Verify (read-only):
-- select qual from pg_policies where tablename = 'advisor_clients' and policyname = 'advisor_clients_member_read';  -- false
