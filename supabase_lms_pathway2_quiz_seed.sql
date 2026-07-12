-- ============================================================
-- Key Wellness — Learning Pathways: Pathway 2 quiz (DRAFT)
-- ⚠️ DRAFT QUESTIONS — review the wording and answers against the
--    actual Pathway 2 video content before running this in the
--    Supabase SQL Editor. Written from the 10 lesson titles only.
--
-- Same pattern as the Pathway 1 quiz in supabase_lms_schema.sql:
-- 8 questions, pass mark 6 (70%), idempotent inserts.
--
-- Without this quiz, members can watch all 10 Pathway 2 lessons but
-- see "Quiz coming soon" at the end — no certificate, and Pathway 3
-- can never unlock for them once it gets content.
--
-- Section map (matches the seed):
--   A — Debt & Credit (lessons 1–3)
--   B — Banking & Saving (lessons 4–5)
--   C — Investing & Wealth Building (lessons 6–9)
--   D — Protection & Risk (lesson 10)
-- ============================================================

insert into public.quizzes (pathway_id, pass_mark, question_count)
select 2, 6, 8
where not exists (select 1 from public.quizzes where pathway_id = 2);

insert into public.quiz_questions (quiz_id, sort_order, section_label, question, options, correct_index)
select q.id, v.sort_order, v.section_label, v.question, v.options::jsonb, v.correct_index
from public.quizzes q
cross join (values
  (1, 'A', 'The most effective way to pay off multiple debts is:',
    '["Paying only the minimum on every debt until your income grows","Putting extra money on one target debt while keeping up minimums on the rest","Taking a new loan to consolidate whenever repayments feel heavy","Ignoring the smallest debts because they matter least"]', 1),
  (2, 'A', 'A credit score is best described as:',
    '["A record of your salary history","A number lenders use to estimate how likely you are to repay","A measure of how wealthy you are","A list of all your bank accounts"]', 1),
  (3, 'A', 'A common warning sign of a financial scam is:',
    '["A licensed provider explaining its fees in writing","An investment that takes years to grow","Guaranteed high returns with little or no risk","Being asked to visit a branch to verify your identity"]', 2),
  (4, 'B', 'The main advantage of keeping savings in a separate account is:',
    '["It always earns the highest interest rate","It keeps the money out of easy reach of everyday spending","Banks require savings to be held separately","It removes all bank charges"]', 1),
  (5, 'C', 'The relationship between risk and return in investing is:',
    '["Higher potential returns generally come with higher risk","Risk and return are unrelated","Low-risk investments always earn more over time","Risk only applies to shares"]', 0),
  (6, 'C', 'Diversification means:',
    '["Buying only one strong company''s shares","Spreading your money across different investments to reduce risk","Keeping all your savings in cash","Switching banks every year"]', 1),
  (7, 'C', 'The biggest advantage of starting retirement savings early is:',
    '["You can retire without a pension fund","Compound growth has more time to work in your favour","Employers contribute more when you are young","You avoid paying tax completely"]', 1),
  (8, 'D', 'The main purpose of insurance is to:',
    '["Grow your wealth faster than investing","Transfer the cost of large, unexpected losses to an insurer","Guarantee you never lose money","Replace the need for an emergency fund"]', 1)
) as v(sort_order, section_label, question, options, correct_index)
where q.pathway_id = 2
on conflict (quiz_id, sort_order) do nothing;

-- ── VERIFICATION ─────────────────────────────────────────────
-- Expect: one quiz row for pathway 2 and 8 questions attached.

select q.id, q.pathway_id, q.pass_mark, q.question_count,
       (select count(*) from public.quiz_questions qq where qq.quiz_id = q.id) as questions
from public.quizzes q
where q.pathway_id = 2;
