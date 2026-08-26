-- ============================================================
-- Rollback — member support: the audit trail and its gate
-- Reverses supabase_support_audit.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- THIS DELETES THE AUDIT TRAIL. support_actions is the record of who ran a
-- password reset for whom. If any real support action has been taken, export
-- it before rolling back:
--
--   select * from support_actions order by created_at;
--
-- The table is dropped rather than kept, because a rollback that leaves an
-- orphan table behind is not a rollback and the harness fails it.
--
-- ORDER: the policy and the functions go before the table, because the policy
-- depends on is_ops_admin() and PostgreSQL refuses to drop a function a live
-- policy needs. That is the same trap the M5 rollback hit.
-- ============================================================

drop policy if exists support_actions_admin_read on support_actions;

drop function if exists support_recent(int);
drop function if exists support_log(text, text, uuid, uuid, text);
drop function if exists support_can(text, uuid);
drop function if exists support_lookup(text);

drop table if exists support_actions;

-- Last: nothing refers to it now.
drop function if exists is_ops_admin();


do $$
declare n int;
begin
  select
      (select count(*) from pg_tables
        where schemaname = 'public' and tablename = 'support_actions')
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public'
          and p.proname in ('is_ops_admin','support_lookup','support_can',
                            'support_log','support_recent'))
    + (select count(*) from pg_policies
        where schemaname = 'public' and tablename = 'support_actions')
    into n;

  if n <> 0 then
    raise exception 'support rollback incomplete: % object(s) left behind', n;
  end if;

  raise notice 'support rollback clean: zero leftover objects.';
end $$;
