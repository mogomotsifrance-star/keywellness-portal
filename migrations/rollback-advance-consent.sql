-- ============================================================
-- ROLLBACK — supabase_advance_consent.sql (consent form before finalise)
-- Written 5 Oct 2026, before the forward migration was applied.
--
-- Puts finalising back exactly as it was, WITHOUT a single DROP statement,
-- so it can be run through the Supabase MCP tool (which holds any DROP for a
-- confirmation it cannot show) as well as in the SQL editor:
--   - restores advance_recommendation_finalise() from kw_fn_backup tag
--     'advance-consent-gate' (the body captured just before the change)
--   - DISABLES the trigger that refuses status -> 'final' without a consent
--   - revokes advance_consent_record() from everyone, so nobody can call it
-- After this an advisor can finalise with no consent form recorded again.
--
-- KEPT on purpose: advance_consents and advance_recommendations.consent_id. A
-- recorded consent form is evidence that an employee agreed to their report
-- going to HR; a rollback must not destroy it. The page keeps working: it
-- still reads both.
--
-- Removing the table, column, trigger and function entirely is a separate,
-- deliberate step: migrations/cleanup-advance-consent.sql (SQL editor only,
-- and only while no consent has ever been recorded).
--
-- ALSO REVERT: the advisor.html commit (consent panel), or advisors will see a
-- panel and a disabled button the database no longer enforces.
-- ============================================================

begin;

do $$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select distinct on (b.proname, b.identity_args) b.definition
      from kw_fn_backup b
     where b.tag = 'advance-consent-gate' and b.proname = 'advance_recommendation_finalise'
     order by b.proname, b.identity_args, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception 'expected 1 backed-up advance_recommendation_finalise under advance-consent-gate, found %', v_n;
  end if;
end $$;

-- execute of a CREATE OR REPLACE keeps the existing ACL; restate it anyway.
revoke execute on function public.advance_recommendation_finalise(uuid) from public, anon;
grant  execute on function public.advance_recommendation_finalise(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_trigger where tgname = 'advance_recommendations_final_needs_consent') then
    alter table public.advance_recommendations disable trigger advance_recommendations_final_needs_consent;
  end if;
  if to_regprocedure('public.advance_consent_record(uuid,date)') is not null then
    revoke execute on function public.advance_consent_record(uuid, date) from public, anon, authenticated;
  end if;
end $$;

commit;

-- Verify (expect: finalise_has_consent_check = false, trigger_enabled = 'D' or none,
-- record_callable_by_authenticated = false, consent_rows_kept = whatever was recorded)
select (select prosrc like '%advance_consents%' from pg_proc where proname = 'advance_recommendation_finalise') as finalise_has_consent_check,
       (select tgenabled from pg_trigger where tgname = 'advance_recommendations_final_needs_consent') as trigger_enabled,
       (select has_function_privilege('authenticated', p.oid, 'EXECUTE') from pg_proc p where p.proname = 'advance_consent_record') as record_callable_by_authenticated,
       (select count(*) from public.advance_consents) as consent_rows_kept;
