-- Rollback for supabase_admin_delete_user.sql
--
-- READ THIS FIRST: the FUNCTIONS roll back completely. The support_actions
-- schema change rolls back only if nothing has used it yet, and that is
-- deliberate.
--
--   * Dropping actor_email / target_email would destroy the only remaining
--     record of who did what, for any audit row whose account has since been
--     deleted. So the columns are dropped ONLY when every row still resolves
--     through its uuid. Otherwise they are kept, and this script says so.
--
--   * actor goes back to NOT NULL only if no row has a null actor. A null
--     actor means an account was deleted while this feature was live; forcing
--     NOT NULL would require inventing an actor or removing an audit row, and
--     neither is acceptable.
--
--   * 'delete_user' stays in the action check constraint if any row uses it.
--     A CHECK that its own table violates is not a rollback, it is a
--     time bomb for the next writer.
--
-- Deleted ACCOUNTS are not restored by anything here. auth.users rows, their
-- password hashes and their member data are gone — same as
-- migrations/rollback-delete-account-france-prolearn.sql, and for the same
-- reason: an account is re-created through Supabase Auth, with a new uuid.
--
-- Safe to re-run.

begin;

-- ── 1. The two RPCs and their helpers ───────────────────────

drop function if exists admin_user_delete(uuid, text, uuid);
drop function if exists admin_user_delete_preview(uuid, text);
drop function if exists _admin_user_refs(uuid);
drop function if exists _admin_user_delete_plan();


-- ── 2. support_log() / support_recent() as they were ────────
-- Transcribed from the LIVE definitions as read on 28 Aug 2026, not from
-- supabase_support_audit.sql. That file still gates both on is_ops_admin(),
-- which M4a deleted when it re-pointed every call site at is_admin(). Copying
-- the original text back would restore a call to a function that no longer
-- exists and break the Support screen on the next click.

create or replace function support_log(
  p_action         text,
  p_outcome        text,
  p_target_user    uuid default null,
  p_target_booking uuid default null,
  p_detail         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;
  if auth.uid() is null then
    raise exception 'no caller identity';
  end if;

  insert into support_actions (actor, action, target_user, target_booking, outcome, detail)
  values (auth.uid(), p_action, p_target_user, p_target_booking, p_outcome,
          left(coalesce(p_detail, ''), 500))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function support_log(text, text, uuid, uuid, text) to authenticated;

create or replace function support_recent(p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id,
             'at', s.created_at,
             'actor', au.email,
             'action', s.action,
             'target', tu.email,
             'outcome', s.outcome,
             'detail', s.detail
           ) order by s.created_at desc)
      from (select * from support_actions
             order by created_at desc
             limit greatest(1, least(coalesce(p_limit, 50), 200))) s
      left join auth.users au on au.id = s.actor
      left join auth.users tu on tu.id = s.target_user
  ), '[]'::jsonb);
end $$;

grant execute on function support_recent(int) to authenticated;


-- ── 3. The audit table, only as far as it is safe to go ─────

do $$
declare
  v_used_action  int;
  v_null_actor   int;
  v_orphan_actor int;
  v_orphan_targ  int;
  r              record;
begin
  select count(*) into v_used_action from support_actions where action = 'delete_user';
  select count(*) into v_null_actor  from support_actions where actor is null;
  select count(*) into v_orphan_actor from support_actions s
   where s.actor_email is not null
     and not exists (select 1 from auth.users u where u.id = s.actor);
  select count(*) into v_orphan_targ from support_actions s
   where s.target_email is not null
     and not exists (select 1 from auth.users u where u.id = s.target_user);

  -- The action check.
  if v_used_action = 0 then
    alter table support_actions drop constraint if exists support_actions_action_check;
    alter table support_actions add constraint support_actions_action_check
      check (action in ('lookup','send_password_reset','resend_booking_confirmation'));
    raise notice 'rollback: action check narrowed back to the original three';
  else
    raise notice 'rollback: KEPT ''delete_user'' in the action check — % row(s) use it',
                 v_used_action;
  end if;

  -- The identity columns, and only if nothing depends on them.
  if v_orphan_actor = 0 and v_orphan_targ = 0 then
    alter table support_actions drop column if exists actor_email;
    alter table support_actions drop column if exists target_email;
    raise notice 'rollback: actor_email / target_email dropped (every row still resolves)';
  else
    raise notice 'rollback: KEPT actor_email / target_email — % actor and % target row(s) '
                 'no longer resolve through auth.users; the address is all that is left',
                 v_orphan_actor, v_orphan_targ;
  end if;

  -- NOT NULL and the delete rules.
  if v_null_actor = 0 then
    alter table support_actions alter column actor set not null;
    for r in
      select c.conname, a.attname
        from pg_constraint c
        join lateral unnest(c.conkey) k(attnum) on true
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
       where c.contype   = 'f'
         and c.conrelid  = 'public.support_actions'::regclass
         and c.confrelid = 'auth.users'::regclass
    loop
      execute format('alter table support_actions drop constraint %I', r.conname);
      execute format('alter table support_actions add constraint %I foreign key (%I) '
                     'references auth.users(id)', r.conname, r.attname);
    end loop;
    raise notice 'rollback: actor back to NOT NULL, both FKs back to NO ACTION';
  else
    raise notice 'rollback: KEPT actor nullable — % row(s) record an account that has '
                 'since been deleted', v_null_actor;
  end if;
end $$;

commit;
