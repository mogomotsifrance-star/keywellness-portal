-- ============================================================
-- Key Wellness — Employer lookup by email (mirrors admins table pattern)
-- Run in Supabase SQL Editor.
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE).
--
-- Problem: employers table used user_id (UUID) which requires the
-- person to have already registered before HR can be set up.
-- Fix: add email column so employers can be added by email before
-- they ever create an account — exactly how admins work.
-- ============================================================

-- 1. Add email column to employers
alter table employers
  add column if not exists email text;

-- 2. Backfill email for any existing rows that have user_id set
update employers e
set email = lower(u.email)
from auth.users u
where u.id = e.user_id
  and e.email is null;

-- 3. Update employer_org() to look up by email (primary) or user_id (fallback)
--    Mirrors is_admin() which uses auth.jwt() ->> 'email'
create or replace function employer_org()
returns uuid
language sql security definer stable set search_path = public as $$
  select org_id from employers
  where lower(email) = lower(auth.jwt() ->> 'email')
     or user_id = auth.uid()
  limit 1;
$$;

-- 4. Update RLS on employers so a user can read their own row by email too
drop policy if exists employers_self_read on employers;
create policy employers_self_read on employers
  for select
  using (
    user_id = auth.uid()
    or lower(email) = lower(auth.jwt() ->> 'email')
  );

-- 5. When an employer logs in for the first time, backfill their user_id
--    automatically so future lookups work even without email.
--    This trigger fires on INSERT to auth.users.
create or replace function backfill_employer_user_id()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update employers
  set user_id = new.id
  where lower(email) = lower(new.email)
    and user_id is null;
  return new;
end;
$$;

drop trigger if exists trg_backfill_employer on auth.users;
create trigger trg_backfill_employer
  after insert on auth.users
  for each row
  execute function backfill_employer_user_id();

-- ── How to add an employer going forward ─────────────────────
-- Just insert their email and org. No UUID needed.
-- They can be added before they ever register.
--
--   insert into employers (email, org_id)
--   values (
--     'hr@company.com',
--     (select id from organizations where invite_code = 'TEST-001')
--   );
--
-- On their first login, employer_org() finds them by email and
-- routes them straight to employer.html — no member dashboard visit.
-- ─────────────────────────────────────────────────────────────

-- ── Fix existing employer (Lebone) without UUID ──────────────
-- The existing row has user_id but may not have email yet.
-- The backfill above (step 2) handles this automatically.
-- Verify with:
--   select user_id, email, org_id from employers;
-- ─────────────────────────────────────────────────────────────
