-- ============================================================
-- Rollback: supabase_advance_recommendation.sql
-- ============================================================
-- Removes the Advance Recommendation table and its five RPCs. Nothing
-- else was touched by the forward migration, so nothing else is undone.
--
-- WHAT IS LOST: every generated Advance Recommendation Report (drafts and
-- finals) and their input/computed audit snapshots. The system notes
-- written into advisor_notes ("Advance Recommendation v1 generated…")
-- are left in place deliberately — they are part of the client's
-- timeline and record that a generation happened, even if the report
-- itself is gone. Delete them by hand only if that is what you want:
--   delete from advisor_notes where origin = 'system'
--     and body like 'Advance Recommendation v%';
--
-- Also delete the Edge Function if you are backing the feature out:
--   supabase functions delete advance-recommendation
-- and remove the Report-tab UI from advisor.html (git revert).
-- ============================================================

drop function if exists public.advance_recommendation_discard(uuid);
drop function if exists public.advance_recommendation_finalise(uuid);
drop function if exists public.advance_recommendation_update(uuid, jsonb, jsonb);
drop function if exists public.advance_recommendation_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text);
drop function if exists public.advance_recommendation_can_generate();

drop policy if exists advance_recommendations_read on public.advance_recommendations;
drop table if exists public.advance_recommendations;

-- Verify: all three should return zero rows.
-- select proname from pg_proc where proname like 'advance_recommendation_%';
-- select tablename from pg_tables where tablename = 'advance_recommendations';
-- select policyname from pg_policies where tablename = 'advance_recommendations';
