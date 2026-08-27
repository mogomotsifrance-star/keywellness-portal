-- ============================================================
-- Rollback — M5a: ops_timeline()
-- Reverses supabase_m5a_ops_timeline.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
-- Adds no table and no column, so there is no data to restore.
--
-- ops_timeline goes first: it calls _ops_as_date, and dropping a function
-- another function's body references is allowed, but dropping them in
-- dependency order keeps the intent obvious.
-- ============================================================

drop function if exists ops_timeline(date, date);
drop function if exists _ops_as_date(text);


do $$
declare
  n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('ops_timeline', '_ops_as_date');

  if n <> 0 then
    raise exception 'M5a rollback incomplete: % object(s) left behind', n;
  end if;

  raise notice 'M5a rollback clean: zero leftover objects.';
end $$;
