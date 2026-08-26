-- ============================================================
-- Key Wellness — M5 fixture (local PostgreSQL 17 only)
--
-- Companion to tests/run-m5.sh and tests/m5-tests.sql. NOT a migration.
-- Never run this against Supabase.
--
-- A reconstruction, not a copy — see docs/build/m5-meetings-actions.md.
-- Tables and constraints are transcribed from
-- docs/build/00-live-schema-snapshot.md as read on 25 Aug 2026.
--
-- ── THIS SUITE ACTUALLY ENFORCES RLS ────────────────────────
-- tests/phase0-tests.sql runs everything as `postgres`, which is a superuser
-- and therefore BYPASSES row-level security. It drives `test.email` to steer
-- is_admin() and current_advisor_id(), so it tests the SECURITY DEFINER
-- functions' internal gates — but every policy assertion it appears to make
-- is vacuous.
--
-- M5 is mostly policies: "a member reads neither", "a third staff member
-- cannot update". Those are worth nothing unless RLS is on for the caller.
-- So this fixture grants the `authenticated` role real table privileges, and
-- m5-tests.sql does `set role authenticated` before every access assertion.
-- authenticated is not the table owner, so PostgreSQL enforces the policies.
-- ============================================================

create schema if not exists auth;

create table auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text,
  created_at timestamptz not null default now()
);

create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb
language sql stable as $$ select jsonb_build_object('email', coalesce(current_setting('test.email', true),'')) $$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon;          end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role;  end if;
end $$;


-- ── Tables ──────────────────────────────────────────────────

create table organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  invite_code text not null unique,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table admins (email text primary key);

create table advisors (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid,
  email        text not null,
  full_name    text not null,
  is_active    boolean not null default true,
  is_team_lead boolean not null default false,
  created_at   timestamptz not null default now()
);

create table employers (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid,
  org_id     uuid not null references organizations(id),
  email      text,
  created_at timestamptz not null default now()
);

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  org_id     uuid references organizations(id),
  first_name text,
  last_name  text,
  joined_at  timestamptz default now()
);

-- The live notifications table, with its RLS and its update guard, so the
-- reminder assertions run against the real delivery path.
create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  type       text not null,
  title      text not null,
  body       text,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);

alter table notifications enable row level security;

create policy notifications_own_read on notifications
  for select to authenticated using (user_id = auth.uid());
create policy notifications_own_update on notifications
  for update to authenticated using (user_id = auth.uid())
  with check (user_id = auth.uid());
-- NOTE: no INSERT policy, exactly as live. Only a SECURITY DEFINER function
-- running as the owner can write a notification.

create or replace function guard_notification_update() returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and not is_admin() then
    if NEW.user_id    is distinct from OLD.user_id
    or NEW.type       is distinct from OLD.type
    or NEW.title      is distinct from OLD.title
    or NEW.body       is distinct from OLD.body
    or NEW.created_at is distinct from OLD.created_at then
      raise exception 'notifications: members may only update read_at'
        using errcode = 'check_violation';
    end if;
  end if;
  return NEW;
end $$;

create trigger trg_guard_notification_update
  before update on notifications
  for each row execute function guard_notification_update();


-- ── Role helpers, matching the live definitions ─────────────

create or replace function is_admin() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

create or replace function is_advisor() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors a
                  where a.is_active
                    and (a.user_id = auth.uid()
                      or lower(a.email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function current_advisor_id() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select id from advisors a
   where a.is_active
     and (a.user_id = auth.uid() or lower(a.email) = lower(auth.jwt() ->> 'email'))
   limit 1;
$$;

create or replace function is_team_lead() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors a
                  where a.is_active and a.is_team_lead
                    and (a.user_id = auth.uid()
                      or lower(a.email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function employer_org() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select org_id from employers
   where user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email')
   limit 1;
$$;


-- ── Seed ────────────────────────────────────────────────────
-- Fixed uuids so the assertions can name people without lookups.
--   L  Lone      admin              (staff)
--   M  Michelle  admin              (staff)
--   K  Kefilwe   advisor            (staff)
--   T  Katlo     advisor            (staff, the uninvolved third party)
--   A  Laone     accountant         (NOT staff — owns actions, M4's invoices)
--   P  a member                     (no access at all)
--   H  an HR user                   (no access at all)

insert into organizations (id, name, invite_code, is_active) values
  ('0a000000-0000-0000-0000-0000000000b0', 'BOPEU',    'BOPEU-T',  true),
  ('0a000000-0000-0000-0000-0000000000d0', 'Sedimosa', 'SED-T',    true),
  ('0a000000-0000-0000-0000-0000000000c0', 'Test Co',  'TESTCO-T', true),
  ('0a000000-0000-0000-0000-0000000000e0', 'Closed Co','CLOSED-T', false);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000009', 'lone@keywellness.co.bw'),
  ('00000000-0000-0000-0000-00000000000a', 'michelle@keywellness.co.bw'),
  ('00000000-0000-0000-0000-00000000000b', 'kefilwe@keywealth.co.bw'),
  ('00000000-0000-0000-0000-00000000000c', 'katlo@keywealth.co.bw'),
  ('00000000-0000-0000-0000-00000000000d', 'laone@keywellness.co.bw'),
  ('00000000-0000-0000-0000-00000000000e', 'member@example.test'),
  ('00000000-0000-0000-0000-00000000000f', 'hr@bopeu.test');

insert into admins (email) values
  ('lone@keywellness.co.bw'), ('michelle@keywellness.co.bw');

insert into advisors (user_id, email, full_name, is_active, is_team_lead) values
  ('00000000-0000-0000-0000-00000000000b', 'kefilwe@keywealth.co.bw', 'Kefilwe', true, false),
  ('00000000-0000-0000-0000-00000000000c', 'katlo@keywealth.co.bw',   'Katlo',   true, false);

insert into employers (user_id, org_id, email) values
  ('00000000-0000-0000-0000-00000000000f', '0a000000-0000-0000-0000-0000000000b0', 'hr@bopeu.test');

insert into profiles (id, org_id, first_name, last_name) values
  ('00000000-0000-0000-0000-00000000000e', '0a000000-0000-0000-0000-0000000000b0',
   'Boitumelo', 'Member'),
  -- staff carry profiles too; support_lookup finds people by name as well as
  -- address, so the fixture needs names to search for
  ('00000000-0000-0000-0000-000000000009', null, 'Lone',    'Coordinator'),
  ('00000000-0000-0000-0000-00000000000b', null, 'Kefilwe', 'Advisor');


-- ── Privileges for the `authenticated` role ─────────────────
-- Without these, `set role authenticated` fails with "permission denied for
-- table" and every RLS assertion would be testing the grant, not the policy.
-- Supabase grants these by default; the fixture has to do it explicitly.

grant usage on schema public to authenticated, anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage, select on all sequences in schema public to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
