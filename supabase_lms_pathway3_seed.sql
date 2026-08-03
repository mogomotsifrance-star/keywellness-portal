-- ============================================================
-- Key Wellness — Learning Pathways: Pathway 3 (Growth)
-- Insert 10 lessons from the Growth/ Storage folder.
-- Run in Supabase SQL Editor — safe to re-run (idempotent inserts).
--
-- Assumes pathway_id = 3 exists in the `pathways` table.
-- Verify first:
--   select id, title from pathways order by sort_order;
--
-- NOTE: filenames below are copied EXACTLY from the Storage bucket,
-- including the inconsistent spacing after "Module N -" and the
-- apostrophe in "Children's" (doubled to '' for SQL).
-- ============================================================

-- ── Section labels for Pathway 3 ────────────────────────────────────
-- Section A  — Major Purchases        (lessons 1–2)
-- Section B  — Tax & Family Planning  (lessons 3–4)
-- Section C  — Wealth Creation        (lessons 5–8)
-- Section D  — Legacy & Review        (lessons 9–10)

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Buying a Home',                              3, 'Major Purchases',        1,  'Growth/Module 1 - Buying a Home_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Buying a Home');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Vehicle Finance',                            3, 'Major Purchases',        2,  'Growth/Module 2 - Vehicle Finance_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Vehicle Finance');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Tax Basics',                                 3, 'Tax & Family Planning',  3,  'Growth/Module 3 -Tax Basics_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Tax Basics');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Planning for Children''s Education',         3, 'Tax & Family Planning',  4,  'Growth/Module 4 - Planning for Children''s Education_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Planning for Children''s Education');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Building Multiple Streams of Income',        3, 'Wealth Creation',        5,  'Growth/Module 5 - Building Multiple Streams of Income_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Building Multiple Streams of Income');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Survival vs. Intentional Wealth Creator',    3, 'Wealth Creation',        6,  'Growth/Module 6 - Survival vs. Intentional Wealth Creator_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Survival vs. Intentional Wealth Creator');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'The Five Stages of Financial Growth',        3, 'Wealth Creation',        7,  'Growth/Module 7 - The Five Stages of Financial Growth_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'The Five Stages of Financial Growth');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Building Long-Term Wealth',                  3, 'Wealth Creation',        8,  'Growth/Module 8 - Building Long-Term Wealth_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Building Long-Term Wealth');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Estate Planning',                            3, 'Legacy & Review',        9,  'Growth/Module 9 - Estate Planning_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Estate Planning');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Financial Wellness Review',                  3, 'Legacy & Review',        10, 'Growth/Module 10 -Financial Wellness Review_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 3 and title = 'Financial Wellness Review');


-- ── VERIFICATION ─────────────────────────────────────────────────────
-- Run after inserting to confirm all 10 lessons landed correctly:
--
--   select sort_order, title, section_label, video_path
--   from content_items where pathway_id = 3 order by sort_order;
--
-- Expect: 10 rows, sort_order 1-10, every video_path starting with 'Growth/'.
--
-- Spot-check a URL (should return HTTP 200, Content-Type: video/mp4):
--   curl -sI "https://tarmpqxsabbehgjaonfz.supabase.co/storage/v1/object/public/Videos/Growth/Module%201%20-%20Buying%20a%20Home_video_4k.mp4"
-- ─────────────────────────────────────────────────────────────────────
