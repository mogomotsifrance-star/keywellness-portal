-- ============================================================
-- Key Wellness — M4 fixture, loaded ON TOP of tests/m1-fixture.sql
--
-- m1-fixture brings everything org_report_data() needs: auth, organizations,
-- org_units, profiles (with live_cat_scores), bookings with all 24 live
-- columns, program_activities, org_reports, content_items, assessments,
-- points_events, threshold_config, _suppress_count and the role helpers.
--
-- This file adds only what m1-fixture lacks and M5 requires — the
-- notifications table — plus is_ops_admin() and real table privileges for the
-- `authenticated` role, so the RLS assertions are not vacuous.
--
-- The runner then applies M1, M5 and M4 on top.
-- ============================================================

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

-- is_ops_admin() belongs to supabase_support_audit.sql. M4 depends on it as a
-- NAME, not as a file, so it is defined here exactly as that migration defines
-- it rather than loading an unrelated migration to test this one.
create or replace function is_ops_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select is_admin();
$$;

-- is_staff() belongs to M5, which the runner applies. Nothing needed here.

-- Without these, `set role authenticated` fails with "permission denied for
-- table" and every RLS assertion would be testing the grant, not the policy.
grant usage on schema public to authenticated, anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;


-- ── People beyond m1-fixture's members ──────────────────────
-- m1-fixture seeds 8 members per organisation and one admin
-- (admin@keywellness.co.bw). M4 needs a named admin, an advisor, and Laone —
-- who is NOT staff and owns the invoice actions.

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000009', 'lone@keywellness.co.bw'),
  ('00000000-0000-0000-0000-00000000000d', 'laone@keywellness.co.bw'),
  ('00000000-0000-0000-0000-00000000000b', 'kefilwe@keywealth.co.bw'),
  ('00000000-0000-0000-0000-00000000000e', 'plainmember@example.test');

insert into admins (email) values ('lone@keywellness.co.bw');

insert into advisors (id, user_id, email, full_name, is_active)
values ('00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-00000000000b', 'kefilwe@keywealth.co.bw', 'Kefilwe', true);

insert into profiles (id, org_id)
values ('00000000-0000-0000-0000-00000000000e', null);
