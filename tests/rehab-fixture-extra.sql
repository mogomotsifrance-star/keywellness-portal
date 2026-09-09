-- ============================================================
-- Key Wellness — Debt Rehab Plan fixture extra (local PostgreSQL only)
--
-- Runs AFTER tests/advance-fixture.sql. NOT a migration. Never run this
-- against Supabase.
--
-- Adds the two roles the rehab suite must prove are denied — an HR /
-- employer user (employers row + employer_org(), transcribed from
-- supabase_employer_dashboard.sql) and an admin — so the suite can show
-- that a document which is internal by structure stays internal.
-- ============================================================
create table employers (
  email text primary key, user_id uuid null references auth.users(id),
  org_id uuid null references organizations(id), is_active boolean not null default true
);
create or replace function employer_org() returns uuid language sql security definer stable set search_path = public as $$
  select org_id from employers where is_active and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email')) limit 1 $$;
grant select on employers to authenticated;

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000005', 'hr@example.test'),
  ('a0000000-0000-4000-8000-000000000006', 'admin@example.test');
-- HR manager of Hollard (d…01), Tumelo's own employer.
insert into employers (email, user_id, org_id) values
  ('hr@example.test', 'a0000000-0000-4000-8000-000000000005', 'd0000000-0000-4000-8000-000000000001');
insert into admins (email) values ('admin@example.test');
