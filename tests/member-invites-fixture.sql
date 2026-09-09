-- ============================================================
-- Key Wellness — member-invites fixture (local PostgreSQL only)
-- Companion to tests/run-member-invites.sh. NOT a migration. Never run on
-- Supabase. A reconstruction of the tables the migration touches, from the
-- live schema as read on 3 Sep 2026.
-- ============================================================
create extension if not exists pgcrypto;
create schema if not exists auth;

create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb
language sql stable as $$ select jsonb_build_object('email', coalesce(current_setting('test.email', true),'')) $$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon;          end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;

create table organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  invite_code text not null unique,
  is_active   boolean not null default true
);
create table org_units (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations(id),
  parent_unit_id uuid references org_units(id),
  name           text not null,
  is_active      boolean not null default true
);
create table unit_departments (
  id        uuid primary key default gen_random_uuid(),
  unit_id   uuid not null references org_units(id),
  name      text not null,
  is_active boolean not null default true,
  unique (unit_id, name)
);
create table admins (email text primary key);
create table bookings (id uuid primary key default gen_random_uuid());

create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  org_id        uuid references organizations(id),
  org_unit_id   uuid references org_units(id),
  department_id uuid references unit_departments(id),
  first_name    text,
  last_name     text,
  joined_at     timestamptz default now()
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

-- live handle_new_user() body, pre-invite, with its trigger
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare code text; resolved uuid;
begin
  code := upper(coalesce(new.raw_user_meta_data ->> 'invite_code', ''));
  if code <> '' then
    select id into resolved from organizations where upper(invite_code) = code and is_active = true;
  end if;
  insert into profiles (id, org_id) values (new.id, resolved)
  on conflict (id) do update set org_id = coalesce(profiles.org_id, excluded.org_id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- live support_actions, as of supabase_admin_delete_user.sql
create table support_actions (
  id             uuid primary key default gen_random_uuid(),
  actor          uuid not null references auth.users(id),
  actor_email    text,
  action         text not null,
  target_user    uuid references auth.users(id),
  target_email   text,
  target_booking uuid references bookings(id) on delete set null,
  outcome        text not null,
  detail         text,
  created_at     timestamptz not null default now(),
  constraint support_actions_action_check check (action in ('lookup','send_password_reset','resend_booking_confirmation','delete_user')),
  constraint support_actions_outcome_check check (outcome in ('ok','denied','error'))
);
alter table support_actions enable row level security;
create policy support_actions_admin_read on support_actions for select using (is_admin());

create or replace function support_log(p_action text, p_outcome text, p_target_user uuid default null,
                                       p_target_booking uuid default null, p_detail text default null)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if not coalesce(is_admin(), false) then raise exception 'not authorised'; end if;
  if auth.uid() is null then raise exception 'no caller identity'; end if;
  insert into support_actions (actor, actor_email, action, target_user, target_email, target_booking, outcome, detail)
  values (auth.uid(), lower(auth.jwt() ->> 'email'), p_action, p_target_user,
          (select lower(email) from auth.users where id = p_target_user),
          p_target_booking, p_outcome, left(coalesce(p_detail, ''), 500))
  returning id into v_id;
  return v_id;
end $$;

-- live support_can, pre-invite (so the test can prove the change)
create or replace function support_can(p_action text, p_target_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare v_day_start timestamptz := (date_trunc('day', now() at time zone 'Africa/Gaborone')) at time zone 'Africa/Gaborone';
        n_actor_day int; n_actor_minute int; n_target_day int; n_global_day int;
begin
  if not coalesce(is_admin(), false) then return jsonb_build_object('allowed', false, 'reason', 'not authorised'); end if;
  select count(*) into n_actor_day from support_actions where actor = auth.uid() and outcome = 'ok' and created_at >= v_day_start;
  if n_actor_day >= 30 then return jsonb_build_object('allowed', false, 'reason', 'daily limit reached (30)'); end if;
  select count(*) into n_actor_minute from support_actions where actor = auth.uid() and created_at >= now() - interval '1 minute';
  if n_actor_minute >= 5 then return jsonb_build_object('allowed', false, 'reason', 'too fast — wait a minute'); end if;
  select count(*) into n_global_day from support_actions where outcome = 'ok' and created_at >= v_day_start;
  if n_global_day >= 100 then return jsonb_build_object('allowed', false, 'reason', 'daily limit reached for the whole team'); end if;
  return jsonb_build_object('allowed', true, 'reason', null);
end $$;

grant usage on schema public, auth to authenticated, anon;
grant select on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated, anon;

-- ── Seed ────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'lone@keywellness.test'),
  ('00000000-0000-0000-0000-00000000b001', 'existing@mcm.test');
insert into admins values ('lone@keywellness.test');

insert into organizations (id, name, invite_code) values
  ('00000000-0000-0000-0000-0000000000f1', 'Sedimosa', 'S3DI-TEST'),
  ('00000000-0000-0000-0000-0000000000f2', 'BOPEU',    'BOPE-TEST');
insert into org_units (id, org_id, parent_unit_id, name) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000f1', null, 'Debswana'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', 'Jwaneng'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000f1', null, 'Morupule Coal Mine (MCM)');
insert into unit_departments (id, unit_id, name) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000e3', 'Mining'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000e3', 'Engineering');
