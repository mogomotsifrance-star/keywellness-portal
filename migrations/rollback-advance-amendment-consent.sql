-- Rollback: supabase_advance_amendment_consent.sql (14 Oct 2026)
-- ============================================================
-- Written BEFORE the migration was applied. MCP-safe (no DROP).
--
-- Restores advance_recommendation_finalise(uuid) and
-- kw_advance_final_needs_consent() from kw_fn_backup tag
-- 'advance-amendment-consent' (the 5 Oct consent-gate bodies captured just
-- before the change), and revokes advance_finalise_basis(uuid).
-- After this, every final again needs its own recorded consent form.
--
-- KEPT on purpose: the amends_id column and any report finalised as an
-- amendment (it is a record of what went to HR and on which consent), and the
-- two private helpers (already revoked from everyone).
--
-- ALSO REVERT the advisor.html commit for Batch 2, or the consent panel will
-- offer "existing consent applies" for a finalise the database now refuses.
-- ============================================================
do $$
declare r record; v_n int := 0;
begin
  for r in
    select distinct on (b.proname) b.definition
      from kw_fn_backup b
     where b.tag = 'advance-amendment-consent'
       and b.proname in ('advance_recommendation_finalise', 'kw_advance_final_needs_consent')
     order by b.proname, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
  end loop;
  if v_n <> 2 then
    raise exception 'expected 2 backed-up bodies under advance-amendment-consent, found %', v_n;
  end if;
end $$;

revoke execute on function public.advance_recommendation_finalise(uuid) from public, anon;
grant  execute on function public.advance_recommendation_finalise(uuid) to authenticated;
revoke execute on function public.advance_finalise_basis(uuid) from public, anon, authenticated;

-- Verify:
-- select prosrc like '%amends_id%' from pg_proc where proname in ('advance_recommendation_finalise','kw_advance_final_needs_consent');  -- false, false
