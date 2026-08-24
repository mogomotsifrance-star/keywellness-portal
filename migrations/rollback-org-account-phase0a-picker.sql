-- ============================================================
-- ROLLBACK — Organisation Account View, Phase 0a
-- Reverses supabase_org_account_phase0a_picker.sql. Safe to re-run.
--
-- ORDERING WARNING. Phase 0a exists because Phase 0's constraint made
-- three insert paths fail. Rolling 0a back on its own puts two of those
-- failures straight back: advisor_add_member_client() and
-- admin_assign_client() will again raise advisor_clients_org_required
-- for any member who has no organisation.
--
-- So roll back 0a ONLY as part of rolling back Phase 0:
--
--   1. migrations/rollback-org-account-phase0a-picker.sql   (this file)
--   2. migrations/rollback-org-account-phase0.sql
--
-- If you only want to undo the picker UI, revert advisor.html and leave
-- this SQL in place — none of it does harm while Phase 0 is applied.
-- ============================================================


-- ── 1. The picker options function ───────────────────────────

drop function if exists advisor_org_options();


-- ── 2. Restore the two member-add RPCs to their pre-0a form ──
-- These copy org_id from the member profile and nothing else, which is
-- how they stood before Phase 0a.

create or replace function advisor_add_member_client(p_member_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_advisor uuid := current_advisor_id();
  v_id      uuid;
  v_email   text;
  v_fn      text;
  v_ln      text;
  v_org     uuid;
begin
  if v_advisor is null then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = v_advisor and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;   -- idempotent
  end if;

  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values
    (v_advisor, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, 'advisor_added', now(), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function advisor_add_member_client(uuid) to authenticated;


create or replace function admin_assign_client(p_advisor_id uuid, p_member_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id    uuid;
  v_email text;
  v_fn    text;
  v_ln    text;
  v_org   uuid;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = p_advisor_id and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;
  end if;

  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values
    (p_advisor_id, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, 'admin_assigned', now(), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function admin_assign_client(uuid, uuid) to authenticated;


-- ── 3. Verify ────────────────────────────────────────────────
--
--   select count(*) as should_be_zero from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'advisor_org_options';
--
--   select count(*) as should_be_zero from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('advisor_add_member_client','admin_assign_client')
--      and pg_get_functiondef(p.oid) like '%no_org%';
-- ============================================================
