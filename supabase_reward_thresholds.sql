-- ============================================================
-- Key Wellness — Reward Thresholds (Rewards-reshape Batch 2)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE TABLE IF NOT EXISTS, ON CONFLICT
-- DO NOTHING on the seed insert).
--
-- Purely additive: one new table. Nothing existing is altered.
--
-- Thresholds differ by category AND by member tenure (first season on
-- the platform vs returning), because learning points are dominated by
-- one-time content events (article/video/quiz) that a returning member
-- has already exhausted.
--
-- Tenure rule (implemented identically in supabase_rewards_reshape.sql's
-- org_rewards()/record_reward_fulfilment() and in index.html's client-side
-- Progress card — see BUILD-NOTES.md): a member is "first season" during
-- the calendar quarter containing their auth.users.created_at; every later
-- quarter they are "returning". profiles has no created_at column of its
-- own (confirmed absent — see BUILD-NOTES.md), so auth.users.created_at is
-- the canonical join for this.
--
-- No admin UI for this table (deliberate — deferred per scope discipline).
-- Staff manage it directly via SQL Editor `update` statements.
-- ============================================================

create table if not exists public.reward_thresholds (
  category text primary key check (category in ('utilisation','learning','progress')),
  first_season_points int not null,
  returning_points int not null,
  updated_at timestamptz not null default now()
);

insert into public.reward_thresholds (category, first_season_points, returning_points) values
  ('utilisation', 300, 300),
  ('learning',    500, 150),   -- returning value MUST be reviewed each season against new content published
  ('progress',    300, 300)
on conflict (category) do nothing;

alter table public.reward_thresholds enable row level security;

drop policy if exists thresholds_readable on public.reward_thresholds;
create policy thresholds_readable on public.reward_thresholds
  for select to authenticated using (true);

-- Deliberately no insert/update/delete policy for authenticated — this table
-- is staff-managed via the SQL Editor only (admin UI deferred, see above).


-- ── VERIFICATION QUERIES ─────────────────────────────────────────

-- 1. Table seeded, readable by any authenticated user, not writable:
--    select * from reward_thresholds order by category;
--    Expect: exactly 3 rows (utilisation, learning, progress) with the
--    values above. As a logged-in member, on index.html, via the browser
--    console (type `sb.rpc(...)`/`sb.from(...)` directly — sb is a
--    page-level const, not window._toolSb, which only exists on the
--    standalone tool pages via kw-profile-sync.js):
--      await sb.from('reward_thresholds').select('*');       -- succeeds
--      await sb.from('reward_thresholds').update({first_season_points:1}).eq('category','progress'); -- fails (no policy)

-- 2. Tenure rule sanity check — seed/pick two real profiles, one created
--    this quarter and one created last quarter, and confirm the formula:
--      select id, created_at,
--             (to_char(created_at,'YYYY"-Q"Q') = to_char(now(),'YYYY"-Q"Q')) as is_first_season
--      from auth.users
--      where id in ('<this-quarter-user-id>', '<last-quarter-user-id>');
--    Expect: true for the this-quarter user, false for the last-quarter user.
-- ─────────────────────────────────────────────────────────────
