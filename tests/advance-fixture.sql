-- ============================================================
-- Key Wellness — Advance Recommendation fixture (local PostgreSQL only)
--
-- Companion to tests/run-advance-db.sh and tests/advance-db-tests.sql.
-- NOT a migration. Never run this against Supabase.
--
-- A reconstruction of the pieces supabase_advance_recommendation.sql
-- depends on: auth stubs, advisors, advisor_clients, advisor_notes, and the
-- four gate functions (is_admin, is_team_lead, current_advisor_id,
-- can_manage_advisor), transcribed from supabase_advisor_portal.sql,
-- supabase_advisor_team_lead.sql and supabase_advisor_ux.sql.
--
-- Access assertions run under `set role authenticated` so RLS is enforced,
-- following the tests/m5-fixture.sql pattern.
-- ============================================================
create schema if not exists auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz not null default now());
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', coalesce(current_setting('test.email', true),'')) $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon;          end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;

create table admins (email text primary key);
create table advisors (
  id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id), email text not null,
  full_name text not null, is_active boolean not null default true, is_team_lead boolean not null default false
);
-- Organisations, because the advance gate reads offers_advances. Only the
-- columns the gate touches; the real table is much wider.
create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  is_active boolean not null default true,
  offers_advances boolean not null default false
);
create table advisor_clients (
  id uuid primary key default gen_random_uuid(),
  advisor_id uuid not null references advisors(id) on delete cascade,
  member_user_id uuid null references auth.users(id),
  org_id uuid null references organizations(id),
  no_org boolean not null default false,
  first_name text not null, last_name text, assessment jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table advisor_notes (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references advisor_clients(id) on delete cascade,
  advisor_id uuid not null references advisors(id) on delete cascade,
  booking_id uuid null, body text not null,
  origin text not null default 'advisor' check (origin in ('advisor','session','migrated','system')),
  created_at timestamptz not null default now(), updated_at timestamptz null
);

create or replace function is_admin() returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email')) $$;
create or replace function current_advisor_id() returns uuid language sql security definer stable set search_path = public as $$
  select id from advisors where is_active and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email'))
  order by (user_id = auth.uid()) desc limit 1 $$;
create or replace function is_team_lead() returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from advisors where id = current_advisor_id() and is_team_lead) $$;
create or replace function can_manage_advisor(p_advisor_id uuid) returns boolean language sql security definer stable set search_path = public as $$
  select p_advisor_id is not null and (p_advisor_id = current_advisor_id() or is_team_lead() or is_admin()) $$;

alter table advisor_clients enable row level security;
create policy advisor_clients_own on advisor_clients for select using (advisor_id = current_advisor_id());
create policy advisor_clients_lead_all on advisor_clients for all using (is_team_lead()) with check (is_team_lead());
create policy advisor_clients_admin_all on advisor_clients for all using (is_admin()) with check (is_admin());
create policy advisor_clients_member_read on advisor_clients for select using (member_user_id = auth.uid());
alter table advisor_notes enable row level security;
create policy advisor_notes_own on advisor_notes for all using (advisor_id = current_advisor_id()) with check (advisor_id = current_advisor_id());

grant usage on schema public to authenticated, anon;
grant select on all tables in schema public to authenticated;
alter default privileges in schema public grant select on tables to authenticated;

-- People
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000001', 'france@example.test'),
  ('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test'),
  ('a0000000-0000-4000-8000-000000000003', 'lead@example.test'),
  ('a0000000-0000-4000-8000-000000000004', 'member@example.test');
insert into advisors (id, user_id, email, full_name, is_team_lead) values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'france@example.test', 'France Mogomotsi', false),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test', 'Kealeboga Gaseitsiwe', false),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003', 'lead@example.test', 'Team Lead', true);
insert into organizations (id, name, offers_advances) values
  ('d0000000-0000-4000-8000-000000000001', 'Hollard', true),      -- runs an advance programme
  ('d0000000-0000-4000-8000-000000000002', 'Debswana', false);    -- does not
insert into advisor_clients (id, advisor_id, member_user_id, org_id, no_org, first_name, last_name, assessment) values
  ('c0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000004', 'd0000000-0000-4000-8000-000000000001', false, 'Tumelo', 'Kgamayane', '{}'::jsonb),
  -- Same advisor, an organisation with no advance programme.
  ('c0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001', null, 'd0000000-0000-4000-8000-000000000002', false, 'Neo', 'Motlhabane', '{}'::jsonb),
  -- Same advisor, a private client on no company programme at all.
  ('c0000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000001', null, null, true, 'Boitumelo', 'Sekgoma', '{}'::jsonb);
