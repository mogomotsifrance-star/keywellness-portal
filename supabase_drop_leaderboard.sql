-- ============================================================
-- Key Wellness — Drop the member leaderboard RPCs (Rewards-reshape
-- Batch 3 — product decision: member leaderboard removed, replaced
-- by the private Rewards Progress card in index.html)
-- Run this in the Supabase SQL Editor AFTER the corresponding
-- frontend change (index.html: VIEWS['leaderboard'] removed, NAV
-- entry removed) has been deployed to dev and confirmed working.
--
-- The verbatim recreate scripts for both functions are saved in
-- migrations/rollback-notes.md — run those first if this ever needs
-- to be undone.
--
-- org_rewards() is NOT touched here — it is reshaped in place by
-- supabase_rewards_reshape.sql (Batch 4), not dropped.
-- ============================================================

drop function if exists public.org_leaderboard(text);
drop function if exists public.org_leaderboard_self_rank(text);


-- ── VERIFICATION ─────────────────────────────────────────────
-- select proname from pg_proc where proname in ('org_leaderboard','org_leaderboard_self_rank');
-- Expect: no rows.
-- ─────────────────────────────────────────────────────────────
