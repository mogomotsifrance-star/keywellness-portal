-- ============================================================
-- Key Wellness — Learning Pathways Batch 1: `Videos` storage bucket
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (ON CONFLICT DO NOTHING / DROP POLICY IF EXISTS).
--
-- WARNING: dev and main share one Supabase project — this is
-- production-immediate the moment it is applied.
--
-- REVISED after the first version was applied: Tshenolo had already created
-- the bucket by hand via the dashboard UI, named `Videos` (capital V, not
-- lowercase `videos` as this file originally assumed — Supabase bucket ids
-- are case-sensitive) and uploaded all 15 Pathway-1 videos + a welcome/
-- emergency-fund file directly into its root, with descriptive filenames
-- (e.g. "Module 1_Introduction to...mp4"), not the lesson-01.mp4/
-- pathway-1/ subfolder convention originally documented. This version:
--   1. Points the public-read policy at the REAL bucket id (`Videos`).
--   2. Cleans up the stray empty `videos` (lowercase) bucket/policy the
--      first version of this file created — confirmed empty (0 objects)
--      before dropping, safe.
-- content_items.video_path (Batch 2) is seeded to match the REAL uploaded
-- filenames, not the lesson-01.mp4 convention — see supabase_lms_schema.sql.
--
-- SECOND REVISION: `delete from storage.objects/storage.buckets` is
-- blocked by a Supabase-managed trigger (`storage.protect_delete()`,
-- error 42501 — "Use the Storage API instead"), confirmed by running the
-- prior version. The whole script runs in one implicit transaction, so
-- that failure rolled back cleanly — nothing was applied. This version
-- drops the SQL-level cleanup of the stray empty lowercase `videos`
-- bucket entirely; it's harmless (confirmed empty, unreferenced by any
-- code) and can be deleted later via Storage → Buckets → ⋯ → Delete in
-- the dashboard UI at your convenience, or left in place indefinitely.
-- ============================================================


-- ── 1. Confirm the real bucket is public (idempotent no-op if already set
-- via the dashboard, which it is — the UI already shows a "PUBLIC" tag) ──

update storage.buckets set public = true where id = 'Videos';


-- ── 2. RLS — public SELECT only, on the REAL bucket ─────────────────
-- Deliberately NO insert/update/delete policy for anon/authenticated — a
-- direct client upload must fail with an RLS error (see verification below).
-- service_role bypasses RLS entirely by default, so it can still write.

drop policy if exists "videos_public_read" on storage.objects;
create policy "videos_public_read" on storage.objects
  for select
  using (bucket_id = 'Videos');


-- ── VERIFICATION QUERIES ─────────────────────────────────────────

-- 1. The real bucket is public:
--      select id, name, public from storage.buckets;
--    Expect: a row with id = 'Videos', public = true. A second row,
--    id = 'videos' (lowercase, empty, from the first version of this file),
--    may still be present — harmless, see header comment.

-- 2. Unauthenticated GET of an uploaded file succeeds (adjust filename to
--    match a real uploaded object — spaces must be URL-encoded as %20):
--      curl -sI "https://tarmpqxsabbehgjaonfz.supabase.co/storage/v1/object/public/Videos/Module%201_Introduction%20to%20Financial%20Literacy.mp4"
--    Expect: 200 (exact filename TBD — Claude Code will list the bucket's
--    real contents via the REST API once this policy is applied, since the
--    anon key can then read storage.objects for this bucket).

-- 3. Authenticated non-service INSERT fails — run from the BROWSER CONSOLE
--    on the dev site while logged in as a real (non-admin) member:
--      const blob = new Blob(['x'], { type: 'text/plain' });
--      await window.sb.storage.from('Videos').upload('hack.txt', blob);
--    Expect: an error object ("new row violates row-level security
--    policy"), no object created.
-- ─────────────────────────────────────────────────────────────
