-- ============================================================
-- Key Wellness — HR Reporting Audit & International-Grade Report Upgrade
-- Batch 1: program_activities table + bookings.client_type column
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (all statements use IF NOT EXISTS)
--
-- Purely additive. Rollback recorded in BUILD-NOTES.md ("Batch 1 —
-- program_activities table + bookings.client_type") before this file was
-- written.
-- ============================================================


-- ── 1a. Programme activities (admin-inputted off-platform delivery) ──
-- Group education talks, branch interventions, webinars — counsellors
-- enter these so reports capture full programme delivery beyond the
-- booking flow. Aggregate by nature: attendee counts, never identities.

create table if not exists program_activities (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  activity_type text not null check (activity_type in
    ('group_intervention','education_talk','webinar','clinic','other')),
  title text not null,
  activity_date date not null,
  attendee_count integer not null check (attendee_count >= 0),
  delivery_mode text check (delivery_mode in ('physical','virtual','hybrid')),
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists program_activities_org_idx on program_activities(org_id);


-- ── RLS ───────────────────────────────────────────────────────
-- Counsellor/admin: full access. No HR policy at all — HR reaches this
-- data only via org_report_data()'s aggregated program_activities section
-- (Batch 2), never a direct table read, matching supabase_multitenancy.sql's
-- "deliberately NO employer policy" pattern for member-data tables. No
-- member policy either — this is counsellor-entered, org-level data with
-- no legitimate member-facing use.

alter table program_activities enable row level security;

drop policy if exists program_activities_admin_all on program_activities;
create policy program_activities_admin_all on program_activities
  for all
  using (is_admin())
  with check (is_admin());


-- ── 1b. Dependent flag on bookings (additive) ────────────────
-- Counsellors set this from the admin side when a session was for a
-- family member booked under a member's account. Defaults to 'member' so
-- every existing row is valid immediately, no backfill needed. Reports
-- surface this only as aggregate counts (suppressed <3) — see Batch 2.

alter table bookings
  add column if not exists client_type text default 'member'
    check (client_type in ('member','dependent'));


-- ── VERIFICATION QUERIES ─────────────────────────────────────
-- Run these per Batch 1's checklist.

-- 1. Tables/columns confirmed:
--    select column_name, data_type from information_schema.columns
--    where table_schema='public' and table_name='program_activities';
--    select column_name, data_type, column_default from information_schema.columns
--    where table_schema='public' and table_name='bookings' and column_name='client_type';

-- 2. RLS enabled + policy count (expect 1):
--    select relrowsecurity from pg_class where relname = 'program_activities';
--    select policyname, cmd from pg_policies where tablename = 'program_activities';

-- 3. As an HR (employer) test account, in the browser console:
--    await window._toolSb.from('program_activities').select('*');  -- must return [] (no policy matches)

-- 4. As a member test account:
--    await window._toolSb.from('program_activities').select('*');  -- must return [] (no policy matches)

-- 5. Existing pages still load — spot-check admin.html's Appointments tab
--    and employer.html's Overview/Reports tabs render unaffected.
-- ─────────────────────────────────────────────────────────────
