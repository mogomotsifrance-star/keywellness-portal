-- ============================================================
-- CLEANUP after rollback-advance-consent.sql — SQL EDITOR ONLY
--
-- Removes the consent objects entirely. Run it only if the consent change is
-- being abandoned AND no consent form has ever been recorded: it refuses
-- otherwise, because those rows are evidence of an employee's agreement.
-- Contains DROP statements, so it will not run through the Supabase MCP tool.
-- ============================================================
begin;
do $$
begin
  if to_regclass('public.advance_consents') is not null and exists (select 1 from public.advance_consents) then
    raise exception 'advance_consents holds % row(s): not removing evidence. Decide what to do with them first.',
      (select count(*) from public.advance_consents);
  end if;
end $$;
drop trigger if exists advance_recommendations_final_needs_consent on public.advance_recommendations;
drop function if exists public.kw_advance_final_needs_consent();
drop function if exists public.advance_consent_record(uuid, date);
drop index if exists public.advance_recommendations_one_final_per_consent;
alter table public.advance_recommendations drop column if exists consent_id;
drop table if exists public.advance_consents;
commit;
