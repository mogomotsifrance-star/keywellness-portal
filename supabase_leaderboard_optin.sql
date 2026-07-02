-- ============================================================
-- Key Wellness — Leaderboard opt-in & alias (Batch 3)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (IF NOT EXISTS).
--
-- Purely additive: two new nullable/defaulted columns on `profiles`.
-- Nothing existing is altered or dropped. Rollback in migrations/rollback-notes.md.
-- ============================================================

alter table public.profiles
  add column if not exists leaderboard_opt_in boolean not null default false,
  add column if not exists display_alias text check (char_length(display_alias) <= 30);

-- No RLS changes needed — profiles already has profiles_own (own row read/write)
-- and profiles_admin_read policies from supabase_multitenancy.sql, which cover
-- these two new columns automatically (RLS is row-level, not column-level).


-- ── VERIFICATION QUERIES ─────────────────────────────────────────

-- 1. Default is OFF for all existing users:
--    select count(*) from profiles where leaderboard_opt_in = true;
--    Expect: 0 immediately after running this migration.

-- 2. Column exists and is nullable for alias, non-null boolean for opt-in:
--    select column_name, is_nullable, column_default
--    from information_schema.columns
--    where table_name = 'profiles' and column_name in ('leaderboard_opt_in','display_alias');
-- ─────────────────────────────────────────────────────────────
