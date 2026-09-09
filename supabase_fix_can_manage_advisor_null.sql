-- ============================================================
-- Key Wellness — can_manage_advisor() must return FALSE, never NULL
-- ============================================================
-- Found 3 Sep 2026 while writing the Debt Rehab Plan's RLS tests.
--
-- can_manage_advisor(p) is
--     p is not null and (p = current_advisor_id() or is_team_lead() or is_admin())
-- For a caller with NO advisors row — a member, an HR user, any signed-in
-- account that is not an advisor — current_advisor_id() is NULL, so
-- `p = NULL` is NULL, `NULL or false or false` is NULL, and the whole
-- expression is NULL rather than FALSE.
--
-- In a policy's USING clause NULL is treated as false, so the SELECT
-- policies hold. But seventeen RPCs gate with
--     if not can_manage_advisor(v_owner) then raise exception ...
-- and `if not NULL` is `if NULL`, which does not raise. Those RPCs therefore
-- let a non-advisor through: advisor_client_notes(), advisor_note_add(),
-- advance_recommendation_create/update/finalise/discard() and the rest. A
-- member who knows their own advisor_clients.id (they can read that row)
-- can read the advisor's private notes on themselves and generate an
-- Advance Recommendation in their own name.
--
-- The fix is one coalesce, in the gate itself, so every call site is
-- covered at once. Same signature, same grants, same semantics for every
-- caller that already got true or false.
--
-- Apply BEFORE supabase_debt_rehab_plan.sql (which does not need it — its
-- RPCs test `is distinct from true` — but everything older does).
-- Rollback: migrations/rollback-fix-can-manage-advisor-null.sql
-- ============================================================
create or replace function can_manage_advisor(p_advisor_id uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce(
    p_advisor_id is not null
      and (p_advisor_id = current_advisor_id() or is_team_lead() or is_admin()),
    false);
$$;
comment on function can_manage_advisor(uuid) is
  'The advisor who holds the caseload, any team lead, or an admin. Returns FALSE (never NULL) for a caller with no advisors row — the RPC gates are written `if not can_manage_advisor(...)`, and `if not NULL` does not raise.';

-- Verify, as a member (no advisors row):
--   select can_manage_advisor('<any advisor id>');   -- false, not null
