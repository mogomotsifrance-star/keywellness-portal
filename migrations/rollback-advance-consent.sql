-- ============================================================
-- ROLLBACK — supabase_advance_consent.sql (consent form before finalise)
-- Written 5 Oct 2026, before the forward migration was applied.
--
-- Part 1 (always): puts finalising back exactly as it was.
--   - drops the trigger that refuses status -> 'final' without a consent
--   - restores advance_recommendation_finalise() from kw_fn_backup tag
--     'advance-consent-gate' (the body captured just before the change)
--   - drops advance_consent_record()
--   After Part 1 an advisor can finalise with no consent form recorded again.
--
-- Part 2 (only when no consent has ever been recorded): removes the table,
--   the column and the index. If even one consent row exists, Part 2 does
--   nothing and says so. A recorded consent form is evidence that an
--   employee agreed to their report going to HR; a rollback must not
--   destroy it. Remove those by hand, deliberately, if that is ever wanted.
--
-- ALSO REVERT: the advisor.html commit (consent panel). With Part 1 only, the
-- page still works: it reads advance_consents and consent_id, which Part 1
-- keeps. With Part 2 as well, the page's report list query names consent_id
-- and fails, so revert the page first.
-- ============================================================

begin;

-- ── Part 1 ───────────────────────────────────────────────────
drop trigger if exists advance_recommendations_final_needs_consent on public.advance_recommendations;
drop function if exists public.kw_advance_final_needs_consent();

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

drop function if exists public.advance_consent_record(uuid, date);

-- ── Part 2 ───────────────────────────────────────────────────
do $$
begin
  if to_regclass('public.advance_consents') is null then
    raise notice 'advance_consents already gone';
  elsif exists (select 1 from public.advance_consents) then
    raise notice 'advance_consents holds % row(s): KEPT, with advance_recommendations.consent_id. Part 1 is done; finalising is ungated.',
      (select count(*) from public.advance_consents);
  else
    drop index if exists public.advance_recommendations_one_final_per_consent;
    alter table public.advance_recommendations drop column if exists consent_id;
    drop table public.advance_consents;
    raise notice 'advance_consents was empty: table, column and index removed';
  end if;
end $$;

commit;

-- Verify (expect: finalise_has_consent_check = false, trigger_left = 0, record_fn_left = 0)
select (select prosrc like '%advance_consents%' from pg_proc where proname = 'advance_recommendation_finalise') as finalise_has_consent_check,
       (select count(*) from pg_trigger where tgname = 'advance_recommendations_final_needs_consent') as trigger_left,
       (select count(*) from pg_proc where proname = 'advance_consent_record') as record_fn_left;
