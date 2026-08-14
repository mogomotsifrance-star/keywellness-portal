-- ============================================================
-- Key Wellness — Roles & Access RPCs for the admin dashboard
--
-- Backs the new "Roles & Access" tab in admin.html, so admins can
-- grant/revoke the Admin and HR roles from the UI instead of running
-- SQL in the Supabase editor. (Advisors already have UI on the
-- Advisors tab; members join themselves via signup.)
--
-- Everything goes through SECURITY DEFINER functions guarded by
-- is_admin(), so this works regardless of table grants / RLS state
-- on `admins`, `employers` and `hr_unit_scope`.
--
-- Run in the Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- PRODUCTION-LIVE on apply — but inert until admin.html ships, and
-- every function is admin-gated, so applying early is safe.
-- ROLLBACK: migrations/rollback-admin-roles-rpcs.sql
-- ============================================================


-- ── 1. Overview — everything the Roles tab needs in one call ──
-- {admins:[{email,registered}],
--  hr:[{id,email,org_id,org_name,units:[names],registered}],
--  orgs:[{id,name}], units:[{id,org_id,parent_unit_id,name}]}
-- `units` on an hr row is [] when their scope is the whole org
-- (mirrors hr_scoped_unit_ids(): a whole-org row wins over unit rows).
create or replace function admin_roles_overview()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  return jsonb_build_object(
    'admins', coalesce((
      select jsonb_agg(jsonb_build_object(
        'email',      lower(a.email),
        'registered', exists (select 1 from auth.users u
                              where lower(u.email) = lower(a.email))
      ) order by lower(a.email))
      from admins a), '[]'::jsonb),

    'hr', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',         e.id,
        'email',      lower(coalesce(e.email, au.email)),
        'org_id',     e.org_id,
        'org_name',   o.name,
        'registered', (e.user_id is not null
                       or exists (select 1 from auth.users u
                                  where lower(u.email) = lower(e.email))),
        'units', coalesce((
          select jsonb_agg(ou.name order by ou.name)
          from hr_unit_scope s
          join org_units ou on ou.id = s.unit_id
          where s.org_id = e.org_id
            and s.unit_id is not null
            and ((e.user_id is not null and s.hr_user_id = e.user_id)
              or (e.email  is not null and lower(s.hr_email) = lower(e.email)))
            -- a whole-org scope row overrides unit rows -> report whole-org
            and not exists (
              select 1 from hr_unit_scope s2
              where s2.org_id = e.org_id and s2.unit_id is null
                and ((e.user_id is not null and s2.hr_user_id = e.user_id)
                  or (e.email  is not null and lower(s2.hr_email) = lower(e.email))))
        ), '[]'::jsonb)
      ) order by o.name, lower(coalesce(e.email, au.email)))
      from employers e
      left join organizations o on o.id = e.org_id
      left join auth.users   au on au.id = e.user_id), '[]'::jsonb),

    'orgs', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name)
                       order by o.name)
      from organizations o), '[]'::jsonb),

    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ou.id, 'org_id', ou.org_id,
        'parent_unit_id', ou.parent_unit_id, 'name', ou.name)
        order by ou.sort_order, ou.name)
      from org_units ou where ou.is_active), '[]'::jsonb)
  );
end;
$$;


-- ── 2. Grant admin ───────────────────────────────────────────
create or replace function admin_role_grant_admin(p_email text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_email));
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'enter a valid email address';
  end if;

  if exists (select 1 from admins where lower(email) = v_email) then
    return jsonb_build_object('ok', true, 'msg', 'already an admin');
  end if;

  -- stored lowercase: index.html matches admins.email by exact string
  insert into admins (email) values (v_email);
  return jsonb_build_object('ok', true, 'msg', 'admin added');
end;
$$;


-- ── 3. Revoke admin ──────────────────────────────────────────
-- Two lockout guards: you cannot remove yourself, and you cannot
-- remove the last remaining admin.
create or replace function admin_role_revoke_admin(p_email text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_email));
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if v_email = lower(auth.jwt() ->> 'email') then
    raise exception 'you cannot remove your own admin access';
  end if;
  if not exists (select 1 from admins where lower(email) = v_email) then
    raise exception 'no admin with that email';
  end if;
  if (select count(*) from admins) <= 1 then
    raise exception 'cannot remove the last admin';
  end if;

  delete from admins where lower(email) = v_email;
  return jsonb_build_object('ok', true, 'msg', 'admin removed');
