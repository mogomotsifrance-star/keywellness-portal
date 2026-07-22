-- ============================================================
-- Key Wellness — Learn tab intro/banner video
-- Registers / updates the "Learn Welcome Video" (uploaded to the Videos
-- bucket root) as a content_items row so it shows as the top banner on
-- the Learn tab, above "Continue learning".
--
-- Run in Supabase SQL Editor — safe to re-run (idempotent).
--
-- How the frontend finds it (index.html, lpIntro()):
--   pathway_id = NULL   → not part of any pathway (won't appear in a
--                         pathway list, won't count toward Learning stats)
--   kind = 'lesson'     → plays through the standard native <video> player
--   video_path LIKE 'Learn Welcome Video%'  → the prefix is how it's told
--                         apart from the onboarding welcome clip. Re-uploading
--                         a new cut only means changing the filename below.
--
-- ⚠️ CURRENT_FILE must match the Storage filename EXACTLY (case, spaces,
--    and the "(2)" suffix Supabase adds on re-upload).
-- ============================================================

-- 1. Point the existing intro row at the current file (the 2026-07-22 replacement).
update public.content_items
set video_path = 'Learn Welcome Video_video_4k (2).mp4'
where pathway_id is null
  and video_path like 'Learn Welcome Video%';

-- 2. First-time installs: create the row if it doesn't exist yet.
insert into public.content_items (title, pathway_id, video_path, kind, published)
select 'Welcome to the Knowledge Hub', null, 'Learn Welcome Video_video_4k (2).mp4', 'lesson', true
where not exists (
  select 1 from public.content_items
  where pathway_id is null and video_path like 'Learn Welcome Video%'
);

-- Verify:
--   select id, title, pathway_id, kind, published, video_path
--   from public.content_items
--   where pathway_id is null and video_path like 'Learn Welcome Video%';
--   Expect one row, video_path = 'Learn Welcome Video_video_4k (2).mp4'.
