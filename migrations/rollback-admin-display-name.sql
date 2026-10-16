-- Rollback: supabase_admin_display_name.sql (16 Oct 2026)
-- Written BEFORE the change was applied. MCP-safe (no DROP).
-- Restores the four note writers from kw_fn_backup tag 'admin-display-name'
-- (as they were with the role, before the admin-name fallback), and clears the
-- names. KEEPS the nullable admins.full_name column (additive). Notes already
-- written keep the name they were written with: notes are append-only.
do $$
declare r record; v_n int := 0;
begin
  for r in select distinct on (b.proname) b.definition from kw_fn_backup b
            where b.tag = 'admin-display-name'
            order by b.proname, b.taken_at asc, b.id asc
  loop
    execute r.definition; v_n := v_n + 1;
  end loop;
  if v_n <> 4 then raise exception 'expected 4 bodies under admin-display-name, found %', v_n; end if;
end $$;
update public.admins set full_name = null where full_name is not null;
-- Verify: select count(*) from pg_proc where prosrc like '%from admins where lower(email) = lower(v_email)%';  -- 0
