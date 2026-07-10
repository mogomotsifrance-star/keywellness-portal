-- ============================================================
-- Key Wellness — my_reward_fulfilments() RPC (Batch 5, member rewards visibility)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE OR REPLACE).
--
-- Purely additive: one new function. Nothing existing is altered.
-- Rollback (recorded in BUILD-NOTES.md before this file was run):
--   drop function if exists my_reward_fulfilments();
--
-- Why this is needed (full detail in BATCH-0-FINDINGS.md, section 0.4.3):
-- reward_fulfilments (supabase_reward_fulfilment.sql) has NO RLS policies
-- for `authenticated` at all — every existing read path
-- (org_reward_history()) is employer-only. There was previously no way
-- for a member to read their own fulfilment rows, despite the plan's
-- assumption that RLS already covered this. This RPC is the new,
-- member-scoped read path: security definer so it can read the table
-- (which has RLS enabled but no policies), hard-scoped to auth.uid() in
-- the query itself so it can never return another member's row — this is
-- NOT a new HR-facing surface, it mirrors the existing member-scoped
-- security-definer pattern already used by award_points().
-- ============================================================

create or replace function public.my_reward_fulfilments()
returns table (
  category     text,
  note         text,
  season       text,
  fulfilled_at timestamptz
)
language sql security definer set search_path = public as $$
  select rf.category, rf.note, rf.season, rf.created_at
  from reward_fulfilments rf
  where rf.user_id = auth.uid()
  order by rf.created_at desc;
$$;

grant execute on function public.my_reward_fulfilments() to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as real users via the browser console.

-- 1. As a member with fulfilments recorded against them — expect their own
--    rows only:
--    await sb.rpc('my_reward_fulfilments');

-- 2. Cross-member isolation — as member A, confirm member B's fulfilments
--    never appear, even if A and B are in the same org and season.

-- 3. As a member with zero fulfilments — expect an empty array, not an
--    error.

-- 4. Confirm no HR-facing fields leak through: no user_id, no org_id, no
--    first_name/last_name/email, no fulfilled_by — only category/note/
--    season/fulfilled_at, all describing the caller's own award.
-- ─────────────────────────────────────────────────────────────
