-- ============================================================
-- Key Wellness — member invites: add a group of people to an organisation
--
-- The database half of the "Add members" action in ops.html Support and the
-- send_invite action in the admin-support Edge Function.
-- Run in the Supabase SQL Editor. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-member-invites.sql
-- Tests:    tests/member-invites-tests.sql (local PostgreSQL; tests/run-member-invites.sh)
-- Verify:   tests/member-invites-verify-live.sql (read-only, this editor)
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────
--
-- Sept 2026: an MCM group filled in a paper attendance register and wanted
-- portal accounts. Until now a member had to create their own account and
-- type an invite code. Staff had no way to say "these people belong to this
-- site, send them a way in" — and the tempting shortcut (staff choose the
-- passwords and hand them out) is the one thing this migration is built to
-- make unnecessary. Nobody at Key Wellness ever sees a member's password:
-- the member receives Supabase's own invite mail and sets it themselves.
--
-- ── RULE 2, KEPT ────────────────────────────────────────────
--
-- admin-support's header says NOTHING ADDRESSABLE COMES FROM THE BODY. An
-- invite is the action most tempted to break that, because the person does
-- not exist yet. So the address does not go to the Edge Function at all:
--
--   1. ops.html calls invite_stage(rows) — this file, as the signed-in
--      admin. It validates every row, refuses addresses that already have
--      an account, and writes member_invites rows.
--   2. ops.html sends the function an INVITE ID. The function calls
--      invite_to_send(id) — again as the caller — and gets the address back
--      from the database. The body never carries one; the function still
--      refuses a body with "email" in it.
--   3. When the person accepts, handle_new_user() finds their invite row and
--      fills the profile: organisation, site, department, name. They skip
--      the invite-code step entirely and land attached to the right site.
--
-- ── THE NULL TRAP ───────────────────────────────────────────
-- Every gate reads `if not coalesce(is_admin(), false)`. See the header of
-- supabase_support_audit.sql for why the coalesce must stay.
--
-- Gate is is_admin(): that is what the live support_* functions use today
-- (the repo's is_ops_admin() was folded back into is_admin() before this
-- landed). When an ops/psychosocial split arrives, change the gate in one
-- place per function, as those files say.
-- ============================================================


-- ── 1. The invite ledger ────────────────────────────────────
-- One row per person invited. It is the record of "who did we send a way in
-- to, did it arrive, did they take it" — the question HR will ask a month
-- after a group session.

