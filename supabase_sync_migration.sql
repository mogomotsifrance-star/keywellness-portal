-- ============================================================
-- Key Wellness — Supabase Sync Migration
-- Run this in your Supabase SQL Editor
-- ============================================================

-- 1. stress_logs table (new) — stores every stress entry from Check-in
CREATE TABLE IF NOT EXISTS stress_logs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  level      INTEGER NOT NULL CHECK (level BETWEEN 1 AND 10),
  tags       TEXT[]   DEFAULT '{}',
  notes      TEXT     DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for fast per-user queries
CREATE INDEX IF NOT EXISTS stress_logs_user_id_idx ON stress_logs(user_id);

-- Row-level security
ALTER TABLE stress_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own stress logs"
  ON stress_logs FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own stress logs"
  ON stress_logs FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own stress logs"
  ON stress_logs FOR DELETE
  USING (auth.uid() = user_id);


-- 2. Add phone and avatar_b64 columns to profiles (if they don't exist)
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS phone      TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS avatar_b64 TEXT DEFAULT '';


-- 3. Verify tables
SELECT 'stress_logs' AS table_name, COUNT(*) AS rows FROM stress_logs
UNION ALL
SELECT 'profiles',   COUNT(*) FROM profiles;
