-- ============================================================
-- Key Wellness — Learning Pathways: Pathway 2 (Financial Stability)
-- Insert 10 lessons from the Financial Stability/ Storage folder.
-- Run in Supabase SQL Editor — safe to re-run (idempotent inserts).
--
-- Assumes pathway_id = 2 exists in the `pathways` table with
-- title = 'Financial Stability'. Verify first:
--   select id, title from pathways order by sort_order;
-- ============================================================

-- ── Section labels for Pathway 2 ────────────────────────────────────
-- Section A  — Debt & Credit (lessons 1–3)
-- Section B  — Banking & Saving (lessons 4–5)
-- Section C  — Investing & Wealth Building (lessons 6–9)
-- Section D  — Protection & Risk (lesson 10)

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Managing and Reducing Debt',                        2, 'Debt & Credit',                1,  'Financial Stability/Module 17 -Managing and Reducing Debt_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Managing and Reducing Debt');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Understanding Credit Reports and Credit Scores',    2, 'Debt & Credit',                2,  'Financial Stability/Module 18 -Understanding Credit Reports and Credit Scores_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Understanding Credit Reports and Credit Scores');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Avoiding Financial Scams and Fraud',               2, 'Debt & Credit',                3,  'Financial Stability/Module 19 - Avoiding Financial Scams and Fraud_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Avoiding Financial Scams and Fraud');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Banking Basics',                                    2, 'Banking & Saving',             4,  'Financial Stability/Module 20 -Banking Basics_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Banking Basics');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Saving Strategies',                                 2, 'Banking & Saving',             5,  'Financial Stability/Module 21 - Saving Strategies_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Saving Strategies');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Introduction to Investing',                         2, 'Investing & Wealth Building',  6,  'Financial Stability/Module 22 - Introduction to Investing_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Introduction to Investing');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Investment Options',                                2, 'Investing & Wealth Building',  7,  'Financial Stability/Module 23 -Investment Options_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Investment Options');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Risk and Return',                                   2, 'Investing & Wealth Building',  8,  'Financial Stability/Module 24 -Risk and Return_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Risk and Return');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Retirement Planning',                               2, 'Investing & Wealth Building',  9,  'Financial Stability/Module 25 -Retirement Planning_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Retirement Planning');

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Insurance Essentials',                              2, 'Protection & Risk',            10, 'Financial Stability/Module 26 -Insurance Essentials_video_4k.mp4'
where not exists (select 1 from public.content_items where pathway_id = 2 and title = 'Insurance Essentials');


-- ── VERIFICATION ─────────────────────────────────────────────────────
-- Run after inserting to confirm all 10 lessons landed correctly:
--
--   select sort_order, title, section_label, video_path
--   from content_items where pathway_id = 2 order by sort_order;
--
-- Expect: 10 rows, sort_order 1-10, every video_path starting with
-- 'Financial Stability/'.
--
-- Spot-check a URL (should return HTTP 200, Content-Type: video/mp4):
--   curl -sI "https://tarmpqxsabbehgjaonfz.supabase.co/storage/v1/object/public/Videos/Financial%20Stability/Module%2017%20-Managing%20and%20Reducing%20Debt_video_4k.mp4"
-- ─────────────────────────────────────────────────────────────────────
