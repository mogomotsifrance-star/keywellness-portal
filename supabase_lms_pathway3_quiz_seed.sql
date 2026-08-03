-- ============================================================
-- Key Wellness — Learning Pathways: Pathway 3 quiz (DRAFT)
-- ⚠️ DRAFT QUESTIONS — review the wording and answers against the
--    actual Pathway 3 video content before running this in the
--    Supabase SQL Editor. Written from the 10 lesson titles only.
--
-- Same pattern as the Pathway 1 & 2 quizzes:
-- 8 questions, pass mark 6 (70%), idempotent inserts.
--
-- Without this quiz, members can watch all 10 Pathway 3 lessons but
-- see "Quiz coming soon" at the end — no certificate awarded.
--
-- Section map (matches supabase_lms_pathway3_seed.sql):
--   A — Major Purchases       (lessons 1–2)
--   B — Tax & Family Planning (lessons 3–4)
--   C — Wealth Creation       (lessons 5–8)
--   D — Legacy & Review       (lessons 9–10)
-- ============================================================

insert into public.quizzes (pathway_id, pass_mark, question_count)
select 3, 6, 8
where not exists (select 1 from public.quizzes where pathway_id = 3);

insert into public.quiz_questions (quiz_id, sort_order, section_label, question, options, correct_index)
select q.id, v.sort_order, v.section_label, v.question, v.options::jsonb, v.correct_index
from public.quizzes q
cross join (values
  (1, 'A', 'When budgeting to buy a home, it is wise to plan for:',
    '["Only the monthly bond repayment","The purchase price, plus transfer costs, rates and ongoing maintenance","Just the deposit and nothing more","The bond repayment minus any rent you used to pay"]', 1),
  (2, 'A', 'Before financing a vehicle, the most important thing to consider is:',
    '["The colour and brand only","The total cost of the loan plus running costs, not just the monthly instalment","How new the model is","Whether friends approve of the choice"]', 1),
  (3, 'B', 'Understanding tax basics matters because:',
    '["Tax is optional for most earners","Knowing your obligations and deductions helps you keep more of what you earn legally","Only businesses pay tax","Tax has no effect on take-home pay"]', 1),
  (4, 'B', 'The best time to start saving for a child''s education is:',
    '["The year before they start university","As early as possible, so compound growth has more time to work","Only once fees are due","After all other spending is done"]', 1),
  (5, 'C', 'Building multiple streams of income mainly helps by:',
    '["Guaranteeing you never pay tax","Reducing reliance on a single source and improving financial resilience","Removing the need to budget","Replacing the need to save"]', 1),
  (6, 'C', 'A key difference between a survival mindset and an intentional wealth creator is:',
    '["Wealth creators avoid all risk","Intentional wealth creators plan and invest deliberately rather than only reacting to bills","Survivors always earn more","There is no real difference"]', 1),
  (7, 'C', 'The most reliable route to building long-term wealth is:',
    '["Chasing quick, high-risk returns","Consistent saving and investing over time, letting compounding work","Keeping all money in cash at home","Waiting for a single big windfall"]', 1),
  (8, 'D', 'The main purpose of estate planning is to:',
    '["Avoid ever paying any tax","Ensure your assets are distributed according to your wishes and ease the burden on family","Grow your investments faster","Replace the need for insurance"]', 1)
) as v(sort_order, section_label, question, options, correct_index)
where q.pathway_id = 3
on conflict (quiz_id, sort_order) do nothing;

-- ── VERIFICATION ─────────────────────────────────────────────
-- Expect: one quiz row for pathway 3 and 8 questions attached.

select q.id, q.pathway_id, q.pass_mark, q.question_count,
       (select count(*) from public.quiz_questions qq where qq.quiz_id = q.id) as questions
from public.quizzes q
where q.pathway_id = 3;
