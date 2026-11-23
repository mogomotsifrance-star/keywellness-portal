-- Rollback for supabase_household_override_guard.sql. Restores both bodies
-- from kw_fn_backup. CREATE OR REPLACE keeps the grants. Safe to run twice.
begin;
do $$
declare r record;
begin
  if (select count(*) from kw_fn_backup where tag = 'household-override-guard') <> 2 then
    raise exception 'expected two bodies in kw_fn_backup under household-override-guard';
  end if;
  for r in select definition from kw_fn_backup where tag = 'household-override-guard' loop
    execute r.definition;
  end loop;
end $$;
commit;
