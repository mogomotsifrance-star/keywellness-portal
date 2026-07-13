-- ============================================================
-- Key Wellness — Learning Pathways: activate Pathway 2
-- Run in Supabase SQL Editor AFTER supabase_lms_pathway2_seed.sql.
--
-- This is the go-live flag from BUILD-NOTES: the pathway card in the
-- UI stays "🔒 Locked" until pathways.status = 'active'. Server-side
-- gating is unaffected — complete_video()/submit_quiz() still require
-- each user to pass the Pathway 1 quiz before Pathway 2 accepts
-- progress, and the frontend now mirrors that same rule.
-- Safe to re-run. To roll back: set status back to 'locked'.
-- ============================================================

update public.pathways
set status = 'active'
where id = 2;

-- ── VERIFICATION ─────────────────────────────────────────────
-- Expect: 1 Foundation active · 2 Financial Stability active ·
--         3 Growth coming_soon, and 10 lessons under pathway 2.

select id, title, status, sort_order
from public.pathways
order by sort_order;

select count(*) as pathway2_lessons
from public.content_items
where pathway_id = 2;