end;
$$;


-- ── 4. Grant HR (employers row + optional unit scope) ────────
-- One employers row per person (unique email), so granting to someone
-- who is already HR of another org MOVES them to the new org.
-- p_unit_id NULL = whole-org scope. The grant defines the scope:
-- existing hr_unit_scope rows for this person are replaced each time,
-- so re-granting is also how you change someone's scope.
create or replace function admin_role_grant_hr(
  p_email   text,
  p_org_id  uuid,
  p_unit_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_email));
  v_uid   uuid;
  v_emp   uuid;
  v_prev  uuid;
  v_msg   text := 'HR access granted';
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'enter a valid email address';
  end if;
  if not exists (select 1 from organizations where id = p_org_id) then
    raise exception 'organisation not found';
  end if;
  if p_unit_id is not null and not exists (
    select 1 from org_units where id = p_unit_id and org_id = p_org_id and is_active
  ) then
    raise exception 'that unit does not belong to the selected organisation';
  end if;

  -- Link the auth account now if it already exists (the signup-time
  -- backfill trigger never fires for accounts that already registered).
  select id into v_uid from auth.users where lower(email) = v_email limit 1;

  select id, org_id into v_emp, v_prev
  from employers
  where lower(email) = v_email
     or (v_uid is not null and user_id = v_uid)
  limit 1;

  if v_emp is null then
    insert into employers (email, org_id, user_id)
    values (v_email, p_org_id, v_uid)
    returning id into v_emp;
  else
    if v_prev is distinct from p_org_id then v_msg := 'HR access moved to the selected organisation'; end if;
    update employers
       set org_id  = p_org_id,
           email   = coalesce(email, v_email),
           user_id = coalesce(user_id, v_uid)
     where id = v_emp;
  end if;

  -- Replace any previous scope with the one just chosen.
  delete from hr_unit_scope
   where lower(hr_email) = v_email
      or (v_uid is not null and hr_user_id = v_uid);
  if p_unit_id is not null then
    insert into hr_unit_scope (hr_email, hr_user_id, org_id, unit_id)
    values (v_email, v_uid, p_org_id, p_unit_id);
  end if;

  return jsonb_build_object('ok', true, 'msg', v_msg, 'employer_id', v_emp);
end;
$$;


-- ── 5. Revoke HR ─────────────────────────────────────────────
create or replace function admin_role_revoke_hr(p_employer_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text;
  v_uid   uuid;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select lower(email), user_id into v_email, v_uid
  from employers where id = p_employer_id;
  if not found then raise exception 'HR manager not found'; end if;

  delete from hr_unit_scope
   where (v_email is not null and lower(hr_email) = v_email)
      or (v_uid   is not null and hr_user_id = v_uid);
  delete from employers where id = p_employer_id;

  return jsonb_build_object('ok', true, 'msg', 'HR access removed');
end;
$$;


-- ── 6. Grants ────────────────────────────────────────────────
revoke all on function admin_roles_overview()                 from public, anon;
revoke all on function admin_role_grant_admin(text)           from public, anon;
revoke all on function admin_role_revoke_admin(text)          from public, anon;
revoke all on function admin_role_grant_hr(text, uuid, uuid)  from public, anon;
revoke all on function admin_role_revoke_hr(uuid)             from public, anon;

grant execute on function admin_roles_overview()                to authenticated;
grant execute on function admin_role_grant_admin(text)          to authenticated;
grant execute on function admin_role_revoke_admin(text)         to authenticated;
grant execute on function admin_role_grant_hr(text, uuid, uuid) to authenticated;
grant execute on function admin_role_revoke_hr(uuid)            to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- SQL Editor (runs as postgres; is_admin() is false there, so the
-- functions should REFUSE — that refusal is itself the check):
--   select admin_roles_overview();          -- expect: not authorised
--
-- Browser console, logged in as an admin:
--   await sb.rpc('admin_roles_overview');   -- expect the full object
--
-- Browser console, logged in as a NON-admin member:
--   await sb.rpc('admin_roles_overview');   -- expect error 'not authorised'
-- ============================================================
