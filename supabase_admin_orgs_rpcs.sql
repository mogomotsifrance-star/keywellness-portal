-- ============================================================
-- Key Wellness — Organisations RPCs for the admin dashboard
--
-- Backs the new "Organisations" tab in admin.html, so onboarding a
-- client company no longer needs SQL in the Supabase editor. Creating
-- the organisation row is the FIRST step of onboarding — the invite
-- code it mints is what members type at signup (handle_new_user()
-- resolves it), and every later step (HR grant on Roles & Access,
-- webinar audience, org report) picks the organisation from a list.
--
-- Why RPCs and not RLS: `organizations` has SELECT-only policies
-- (orgs_admin_all / orgs_own from supabase_multitenancy.sql) — there
-- is no INSERT/UPDATE/DELETE path for anyone. Rather than open the
-- table up, every write goes through a SECURITY DEFINER function
-- guarded by is_admin(), matching supabase_admin_roles_rpcs.sql.
--
-- Invite codes are stored UPPERCASE and compared case-insensitively,
-- because both readers — handle_new_user() and verify_invite_code() —
-- match on upper(invite_code). Uniqueness is therefore enforced here
-- on upper(invite_code), which is stricter than the table's own
-- unique constraint on the raw text.
--
-- Run in the Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- PRODUCTION-LIVE on apply — but inert until admin.html ships, and
-- every function is admin-gated, so applying early is safe.
-- ROLLBACK: migrations/rollback-admin-orgs-rpcs.sql
-- ============================================================


-- ── 0. Dependency probe ──────────────────────────────────────
-- True when anything at all still points at this organisation.
-- Used to decide whether the row can be deleted outright (a typo
-- caught minutes later) or must be deactivated instead. Covers every
-- table with an FK to organizations as at this migration.
-- Internal helper: SECURITY DEFINER, callable only by the owner and
-- by the admin-gated functions below.
create or replace function admin_org_has_dependents(p_org_id uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles               where org_id = p_org_id)
      or exists (select 1 from employers              where org_id = p_org_id)
      or exists (select 1 from org_units              where org_id = p_org_id)
      or exists (select 1 from hr_unit_scope          where org_id = p_org_id)
      or exists (select 1 from org_reports            where org_id = p_org_id)
      or exists (select 1 from org_headcount_reports  where org_id = p_org_id)
      or exists (select 1 from program_activities     where org_id = p_org_id)
      or exists (select 1 from content_items          where org_id = p_org_id)
      or exists (select 1 from advisor_clients        where org_id = p_org_id)
      or exists (select 1 from reward_fulfilments     where org_id = p_org_id);
$$;


-- ── 1. Overview — everything the Organisations tab needs ─────
-- [{id,name,invite_code,is_active,program_name,program_logo_path,
--   created_at,member_count,hr_count,unit_count,deletable}]
create or replace function admin_orgs_overview()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',                o.id,
      'name',              o.name,
      'invite_code',       o.invite_code,
      'is_active',         o.is_active,
      'program_name',      o.program_name,
      'program_logo_path', o.program_logo_path,
      'created_at',        o.created_at,
      'member_count', (select count(*) from profiles  p where p.org_id = o.id),
      'hr_count',     (select count(*) from employers e where e.org_id = o.id),
      'unit_count',   (select count(*) from org_units u where u.org_id = o.id and u.is_active),
      'deletable',    not admin_org_has_dependents(o.id)
    ) order by o.name)
    from organizations o), '[]'::jsonb);
end;
$$;


