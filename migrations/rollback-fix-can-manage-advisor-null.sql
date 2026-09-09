-- ============================================================
-- Rollback: supabase_fix_can_manage_advisor_null.sql
-- ============================================================
-- Restores the body from supabase_advisor_team_lead.sql. NOTE: this
-- reopens the hole that file describes — a caller with no advisors row
-- gets NULL from the gate and `if not can_manage_advisor(...)` does not
-- raise. Only roll this back if the fix itself broke something.
-- ============================================================
create or replace function can_manage_advisor(p_advisor_id uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select p_advisor_id is not null
     and (p_advisor_id = current_advisor_id() or is_team_lead() or is_admin());
$$;
comment on function can_manage_advisor(uuid) is null;
