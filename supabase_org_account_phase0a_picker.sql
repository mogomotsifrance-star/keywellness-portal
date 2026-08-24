-- ============================================================
-- Key Wellness — Organisation Account View, PHASE 0a
-- Run in the Supabase SQL Editor AFTER supabase_org_account_phase0.sql.
-- Safe to re-run.
--
-- Rollback: migrations/rollback-org-account-phase0a-picker.sql
--
-- ------------------------------------------------------------
-- WHY THIS EXISTS
--
-- Phase 0 made org attribution mandatory in the database. Three code
-- paths still insert advisor clients without it, so each now fails with
-- a raw constraint error the moment the member has no organisation:
--
--   1. advisor.html's add-client form  — sends no org at all
--   2. advisor.html's import-client    — same
--   3. advisor_add_member_client() and admin_assign_client() — both copy
--      org_id from the member profile, which is NULL for anyone who
--      signed up but has not entered an invite code
--
-- (1) and (2) need a picker in the UI, and a picker needs something to
-- read: an advisor has NO RLS read on `organizations` or `org_units`.
-- `org_units_read` grants only the member's own org, the employer's own
-- org, or admin — an advisor is none of those, by design. Hence a
-- SECURITY DEFINER options function rather than widening a policy.
--
-- (3) is fixed here, server-side, because the caller never sees the
-- organisation at all.
-- ------------------------------------------------------------


-- ── 1. What an advisor may attach a client to ────────────────
-- Mirrors the member picker's rules exactly, and for the same reasons:
--   * only active organisations
--   * only leaf units — a company that has sites is not selectable
--   * a site under a CLOSED company is invisible, even if it is itself
--     active (the rule org_units already enforces for members)
--
-- Returns organisations with no units too: those are attributed at
-- organisation level, with no site.

create or replace function advisor_org_options()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_out jsonb;
begin
  if not (is_advisor() or is_admin()) then
    raise exception 'not authorised';
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'org_id', o.id,
             'name',   o.name,
             'units',  coalesce(u.units, '[]'::jsonb)
           ) order by o.name), '[]'::jsonb)
    into v_out
  from organizations o
  left join lateral (
    select jsonb_agg(jsonb_build_object('id', x.id, 'label', x.label)
                     order by x.label) as units
    from (
      select ou.id, kw_unit_label(ou.id) as label
      from org_units ou
      left join org_units par on par.id = ou.parent_unit_id
      where ou.org_id = o.id
        and ou.is_active
        and (par.id is null or par.is_active)          -- no orphan sites
        and not exists (select 1 from org_units c      -- leaves only
                         where c.parent_unit_id = ou.id and c.is_active)
    ) x
  ) u on true
  where o.is_active;

  return v_out;
end;
$$;

comment on function advisor_org_options() is
  'Organisations and selectable sites for the advisor add-client picker. Advisors have no RLS read on either table.';

grant execute on function advisor_org_options() to authenticated;


-- ── 2. Adding an existing portal member as a client ──────────
-- Both functions copied org_id from the member profile and stopped
-- there. A member who has signed up but never entered an invite code has
-- no org, which now violates advisor_clients_org_required. Declaring
-- no_org is the honest reading: we know who they are, and we know they
-- are not under a company programme yet.
--
-- When they later enter an invite code, trg_sync_advisor_client_org
-- picks the organisation up and clears no_org automatically. Nothing
-- needs to be corrected by hand.

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
  v_unit    uuid;
begin
  if v_advisor is null then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = v_advisor and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;   -- idempotent
  end if;

  select u.email, p.first_name, p.last_name, p.org_id, p.org_unit_id
    into v_email, v_fn, v_ln, v_org, v_unit
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email,
     org_id, org_unit_id, no_org, source, linked_at, created_by)
  values
    (v_advisor, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, case when v_org is null then null else v_unit end,
     v_org is null, 'advisor_added', now(), auth.uid())
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
  v_unit  uuid;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = p_advisor_id and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;
  end if;

  select u.email, p.first_name, p.last_name, p.org_id, p.org_unit_id
    into v_email, v_fn, v_ln, v_org, v_unit
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email,
     org_id, org_unit_id, no_org, source, linked_at, created_by)
  values
    (p_advisor_id, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, case when v_org is null then null else v_unit end,
     v_org is null, 'admin_assigned', now(), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function admin_assign_client(uuid, uuid) to authenticated;


-- ── 3. Verification ──────────────────────────────────────────
--
-- 3a. As a signed-in advisor, the picker has something in it:
--   select advisor_org_options();
--
-- 3b. Leaf rule holds — a company with active sites must not appear in
--     its own units list, and its sites must:
--   select o->>'name' as org,
--          jsonb_array_length(o->'units') as selectable_sites
--     from jsonb_array_elements(advisor_org_options()) o;
--
-- 3c. Adding an org-less member no longer breaks. On a test member with
--     profiles.org_id IS NULL:
--   select advisor_add_member_client('<user_id>');
--   select no_org, org_id from advisor_clients where member_user_id = '<user_id>';
--   -- expect: no_org = true, org_id = null, and no constraint error
--
-- 3d. And it self-corrects when they join an organisation:
--   update profiles set org_id = '<org_id>' where id = '<user_id>';
--   select no_org, org_id from advisor_clients where member_user_id = '<user_id>';
--   -- expect: no_org = false, org_id set, by trg_sync_advisor_client_org
-- ============================================================
