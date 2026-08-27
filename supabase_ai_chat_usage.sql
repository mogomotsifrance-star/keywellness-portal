-- ============================================================
-- Key Wellness — Ask Key (Member AI Chat): Batch 1 (schema)
-- Run this in the Supabase SQL Editor (dashboard -> SQL Editor).
-- Run once; safe to re-run (IF NOT EXISTS throughout).
--
-- WARNING: dev and main share ONE Supabase project — this is
-- production-live the moment it is applied. Additive only: one new
-- table + one index + RLS enable. No DROP, no destructive ALTER, no
-- data rewrite, no change to any existing table or policy.
-- Rollback: migrations/rollback-ask-claude-usage.sql
-- (written and committed BEFORE this file, per project rule).
--
-- Purpose (docs/build/BATCH-0-ASK-CLAUDE-FINDINGS.md, Locked Decisions 5/6/2.1):
--   Server-side backing store for the ask-claude Edge Function's
--   DAILY cap (20/user/day, Africa/Gaborone boundary) and BURST limit
--   (5/user/rolling minute), plus per-request token telemetry for cost
--   monitoring. ONE row is inserted per successful Anthropic response.
--
--   PRIVACY: this table stores COUNTS AND TOKEN TALLIES ONLY. It never
--   stores message content, prompts, snapshots, or any identifier
--   beyond user_id. Do not add a message/content column to it.
--
-- Access model:
--   • The Edge Function uses the SERVICE ROLE, which bypasses RLS —
--     it is the only reader and the only writer.
--   • RLS is enabled with NO client policies at all, so an anon/member
--     JWT can neither read nor insert (default-deny). Members must not
--     see usage rows, and must not be able to forge cap resets.
--   • Admin read access is intentionally deferred (future usage/cost
--     dashboard); no admin policy is added here.
-- ============================================================


-- ── ai_chat_usage ───────────────────────────────────────────────
-- One row per successful ask-claude response. used_at drives both the
-- daily cap (count rows since the Gaborone day boundary) and the burst
-- limit (count rows in the last rolling minute). Token columns are
-- nullable: a usage-row insert must never block the member's reply, so
-- if the Anthropic usage block is missing the row is still written with
-- NULL tallies rather than failing.
create table if not exists public.ai_chat_usage (
  id                 uuid        primary key default gen_random_uuid(),
  user_id            uuid        not null,
  used_at            timestamptz not null default now(),
  input_tokens       int,
  output_tokens      int,
  cache_read_tokens  int
);

-- Supports both cap queries: (user_id, used_at) range scans per user.
create index if not exists ai_chat_usage_user_used_at_idx
  on public.ai_chat_usage (user_id, used_at);

-- Default-deny: enable RLS and add NO policies. Service role bypasses
-- RLS (function path); every client role is denied read and write.
alter table public.ai_chat_usage enable row level security;


-- ── VERIFICATION CHECKLIST (run after applying) ──────────────────
-- 1. Table + index exist:
--      select column_name, data_type, is_nullable
--      from information_schema.columns
--      where table_schema='public' and table_name='ai_chat_usage'
--      order by ordinal_position;            -- 6 cols; token cols nullable
--      select indexname from pg_indexes
--      where schemaname='public' and tablename='ai_chat_usage';
--                                            -- pkey + ai_chat_usage_user_used_at_idx
--
-- 2. RLS on, zero policies:
--      select relrowsecurity from pg_class
--      where oid = 'public.ai_chat_usage'::regclass;   -- t
--      select count(*) from pg_policies
--      where schemaname='public' and tablename='ai_chat_usage';   -- 0
--
-- 3. A member session gets zero rows and cannot insert
--    (run in the browser console while logged in as a member):
--      await sb.from('ai_chat_usage').select('*');
--        -- expect: data = [] (default-deny read, no rows leak)
--      await sb.from('ai_chat_usage').insert({ user_id: (await sb.auth.getUser()).data.user.id });
--        -- expect: error / 0 rows (RLS blocks the insert)
--
-- 4. Rollback recorded: migrations/rollback-ask-claude-usage.sql (drops table).
-- ─────────────────────────────────────────────────────────────────
