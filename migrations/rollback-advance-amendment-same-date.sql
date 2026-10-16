-- Rollback: supabase_advance_amendment_same_date.sql (16 Oct 2026)
-- Written BEFORE the change was applied. MCP-safe (no DROP).
-- Restores _advance_amendment_of from kw_fn_backup tag
-- 'advance-amendment-same-date' (the 14 Oct body with rule 4: the advisor figure
-- must have changed after the last final). Reports already finalised as
-- amendments keep their amends_id.
do $$
declare r record; v_n int := 0;
begin
  for r in select b.definition from kw_fn_backup b
            where b.tag = 'advance-amendment-same-date' and b.proname = '_advance_amendment_of'
            order by b.taken_at asc, b.id asc limit 1
  loop
    execute r.definition; v_n := v_n + 1;
  end loop;
  if v_n <> 1 then raise exception 'no backup under advance-amendment-same-date'; end if;
end $$;
revoke execute on function public._advance_amendment_of(uuid) from public, anon, authenticated;
-- Verify: select prosrc like '%advance_overrides%' from pg_proc where proname = '_advance_amendment_of';  -- true
