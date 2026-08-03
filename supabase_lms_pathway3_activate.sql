-- ============================================================
-- Key Wellness — Learning Pathways: activate Pathway 3 (Growth)
-- Run in Supabase SQL Editor AFTER supabase_lms_pathway3_seed.sql.
--
-- This is the go-live flag: the pathway card in the UI stays
-- "🔒 Locked" until pathways.status = 'active'. This also strips the
-- "(Coming Soon)" suffix from the title so the card reads "Growth".
-- Safe to re-run. To roll back: set status back to 'coming_soon'
-- and title back to 'Growth (Coming Soon)'.
--
-- NOTE: server-side gating is unaffected — complete_video()/submit_quiz()
-- still enforce their own prerequisite rules per user. Activating the
-- status only removes the visual lock. If Pathway 3 needs a quiz +
-- certificate, seed that separately (see supabase_lms_pathway2_quiz_seed.sql).
-- ============================================================

update public.pathways
set status = 'active',
    title  = 'Growth'
where id = 3;

-- ── VERIFICATION ─────────────────────────────────────────────
-- Expect: 1 Foundation active · 2 Financial Stability active ·
--         3 Growth active, and 10 lessons under pathway 3.

select id, title, status, sort_order
from public.pathways
order by sort_order;

select count(*) as pathway3_lessons
from public.content_items
where pathway_id = 3;