-- ── 2. Suggest a free invite code ────────────────────────────
-- <first 4 alphanumerics of the name, padded>-<4 digits>, e.g.
-- 'Sedimosa' -> 'SEDI-4821'. Retries until the code is unused, so the
-- admin never has to think one up or check it by hand.
create or replace function admin_org_suggest_code(p_name text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_stem text;
  v_code text;
  i      int := 0;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  v_stem := upper(regexp_replace(coalesce(p_name, ''), '[^a-zA-Z0-9]', '', 'g'));
  if length(v_stem) < 4 then v_stem := rpad(nullif(v_stem, ''), 4, 'X'); end if;
  if v_stem is null then v_stem := 'ORGX'; end if;
  v_stem := substr(v_stem, 1, 4);

  loop
    i := i + 1;
    v_code := v_stem || '-' || lpad(floor(random() * 10000)::int::text, 4, '0');
    exit when not exists (select 1 from organizations where upper(invite_code) = v_code);
    if i > 50 then
      raise exception 'could not find a free invite code for that name — enter one by hand';
    end if;
  end loop;

  return v_code;
end;
$$;


-- ── 3. Create an organisation ────────────────────────────────
-- Blank invite code = generate one. New organisations start active,
-- so members can join with the code straight away.
create or replace function admin_org_create(
  p_name              text,
  p_invite_code       text default null,
  p_program_name      text default null,
  p_program_logo_path text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_code text := upper(btrim(coalesce(p_invite_code, '')));
  v_prog text := nullif(btrim(coalesce(p_program_name, '')), '');
  v_logo text := nullif(btrim(coalesce(p_program_logo_path, '')), '');
  v_id   uuid;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  if length(v_name) < 2 then
    raise exception 'enter the organisation name';
  end if;
  if exists (select 1 from organizations where lower(name) = lower(v_name)) then
    raise exception 'an organisation called "%" already exists', v_name;
  end if;

  if v_code = '' then
    v_code := admin_org_suggest_code(v_name);
  else
    if v_code !~ '^[A-Z0-9][A-Z0-9-]{2,23}$' then
      raise exception 'invite code must be 3-24 characters: letters, numbers and hyphens only';
    end if;
    if exists (select 1 from organizations where upper(invite_code) = v_code) then
      raise exception 'that invite code is already in use';
    end if;
  end if;

  if v_logo is not null and v_logo !~* '^(https://|/|assets/)' then
    raise exception 'programme logo must be an https:// URL or a path inside the portal';
  end if;

  insert into organizations (name, invite_code, is_active, program_name, program_logo_path)
  values (v_name, v_code, true, v_prog, v_logo)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'invite_code', v_code,
    'msg', format('%s created. Invite code: %s', v_name, v_code));
end;
$$;


-- ── 4. Update an organisation ────────────────────────────────
-- The edit form sends every field, so this is a full replace of the
-- editable columns. Changing the invite code only affects FUTURE
-- signups: existing members are linked by org_id, never by code.
create or replace function admin_org_update(
  p_org_id            uuid,
  p_name              text,
  p_invite_code       text,
  p_program_name      text    default null,
  p_program_logo_path text    default null,
  p_is_active         boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_code text := upper(btrim(coalesce(p_invite_code, '')));
  v_prog text := nullif(btrim(coalesce(p_program_name, '')), '');
  v_logo text := nullif(btrim(coalesce(p_program_logo_path, '')), '');
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if not exists (select 1 from organizations where id = p_org_id) then
    raise exception 'organisation not found';
  end if;

  if length(v_name) < 2 then
    raise exception 'enter the organisation name';
  end if;
  if exists (select 1 from organizations
             where lower(name) = lower(v_name) and id <> p_org_id) then
    raise exception 'an organisation called "%" already exists', v_name;
  end if;

  if v_code = '' then
    raise exception 'an organisation must keep an invite code';
  end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9-]{2,23}$' then
    raise exception 'invite code must be 3-24 characters: letters, numbers and hyphens only';
  end if;
  if exists (select 1 from organizations
             where upper(invite_code) = v_code and id <> p_org_id) then
    raise exception 'that invite code is already in use';
  end if;

  if v_logo is not null and v_logo !~* '^(https://|/|assets/)' then
    raise exception 'programme logo must be an https:// URL or a path inside the portal';
  end if;

  update organizations
     set name              = v_name,
         invite_code       = v_code,
         program_name      = v_prog,
         program_logo_path = v_logo,
         is_active         = coalesce(p_is_active, true)
   where id = p_org_id;

  return jsonb_build_object('ok', true, 'msg', 'Organisation updated');
end;
$$;


-- ── 5. Activate / deactivate ─────────────────────────────────
-- Deactivating closes the door on NEW signups with that invite code
-- (handle_new_user() only resolves active organisations). Members who
-- already joined keep their org_id, their data and their reporting.
create or replace function admin_org_set_active(p_org_id uuid, p_is_active boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select name into v_name from organizations where id = p_org_id;
  if not found then raise exception 'organisation not found'; end if;

  update organizations set is_active = coalesce(p_is_active, true) where id = p_org_id;

  return jsonb_build_object('ok', true,
    'msg', v_name || (case when p_is_active then ' reactivated' else ' deactivated' end));
end;
$$;


-- ── 6. Delete an empty organisation ──────────────────────────
-- Only for an organisation nothing points at yet — the "created it
-- with a typo" case. Anything with members, HR, companies, reports,
-- activities, webinars, advisor caseloads or reward fulfilments must
-- be deactivated instead, so no history is ever silently destroyed.
create or replace function admin_org_delete(p_org_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select name into v_name from organizations where id = p_org_id;
  if not found then raise exception 'organisation not found'; end if;

  if admin_org_has_dependents(p_org_id) then
    raise exception 'cannot delete "%" — members, HR managers, companies or reports are attached to it. Deactivate it instead.', v_name;
  end if;

  delete from organizations where id = p_org_id;

  return jsonb_build_object('ok', true, 'msg', v_name || ' deleted');
end;
$$;


-- ── 7. Grants ────────────────────────────────────────────────
-- admin_org_has_dependents stays owner-only: it is called from inside
-- the SECURITY DEFINER functions above, which run as the owner.
revoke all on function admin_org_has_dependents(uuid)                          from public, anon, authenticated;
revoke all on function admin_orgs_overview()                                   from public, anon;
revoke all on function admin_org_suggest_code(text)                            from public, anon;
revoke all on function admin_org_create(text, text, text, text)                from public, anon;
revoke all on function admin_org_update(uuid, text, text, text, text, boolean) from public, anon;
revoke all on function admin_org_set_active(uuid, boolean)                     from public, anon;
revoke all on function admin_org_delete(uuid)                                  from public, anon;

grant execute on function admin_orgs_overview()                                   to authenticated;
grant execute on function admin_org_suggest_code(text)                            to authenticated;
grant execute on function admin_org_create(text, text, text, text)                to authenticated;
grant execute on function admin_org_update(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function admin_org_set_active(uuid, boolean)                     to authenticated;
grant execute on function admin_org_delete(uuid)                                  to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- SQL Editor (runs as postgres; is_admin() is false there, so the
-- functions should REFUSE — that refusal is itself the check):
--   select admin_orgs_overview();        -- expect: not authorised
--
-- Browser console, logged in as an admin:
--   await sb.rpc('admin_orgs_overview');                        -- full list
--   await sb.rpc('admin_org_suggest_code', {p_name:'Acme Ltd'}); -- 'ACME-####'
--   await sb.rpc('admin_org_create', {p_name:'Acme Ltd'});       -- creates it
--   await sb.rpc('admin_org_delete', {p_org_id:'<the id>'});     -- removes it again
--
-- Browser console, logged in as a NON-admin member:
--   await sb.rpc('admin_orgs_overview');  -- expect error 'not authorised'
-- ============================================================
