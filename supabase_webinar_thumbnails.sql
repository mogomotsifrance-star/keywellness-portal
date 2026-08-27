-- ============================================================
-- Key Wellness — Webinar Thumbnails: Batch 1 (schema)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor).
-- Run once; safe to re-run (ADD COLUMN IF NOT EXISTS).
--
-- WARNING: dev and main share ONE Supabase project — this is
-- production-live the moment it is applied. Additive only: one nullable
-- column, no DROP, no destructive ALTER, no data rewrite, no policy change.
-- Rollback: migrations/rollback-webinar-thumbnails.sql
-- (written and committed BEFORE this file, per project rule).
--
-- Batch 0 findings this file is shaped by
-- (docs/build/BATCH-0-WEBINAR-THUMBNAILS-FINDINGS.md):
--   • There is NO `webinars` table. Webinars are content_items rows with
--     kind='webinar' (video_path = Vimeo ref). The thumbnail column goes
--     on content_items, alongside the existing webinar_date (added by
--     supabase_sedimosa_phase2_batch1.sql).
--   • thumbnail_url does not exist yet anywhere (grep-confirmed).
--   • Thumbnails are STORED, never live-fetched: populated once at
--     upload/edit time (Vimeo oEmbed or manual), then rendered as a plain
--     image. NULL everywhere on existing rows → members keep the current
--     generated-SVG placeholder (kwPoster), no visible change.
--   • RLS unchanged: content_items_admin_all (is_admin()) already gates all
--     writes; members have no write path. No policy touched here.
-- ============================================================


-- ── content_items.thumbnail_url ─────────────────────────────────
-- Stored poster image URL for kind='webinar' rows. Typically a Vimeo
-- oEmbed thumbnail (i.vimeocdn.com/...) captured at upload/edit time, or a
-- manually-pasted image URL when oEmbed yields nothing under embed-only
-- privacy. NULL = fall back to the existing styled placeholder. Lessons
-- (kind='lesson') keep their title-matched kwPoster art and ignore this.
alter table public.content_items
  add column if not exists thumbnail_url text;


-- ── VERIFICATION CHECKLIST (run after applying) ──────────────────
-- 1. Column exists, nullable, null everywhere:
--      select column_name, is_nullable, data_type
--      from information_schema.columns
--      where table_schema='public' and table_name='content_items'
--        and column_name='thumbnail_url';                 -- 1 row, YES, text
--      select count(*) filter (where thumbnail_url is not null) as with_thumb,
--             count(*) as total
--      from content_items where kind='webinar';            -- with_thumb = 0
--
-- 2. Existing rows unaffected — the Learn page + webinar spotlight render
--    exactly as before a member's next load (null thumbnail → placeholder).
--
-- 3. A member session still cannot UPDATE (unchanged; retest anyway):
--      await sb.from('content_items')
--        .update({ thumbnail_url:'x' })
--        .eq('kind','webinar');                            -- expect RLS: 0 rows / error
-- ─────────────────────────────────────────────────────────────────
