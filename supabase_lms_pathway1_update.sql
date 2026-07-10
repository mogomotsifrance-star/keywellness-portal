-- ============================================================
-- Key Wellness — Learning Pathways: Pathway 1 video reorg + new
-- lesson + real welcome video
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (every statement matches by title, idempotent).
--
-- WARNING: dev and main share one Supabase project — this is
-- production-immediate the moment it is applied. Rollback recorded in
-- migrations/rollback-notes.md BEFORE this file (per project convention).
--
-- Tshenolo (a) moved all 15 Pathway-1 files from the bucket root into a
-- `Foundation/` subfolder (and created an empty `Financial Stability/`
-- folder for Pathway 2 later), (b) added a new lesson, "Psychology of
-- Spending", inserted as lesson 4 — everything from the old lesson 4
-- onward shifts down one place (old 4-15 -> new 5-16) — and (c) uploaded
-- a real welcome video to the bucket root.
--
-- UPDATEs existing rows in place (matched by title, not delete+recreate)
-- specifically so any content_progress already recorded against these
-- ids survives. Section labels are untouched: every shifted lesson stays
-- in the same section it was already in, so grouping-by-section_label in
-- the frontend produces the correct new boundaries (Section A "Mindset &
-- Psychology" now spans lessons 1-6, everything else shifts accordingly)
-- with zero label changes needed.
-- ============================================================


-- ── 1. Shift existing 15 lessons: new sort_order + Foundation/ prefix ──
-- One statement per row, matched by title (stable across re-runs).
-- Postgres checks the (pathway_id, sort_order) unique constraint at the
-- end of EACH statement, not mid-statement, so touching one row per
-- statement here — rather than one big multi-row UPDATE — avoids any
-- transient collision with a title-matched row that hasn't moved yet.

update public.content_items set sort_order = 1,  video_path = 'Foundation/Module 1_Introduction to Financial Literacy_video.mp4'
  where pathway_id = 1 and title = 'Introduction to Financial Literacy';
update public.content_items set sort_order = 2,  video_path = 'Foundation/Module 2_Understanding Your Relationship with Money_video.mp4'
  where pathway_id = 1 and title = 'Understanding Your Relationship with Money';
update public.content_items set sort_order = 3,  video_path = 'Foundation/Module 3_Emotional Spending_video.mp4'
  where pathway_id = 1 and title = 'Emotional Spending';
update public.content_items set sort_order = 16, video_path = 'Foundation/Module 16_Assets vs Liabilities_video_4k (1).mp4'
  where pathway_id = 1 and title = 'Assets vs Liabilities'; -- moved out of the way first (was 15, nothing else targets 16 yet)
update public.content_items set sort_order = 15, video_path = 'Foundation/Module 15_Understanding Debt_video_4k.mp4'
  where pathway_id = 1 and title = 'Understanding Debt';
update public.content_items set sort_order = 14, video_path = 'Foundation/Module 14_Emergency Funds_video_4k.mp4'
  where pathway_id = 1 and title = 'Emergency Funds';
update public.content_items set sort_order = 13, video_path = 'Foundation/Module 13_Building Better Money Habits_video_4k.mp4'
  where pathway_id = 1 and title = 'Building Better Money Habits';
update public.content_items set sort_order = 12, video_path = 'Foundation/Module 12_Needs vs Wants_video_4k.mp4'
  where pathway_id = 1 and title = 'Needs vs Wants';
update public.content_items set sort_order = 11, video_path = 'Foundation/Module 11_Managing Cash Flow_video.mp4'
  where pathway_id = 1 and title = 'Managing Cash Flow';
update public.content_items set sort_order = 10, video_path = 'Foundation/Module 10_Creating a Personal Budget_video.mp4'
  where pathway_id = 1 and title = 'Creating a Personal Budget';
update public.content_items set sort_order = 9,  video_path = 'Foundation/Module 9_Understanding Your Payslip_video.mp4'
  where pathway_id = 1 and title = 'Understanding Your Payslip';
update public.content_items set sort_order = 8,  video_path = 'Foundation/Module 8_Setting SMART Financial Goals_video.mp4'
  where pathway_id = 1 and title = 'Setting SMART Financial Goals';
update public.content_items set sort_order = 7,  video_path = 'Foundation/Module 7_The Three Money Problems_video.mp4'
  where pathway_id = 1 and title = 'The Three Money Problems';
update public.content_items set sort_order = 6,  video_path = 'Foundation/Module 6_Qualifying vs Affording_video.mp4'
  where pathway_id = 1 and title = 'Qualifying vs Affording';
update public.content_items set sort_order = 5,  video_path = 'Foundation/Module 5_Lifestyle Inflation_video.mp4'
  where pathway_id = 1 and title = 'Lifestyle Inflation';


-- ── 2. New lesson: Psychology of Spending (lesson 4) ────────────────

insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Psychology of Spending', 1, 'Mindset & Psychology', 4, 'Foundation/Module 4_Psychology of Spending_video_4k.mp4'
where not exists (
  select 1 from public.content_items where pathway_id = 1 and title = 'Psychology of Spending'
);


-- ── 3. Real welcome video ────────────────────────────────────────────
-- Uploaded to the bucket root as "Wellcome to Key Wellness Portal.mp4"
-- (filename typo preserved intentionally — it must match the real
-- object key exactly, cosmetic spelling aside).

update public.content_items
set video_path = 'Wellcome to Key Wellness Portal.mp4'
where pathway_id is null and title = 'Welcome to Key Wellness';


-- ── VERIFICATION QUERIES ─────────────────────────────────────────

-- 1. All 16 Pathway-1 lessons, in order, with the new Foundation/ prefix:
--      select sort_order, title, section_label, video_path
--      from content_items where pathway_id = 1 order by sort_order;
--    Expect: 16 rows, sort_order 1-16 with no gaps or duplicates,
--    "Psychology of Spending" at position 4, every video_path starting
--    with "Foundation/".

-- 2. Welcome video path updated:
--      select video_path from content_items where pathway_id is null;
--    Expect: 'Wellcome to Key Wellness Portal.mp4'.

-- 3. Every path resolves live (spot-check a few, from any terminal):
--      curl -sI "https://tarmpqxsabbehgjaonfz.supabase.co/storage/v1/object/public/Videos/Foundation/Module%204_Psychology%20of%20Spending_video_4k.mp4"
--      curl -sI "https://tarmpqxsabbehgjaonfz.supabase.co/storage/v1/object/public/Videos/Wellcome%20to%20Key%20Wellness%20Portal.mp4"
--    Expect: 200, Content-Type: video/mp4, on both.
-- ─────────────────────────────────────────────────────────────
