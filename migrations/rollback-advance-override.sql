-- Rollback: supabase_advance_override.sql (13 Oct 2026)
-- ============================================================
-- Written BEFORE the migration was applied. Runs through the Supabase MCP
-- tool (no DROP).
--
-- ORDER MATTERS:
--   1. Redeploy the Edge Function advance-recommendation from the commit
--      before the override (v5 code, commit 6002a45 or earlier). The new code
--      calls advance_override_effective() and refuses to generate if it
--      cannot, so revoking first would stop all report generation.
--   2. Revert the advisor.html commit (the override panel).
--   3. Run this file.
--
-- Effect: no RPC can read or write overrides or internal notes any more,
-- and the finalise guard is off, so any draft can be marked final again
-- (subject to the consent gate, which is untouched).
--
-- KEEPS every override, use-of-funds line and internal note: they are the
-- track record. For full removal see cleanup-advance-override.sql.
-- ============================================================
revoke execute on function public.advance_override_get(uuid)                                  from public, anon, authenticated;
revoke execute on function public.advance_override_save(uuid, uuid, numeric, text, jsonb)     from public, anon, authenticated;
revoke execute on function public.advance_override_remove(uuid, text)                         from public, anon, authenticated;
revoke execute on function public.advance_internal_note_add(uuid, text, uuid)                 from public, anon, authenticated;
revoke execute on function public.advance_override_effective(uuid)                            from public, anon, authenticated;

alter table public.advance_recommendations disable trigger advance_override_finalise_guard;

-- Verify:
-- select proname, has_function_privilege('authenticated', oid, 'EXECUTE') from pg_proc
--  where proname like 'advance_override_%' or proname = 'advance_internal_note_add';      -- all false
-- select tgenabled from pg_trigger where tgname = 'advance_override_finalise_guard';        -- 'D'
