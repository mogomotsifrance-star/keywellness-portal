-- ============================================================
-- Rollback: supabase_debt_rehab_plan.sql
-- ============================================================
-- Removes the Debt Rehab Plan table and its six RPCs. Nothing else was
-- touched by the forward migration, so nothing else is undone.
--
-- WHAT IS LOST: every generated Debt Rehab Plan (drafts and finals) and
-- their input/computed audit snapshots. The system notes written into
-- advisor_notes ("Debt Rehab Plan v1 generated…") are left in place
-- deliberately — they are part of the client's timeline. Delete them by
-- hand only if that is what you want:
--   delete from advisor_notes where origin = 'system'
--     and body like 'Debt Rehab Plan v%';
--
-- Also delete the Edge Function if you are backing the feature out:
--   supabase functions delete debt-rehab-plan
-- and remove the Report-tab UI from advisor.html (git revert).
-- ============================================================

drop function if exists public.debt_rehab_plan_discard(uuid);
drop function if exists public.debt_rehab_plan_finalise(uuid);
drop function if exists public.debt_rehab_plan_update(uuid, jsonb, jsonb);
drop function if exists public.debt_rehab_plan_list(uuid);
drop function if exists public.debt_rehab_plan_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text);
drop function if exists public.debt_rehab_plan_can_generate();

drop table if exists public.debt_rehab_plans;

-- Verify: all three should return zero rows.
-- select proname from pg_proc where proname like 'debt_rehab_plan_%';
-- select tablename from pg_tables where tablename = 'debt_rehab_plans';
-- select policyname from pg_policies where tablename = 'debt_rehab_plans';
