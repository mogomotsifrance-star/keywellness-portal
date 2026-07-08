-- ============================================================
-- Key Wellness — Organisation Utilisation Report Pipeline
-- Batch 1: bookings attendance columns + org_reports table + RLS
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (all statements use IF NOT EXISTS / OR REPLACE)
--
-- Purely additive: two new columns-sets, one new table. Nothing existing
-- is altered or dropped. Rollback statements are recorded in BUILD-NOTES.md
-- (top section, "Batch 1 — rollback statements") BEFORE this file was run.
-- ============================================================


-- ── 1a. Booking attendance columns ───────────────────────────
-- attended: null = unconfirmed, true = attended, false = no-show.
-- session_mode is distinct from the existing `session_type` column
-- (session_type is a counselling category; session_mode is delivery
-- channel — see BUILD-NOTES.md Batch 0 discovery for the naming clash
-- this was checked against).

alter table bookings
  add column if not exists attended boolean,
  add column if not exists attendance_confirmed_by uuid references auth.users(id),
  add column if not exists attendance_confirmed_at timestamptz,
  add column if not exists session_mode text check (session_mode in ('physical','virtual'));


-- ── 1b. org_reports table ────────────────────────────────────

create table if not exists org_reports (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations(id),
  period_start   date not null,
  period_end     date not null,
  period_label   text not null,              -- e.g. 'Q2 2026 (Apr–Jun)'
  status         text not null default 'draft' check (status in ('draft','published')),
  narrative      jsonb not null default '{}', -- keyed by section id, see Batch 3
  data_snapshot  jsonb,                       -- populated at publish, null while draft
  created_by     uuid not null references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  published_by   uuid references auth.users(id),
  published_at   timestamptz
);

create index if not exists org_reports_org_idx on org_reports(org_id);


-- ── 1c. RLS ───────────────────────────────────────────────────
-- No separate "counsellor" role exists in this codebase (admin.html's
-- gate checks only the `admins` table) — "counsellor/admin" from the spec
-- is implemented as is_admin(), same as every other admin-gated RPC here.
--
-- Four separate policies (not one blanket `for all`) so that editing a
-- published report fails at the RLS layer itself, independent of whatever
-- publish_org_report() does in Batch 4:
--   - UPDATE's `using` requires status = 'draft' on the EXISTING row, so a
--     published row is simply not a candidate for update under this policy.
--   - UPDATE's `with check` also requires status = 'draft' on the NEW row,
--     so a direct client update() cannot itself flip status to 'published'
--     — only the security-definer publish_org_report() RPC can (Batch 4),
--     which bypasses RLS the same way every other security-definer
--     function in this codebase does.

alter table org_reports enable row level security;

drop policy if exists org_reports_admin_select on org_reports;
create policy org_reports_admin_select on org_reports
  for select
  using (is_admin());

drop policy if exists org_reports_admin_insert on org_reports;
create policy org_reports_admin_insert on org_reports
  for insert
  with check (is_admin() and status = 'draft');

drop policy if exists org_reports_admin_update on org_reports;
create policy org_reports_admin_update on org_reports
  for update
  using (is_admin() and status = 'draft')
  with check (is_admin() and status = 'draft');

drop policy if exists org_reports_admin_delete on org_reports;
create policy org_reports_admin_delete on org_reports
  for delete
  using (is_admin() and status = 'draft');

-- HR: published reports for their own org only. No insert/update/delete —
-- HR never edits a report, only reads it.
drop policy if exists org_reports_hr_read on org_reports;
create policy org_reports_hr_read on org_reports
  for select
  using (status = 'published' and org_id = employer_org());

-- Members: no policy at all. RLS is enabled and default-deny with no
-- matching policy → zero rows, per invariant 1 (aggregate-only to HR) and
-- the members-get-zero-rows checklist requirement.


-- ── VERIFICATION QUERIES ─────────────────────────────────────
-- Run these after applying, per Batch 1's checklist.

-- 1. Columns exist:
--    select column_name, data_type from information_schema.columns
--    where table_schema='public' and table_name='bookings'
--      and column_name in ('attended','attendance_confirmed_by','attendance_confirmed_at','session_mode');

-- 2. Table exists with RLS enabled:
--    select relrowsecurity from pg_class where relname = 'org_reports';

-- 3. Policy count (expect 5: 4 admin + 1 hr):
--    select policyname, cmd from pg_policies where tablename = 'org_reports';

-- 4. As an HR (employer) test account, in the browser console (NOT the SQL
--    Editor, which bypasses RLS):
--    await window._toolSb.from('org_reports').select('*');             -- must return [] (no published rows yet)
--    await window._toolSb.from('org_reports').insert({ org_id: '<uuid>', period_start:'2026-01-01', period_end:'2026-03-31', period_label:'Q1 2026', created_by: '<uuid>' });
--    -- must fail (HR has no insert policy)

-- 5. As a member test account:
--    await window._toolSb.from('org_reports').select('*');             -- must return [] (no policy matches)

-- 6. As an admin/counsellor test account, insert a draft, then try to
--    update it after manually setting its status to 'published' via the
--    SQL Editor (which bypasses RLS) — the client-side update should then
--    return { data: [], error: null } (0 rows), NOT throw an error. Batch 3's
--    save handler must treat data.length === 0 as a failure — see
--    BUILD-NOTES.md's "Supabase-JS footgun" note.
-- ─────────────────────────────────────────────────────────────