create table if not exists member_invites (
  id             uuid primary key default gen_random_uuid(),
  email          text not null,
  first_name     text,
  last_name      text,
  org_id         uuid not null references organizations(id),
  org_unit_id    uuid references org_units(id),
  department_id  uuid references unit_departments(id),
  status         text not null default 'staged',
  auth_user_id   uuid references auth.users(id) on delete set null,
  created_by     uuid not null references auth.users(id),
  created_at     timestamptz not null default now(),
  sent_at        timestamptz,
  sent_count     int not null default 0,
  accepted_at    timestamptz,
  last_error     text
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'member_invites_status_check') then
    alter table member_invites add constraint member_invites_status_check
      check (status in ('staged','sent','accepted','failed','cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'member_invites_email_lower_check') then
    alter table member_invites add constraint member_invites_email_lower_check
      check (email = lower(btrim(email)));
  end if;
end $$;

-- One live invite per address. Accepted/cancelled rows fall out of the index
-- so a person who leaves and comes back can be invited again.
create unique index if not exists member_invites_live_email_uidx
  on member_invites (email) where status in ('staged','sent','failed');
create index if not exists member_invites_org_idx     on member_invites (org_id, created_at desc);
create index if not exists member_invites_created_idx on member_invites (created_at desc);

alter table member_invites enable row level security;

-- Read for admins; no direct writes for anyone. Rows are written only by the
-- definer functions below, so every change carries the caller's identity.
drop policy if exists member_invites_admin_read on member_invites;
create policy member_invites_admin_read on member_invites
  for select using (coalesce(is_admin(), false));

revoke insert, update, delete on table member_invites from anon, authenticated;
grant select on table member_invites to authenticated;


-- ── 2. The audit trail learns a fourth action ───────────────
-- Invites are logged in support_actions like everything else on the Support
-- screen, so the left column shows them. target_user is null (there is no
-- user yet); detail carries the address.

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'support_actions_action_check') then
    alter table support_actions drop constraint support_actions_action_check;
  end if;
  alter table support_actions add constraint support_actions_action_check
    check (action in ('lookup','send_password_reset','resend_booking_confirmation',
                      'delete_user','send_invite'));
end $$;


-- ── 3. support_can() — invites get their own budget ─────────
-- Body identical to the live function except: invites are excluded from the
-- reset/resend counts (a 40-person group must not lock password resets for
-- the rest of the day), and get their own limits — 200 per admin per day,
-- 30 per minute, 3 sends per invite per day.

create or replace function support_can(p_action text, p_target_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_day_start timestamptz := (date_trunc('day', now() at time zone 'Africa/Gaborone'))
                             at time zone 'Africa/Gaborone';
  n_actor_day    int;
  n_actor_minute int;
  n_target_day   int;
  n_global_day   int;
begin
  if not coalesce(is_admin(), false) then
    return jsonb_build_object('allowed', false, 'reason', 'not authorised');
  end if;

  if p_action = 'send_invite' then
    select count(*) into n_actor_day
      from support_actions
     where actor = auth.uid() and action = 'send_invite'
       and outcome = 'ok' and created_at >= v_day_start;
    if n_actor_day >= 200 then
      return jsonb_build_object('allowed', false, 'reason', 'daily invite limit reached (200)');
    end if;

    select count(*) into n_actor_minute
      from support_actions
     where actor = auth.uid() and action = 'send_invite'
       and created_at >= now() - interval '1 minute';
    if n_actor_minute >= 30 then
      return jsonb_build_object('allowed', false, 'reason', 'too fast — wait a minute');
    end if;

    return jsonb_build_object('allowed', true, 'reason', null);
  end if;

  select count(*) into n_actor_day
    from support_actions
   where actor = auth.uid() and outcome = 'ok' and action <> 'send_invite'
     and created_at >= v_day_start;
  if n_actor_day >= 30 then
    return jsonb_build_object('allowed', false, 'reason', 'daily limit reached (30)');
  end if;

  select count(*) into n_actor_minute
    from support_actions
   where actor = auth.uid() and action <> 'send_invite'
     and created_at >= now() - interval '1 minute';
  if n_actor_minute >= 5 then
    return jsonb_build_object('allowed', false, 'reason', 'too fast — wait a minute');
  end if;

  if p_action = 'send_password_reset' and p_target_user is not null then
    select count(*) into n_target_day
      from support_actions
     where action = 'send_password_reset' and target_user = p_target_user
       and outcome = 'ok' and created_at >= v_day_start;
    if n_target_day >= 3 then
      return jsonb_build_object('allowed', false,
        'reason', 'this member has already had 3 reset links today');
    end if;
  end if;

  select count(*) into n_global_day
    from support_actions
   where outcome = 'ok' and action <> 'send_invite' and created_at >= v_day_start;
  if n_global_day >= 100 then
    return jsonb_build_object('allowed', false, 'reason', 'daily limit reached for the whole team');
  end if;

  return jsonb_build_object('allowed', true, 'reason', null);
end $$;

revoke execute on function support_can(text, uuid) from public, anon;
grant execute on function support_can(text, uuid) to authenticated;


-- ── 4. invite_stage() — validate a pasted list, write the rows ──
-- Input: a jsonb array of {first_name, last_name, email, department}
-- plus the organisation and (optional) site chosen on the screen.
-- Output: one result per input row, in order, each with a status:
--   staged            — row written, ready to send
--   exists            — this address already has an account; nothing written
--   already_invited   — a live invite for this address exists; nothing written
--   duplicate         — the address appears earlier in the same list
--   invalid_email     — not an address
-- and a `warning` when the department name did not match one of the site's
-- departments — the row is still staged, with department left blank, so a
-- misspelt department never blocks a person's account.
--
-- Nothing is sent here. Sending is a separate, per-person, audited step.

create or replace function invite_stage(p_org_id uuid, p_org_unit_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  r          jsonb;
  v_email    text;
  v_first    text;
  v_last     text;
  v_dept     text;
  v_dept_id  uuid;
  v_id       uuid;
  v_status   text;
  v_warning  text;
  v_seen     text[] := '{}';
  v_out      jsonb  := '[]'::jsonb;
  n_children int;
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;
  if auth.uid() is null then
    raise exception 'no caller identity';
  end if;

  if not exists (select 1 from organizations where id = p_org_id and is_active) then
    raise exception 'organisation not found or inactive';
  end if;

  -- The site must belong to the organisation and must be a leaf: a member
  -- attaches to a site, never to a company that has sites (the rule
  -- org_units already enforces for members).
  if p_org_unit_id is not null then
    if not exists (select 1 from org_units u
                    where u.id = p_org_unit_id and u.org_id = p_org_id and u.is_active) then
      raise exception 'site does not belong to that organisation';
    end if;
    select count(*) into n_children from org_units where parent_unit_id = p_org_unit_id and is_active;
    if n_children > 0 then
      raise exception 'choose a site, not a company that has sites';
    end if;
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'no rows';
  end if;
  if jsonb_array_length(p_rows) > 200 then
    raise exception 'at most 200 people per list';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_email   := lower(btrim(coalesce(r ->> 'email', '')));
    v_first   := nullif(btrim(coalesce(r ->> 'first_name', '')), '');
    v_last    := nullif(btrim(coalesce(r ->> 'last_name', '')), '');
    v_dept    := nullif(btrim(coalesce(r ->> 'department', '')), '');
    v_dept_id := null;
    v_id      := null;
    v_warning := null;

    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_status := 'invalid_email';
    elsif v_email = any (v_seen) then
      v_status := 'duplicate';
    elsif exists (select 1 from auth.users u where lower(u.email) = v_email) then
      v_status := 'exists';
    elsif exists (select 1 from member_invites m
                   where m.email = v_email and m.status in ('staged','sent','failed')) then
      v_status := 'already_invited';
      select id into v_id from member_invites
       where email = v_email and status in ('staged','sent','failed') limit 1;
    else
      if v_dept is not null and p_org_unit_id is not null then
        select d.id into v_dept_id
          from unit_departments d
         where d.unit_id = p_org_unit_id and d.is_active
           and lower(d.name) = lower(v_dept)
         limit 1;
        if v_dept_id is null then
          v_warning := 'department "' || v_dept || '" is not one of this site''s departments — left blank';
        end if;
      elsif v_dept is not null then
        v_warning := 'no site chosen, so the department was left blank';
      end if;

      insert into member_invites (email, first_name, last_name, org_id, org_unit_id, department_id, created_by)
      values (v_email, v_first, v_last, p_org_id, p_org_unit_id, v_dept_id, auth.uid())
      returning id into v_id;
      v_status := 'staged';
    end if;

    v_seen := v_seen || v_email;
    v_out  := v_out || jsonb_build_object(
      'email', v_email, 'first_name', v_first, 'last_name', v_last,
      'department', v_dept, 'department_id', v_dept_id,
      'invite_id', v_id, 'status', v_status, 'warning', v_warning);
  end loop;

  return v_out;
end $$;

revoke execute on function invite_stage(uuid, uuid, jsonb) from public, anon;
grant execute on function invite_stage(uuid, uuid, jsonb) to authenticated;


-- ── 5. invite_to_send() — the Edge Function's only way to an address ──
-- Called as the signed-in admin with an invite id. Returns what the Auth
-- admin API needs and nothing more. Refuses accepted/cancelled invites.

create or replace function invite_to_send(p_invite_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v jsonb;
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;

  select jsonb_build_object(
           'invite_id',     m.id,
           'email',         m.email,
           'first_name',    m.first_name,
           'last_name',     m.last_name,
           'org_id',        m.org_id,
           'org_unit_id',   m.org_unit_id,
           'department_id', m.department_id,
           'org_name',      o.name,
           'unit_name',     u.name,
           'status',        m.status,
           'sent_count',    m.sent_count)
    into v
    from member_invites m
    join organizations o on o.id = m.org_id
    left join org_units u on u.id = m.org_unit_id
   where m.id = p_invite_id;

  if v is null then
    raise exception 'invite not found';
  end if;
  if (v ->> 'status') not in ('staged','sent','failed') then
    raise exception 'this invite is %', (v ->> 'status');
  end if;
  if (v ->> 'sent_count')::int >= 3 then
    raise exception 'this invite has already been sent 3 times';
  end if;
  return v;
end $$;

revoke execute on function invite_to_send(uuid) from public, anon;
grant execute on function invite_to_send(uuid) to authenticated;


-- ── 6. invite_mark() — record the outcome of a send ─────────

create or replace function invite_mark(p_invite_id uuid, p_outcome text, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;
  if p_outcome not in ('sent','failed','cancelled') then
    raise exception 'bad outcome';
  end if;

  update member_invites
     set status     = case when status = 'accepted' then status else p_outcome end,
         sent_at    = case when p_outcome = 'sent' then now() else sent_at end,
         sent_count = case when p_outcome = 'sent' then sent_count + 1 else sent_count end,
         last_error = case when p_outcome = 'failed' then left(coalesce(p_error,''), 300)
                           when p_outcome = 'sent'   then null
                           else last_error end
   where id = p_invite_id;

  if not found then
    raise exception 'invite not found';
  end if;
end $$;

revoke execute on function invite_mark(uuid, text, text) from public, anon;
grant execute on function invite_mark(uuid, text, text) to authenticated;


-- ── 7. invite_list() — the Support screen's right column ────

create or replace function invite_list(p_org_id uuid default null, p_limit int default 100)
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
             'invite_id',   m.id,
             'email',       m.email,
             'name',        btrim(coalesce(m.first_name,'') || ' ' || coalesce(m.last_name,'')),
             'org_name',    o.name,
             'unit_name',   u.name,
             'department',  d.name,
             'status',      m.status,
             'sent_at',     m.sent_at,
             'sent_count',  m.sent_count,
             'accepted_at', m.accepted_at,
             'last_error',  m.last_error,
             'created_at',  m.created_at,
             'created_by',  au.email
           ) order by m.created_at desc)
      from (select * from member_invites
             where p_org_id is null or org_id = p_org_id
             order by created_at desc
             limit greatest(1, least(coalesce(p_limit, 100), 500))) m
      join organizations o on o.id = m.org_id
      left join org_units u on u.id = m.org_unit_id
      left join unit_departments d on d.id = m.department_id
      left join auth.users au on au.id = m.created_by
  ), '[]'::jsonb);
end $$;

revoke execute on function invite_list(uuid, int) from public, anon;
grant execute on function invite_list(uuid, int) to authenticated;


-- ── 8. handle_new_user() — the invite is honoured at signup ─
-- Live body kept intact (invite_code from metadata → org_id). Added: find
-- the person's invite row — by the invite_id the Auth admin API stamped into
-- their metadata, else by address — and fill organisation, site, department
-- and name from it. The invite becomes 'accepted'.
--
-- coalesce-on-conflict is kept: a profile that already exists never has a
-- filled value overwritten by this trigger.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  code        text;
  resolved    uuid;
  v_invite_id uuid;
  inv         member_invites%rowtype;
begin
  code := upper(coalesce(new.raw_user_meta_data ->> 'invite_code', ''));

  if code <> '' then
    select id into resolved
      from organizations
     where upper(invite_code) = code
       and is_active = true;
    -- If code is unknown or inactive, resolved stays null → public member
  end if;

  begin
    v_invite_id := nullif(new.raw_user_meta_data ->> 'invite_id', '')::uuid;
  exception when others then
    v_invite_id := null;
  end;

  select * into inv
    from member_invites m
   where m.status in ('staged','sent','failed')
     and (m.id = v_invite_id
          or (new.email is not null and m.email = lower(new.email)))
   order by (m.id = v_invite_id) desc, m.created_at desc
   limit 1;

  if inv.id is not null then
    resolved := coalesce(inv.org_id, resolved);
  end if;

  insert into profiles (id, org_id, org_unit_id, department_id, first_name, last_name)
  values (new.id, resolved, inv.org_unit_id, inv.department_id, inv.first_name, inv.last_name)
  on conflict (id) do update
    set org_id        = coalesce(profiles.org_id,        excluded.org_id),
        org_unit_id   = coalesce(profiles.org_unit_id,   excluded.org_unit_id),
        department_id = coalesce(profiles.department_id, excluded.department_id),
        first_name    = coalesce(profiles.first_name,    excluded.first_name),
        last_name     = coalesce(profiles.last_name,     excluded.last_name);

  if inv.id is not null then
    update member_invites
       set status = 'accepted', accepted_at = now(), auth_user_id = new.id
     where id = inv.id;
  end if;

  return new;
end $$;


-- ── 9. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'member_invites';
  if n <> 1 then
    raise exception 'member_invites: expected exactly 1 policy (read), found %', n;
  end if;
  if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                  where ns.nspname='public' and c.relname='member_invites' and c.relrowsecurity) then
    raise exception 'member_invites: RLS is not enabled';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'support_actions_action_check'
                   and pg_get_constraintdef(oid) like '%send_invite%') then
    raise exception 'support_actions: send_invite not in the action check';
  end if;
  raise notice 'member invites applied. Deploy admin-support (send_invite action) next.';
end $$;
