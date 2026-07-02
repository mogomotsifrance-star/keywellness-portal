-- ============================================================
-- Key Wellness — Fix employers.user_id primary key
-- Run in Supabase SQL Editor.
--
-- Problem: employers.user_id is still `primary key` (supabase_multitenancy.sql),
-- which means it can never be NULL. supabase_employer_email.sql added an
-- `email` column and documented `insert into employers (email, org_id)
-- values (...)` as the way to add an employer before they've registered —
-- but that insert fails with a not-null violation on user_id, because it's
-- still the PK. Confirmed in the Table Editor: user_id shows as required,
-- email shows under "Optional Fields" — backwards from the intended flow.
--
-- Fix:
--   1. Add a surrogate `id` primary key.
--   2. Drop the PK constraint on user_id, keep it nullable + FK'd to
--      auth.users, add a unique constraint so one user can't get two rows.
--   3. Add a unique constraint on lower(email) so the same HR contact
--      can't be added twice.
--
-- Safe to re-run — uses IF EXISTS / IF NOT EXISTS guards.
-- ============================================================

-- ── ROLLBACK NOTE ─────────────────────────────────────────────
-- Current shape (from supabase_multitenancy.sql):
--   user_id uuid primary key references auth.users(id) on delete cascade,
--   org_id  uuid not null references organizations(id) on delete cascade,
--   created_at timestamptz not null default now()
-- plus (from supabase_employer_email.sql): email text
-- To roll back: drop the new id/unique constraints and re-add
--   `alter table employers add primary key (user_id);`
-- (only possible if every row still has a non-null user_id at that time).
-- ─────────────────────────────────────────────────────────────

-- 1. Surrogate primary key
alter table employers
  add column if not exists id uuid not null default gen_random_uuid();

-- Drop the old PK (this also drops its implicit unique index on user_id)
alter table employers
  drop constraint if exists employers_pkey;

alter table employers
  add constraint employers_pkey primary key (id);

-- 2. user_id: nullable, still FK'd, but unique when present
alter table employers
  alter column user_id drop not null;

drop index if exists employers_user_id_key;
create unique index employers_user_id_key
  on employers (user_id)
  where user_id is not null;

-- (FK to auth.users already exists from supabase_multitenancy.sql and is
--  unaffected by dropping the PK — only the primary-key-ness is removed.)

-- 3. email: unique when present, so the same HR contact can't be added twice
drop index if exists employers_email_key;
create unique index employers_email_key
  on employers (lower(email))
  where email is not null;

-- ── VERIFICATION ──────────────────────────────────────────────
-- 1. Confirm new shape:
--    select column_name, is_nullable, column_default
--    from information_schema.columns
--    where table_name = 'employers' order by ordinal_position;
--
-- 2. Confirm PK is now `id`:
--    select constraint_name, constraint_type
--    from information_schema.table_constraints
--    where table_name = 'employers' and constraint_type = 'PRIMARY KEY';
--
-- 3. Confirm the documented email-only insert now works:
--    insert into employers (email, org_id)
--    values ('hr@newcompany.com', (select id from organizations where invite_code = 'TEST-001'));
--    select * from employers where email = 'hr@newcompany.com';
--
-- 4. Confirm duplicate email is rejected:
--    insert into employers (email, org_id) values ('hr@newcompany.com', (select id from organizations limit 1));
--    -- should raise: duplicate key value violates unique constraint "employers_email_key"
--
-- 5. Re-run supabase_verify.sql — employers table checks should still pass.
-- ─────────────────────────────────────────────────────────────
