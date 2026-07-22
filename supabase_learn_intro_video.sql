-- ============================================================
-- Key Wellness — Learn tab intro/banner video
-- Registers the "Learn Welcome Video" (uploaded to the Videos bucket
-- root) as a content_items row so it shows as the top banner on the
-- Learn tab, above "Continue learning".
--
-- Run in Supabase SQL Editor — safe to re-run (idempotent insert).
--
-- How the frontend finds it:
--   pathway_id = NULL  → not part of any pathway (won't appear in a
--                        pathway list, won't count toward Learning stats)
--   kind = 'lesson'    → plays through the standard native <video> player
--   video_path matches LP_INTRO_PATH in index.html (lpIntro()), which is
--   how it's told apart from the onboarding welcome video.
--
-- ⚠️ video_path must match the Storage filename EXACTLY (case + spaces).
-- ⚠️ Edit the title below if you want different banner text.
-- ============================================================

insert into public.content_items (title, pathway_id, video_path, kind, published)
select 'Welcome to the Knowledge Hub', null, 'Learn Welcome Video_video_4k.mp4', 'lesson', true
where not exists (
  select 1 from public.content_items
  where video_path = 'Learn Welcome Video_video_4k.mp4'
);

-- Verify:
--   select id, title, pathway_id, kind, published, video_path
--   from public.content_items
--   where video_path = 'Learn Welcome Video_video_4k.mp4';
