-- ============================================================
-- Key Wellness — Learning Pathways Batch 2: schema & seeds
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (IF NOT EXISTS / ON CONFLICT DO NOTHING).
--
-- WARNING: dev and main share one Supabase project — this is
-- production-immediate the moment it is applied. Rollback is recorded in
-- migrations/rollback-notes.md BEFORE this file (per project convention).
--
-- Batch 0 discovery confirmed `content_items`/`content_progress` do NOT
-- exist in this project (the brief assumed they did and planned to ALTER
-- them) — both are CREATE TABLE here, not ALTER. No naming collisions with
-- `pathways`/`quizzes`/`quiz_questions`/`quiz_attempts`/`certificates`
-- either (also confirmed in Batch 0). See BATCH-0-LMS-FINDINGS.md.
--
-- video_path values below use the REAL filenames Tshenolo already uploaded
-- to the `Videos` bucket (confirmed via a live storage listing after Batch
-- 1's policy was applied) — not the lesson-01.mp4 convention originally
-- documented. The welcome video has NOT been uploaded yet — its
-- content_items row uses a placeholder path ('welcome.mp4') flagged in
-- BUILD-NOTES.md as a pending manual upload; nothing else depends on that
-- file existing for this batch to apply cleanly.
-- ============================================================


-- ── 1. Pathways ──────────────────────────────────────────────

create table if not exists public.pathways (
  id                 smallint primary key,
  title              text not null,
  description        text,
  sort_order         smallint not null,
  status             text not null check (status in ('active','locked','coming_soon')),
  certificate_level  text,
  created_at         timestamptz not null default now()
);

insert into public.pathways (id, title, description, sort_order, status, certificate_level) values
  (1, 'Foundation', 'The essentials of financial literacy — mindset, budgeting, debt, and protecting what you build.', 1, 'active', 'Foundations'),
  (2, 'Financial Stability', 'Building on the basics toward consistent, resilient financial habits.', 2, 'locked', 'Intermediate'),
  (3, 'Growth (Coming Soon)', 'Advanced wealth-building topics.', 3, 'coming_soon', 'Advanced')
on conflict (id) do nothing;


-- ── 2. Content items (videos) — created fresh, NOT altered ─────
-- pathway_id null = the welcome video, outside every pathway.

create table if not exists public.content_items (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  pathway_id        smallint references public.pathways(id),
  section_label     text,
  sort_order        smallint,
  video_path        text,
  poster_path       text,
  duration_seconds  int,
  created_at        timestamptz not null default now(),
  unique (pathway_id, sort_order)
);

-- Welcome video — outside all pathways. Real file not yet uploaded
-- (Batch 0/1 confirmed no `welcome*` object in the Videos bucket); this
-- placeholder path must be corrected once Tshenolo uploads it.
insert into public.content_items (title, pathway_id, section_label, sort_order, video_path)
select 'Welcome to Key Wellness', null, null, null, 'welcome.mp4'
where not exists (
  select 1 from public.content_items where pathway_id is null and title = 'Welcome to Key Wellness'
);

-- Pathway 1 — 15 lessons, real uploaded filenames (case- and space-exact;
-- URL-encode at render time in JS, store raw here).
insert into public.content_items (title, pathway_id, section_label, sort_order, video_path) values
  ('Introduction to Financial Literacy',        1, 'Mindset & Psychology',    1,  'Module 1_Introduction to Financial Literacy_video.mp4'),
  ('Understanding Your Relationship with Money', 1, 'Mindset & Psychology',    2,  'Module 2_Understanding Your Relationship with Money_video.mp4'),
  ('Emotional Spending',                        1, 'Mindset & Psychology',    3,  'Module 3_Emotional Spending_video.mp4'),
  ('Lifestyle Inflation',                       1, 'Mindset & Psychology',    4,  'Module 4_Lifestyle Inflation_video.mp4'),
  ('Qualifying vs Affording',                   1, 'Mindset & Psychology',    5,  'Module 5_Qualifying vs Affording_video.mp4'),
  ('The Three Money Problems',                  1, 'Diagnosis & Direction',   6,  'Module 6_The Three Money Problems_video.mp4'),
  ('Setting SMART Financial Goals',             1, 'Diagnosis & Direction',   7,  'Module 7_Setting SMART Financial Goals_video.mp4'),
  ('Understanding Your Payslip',                1, 'Practical Foundations',   8,  'Module 8_Understanding Your Payslip_video.mp4'),
  ('Creating a Personal Budget',                1, 'Practical Foundations',   9,  'Module 9_Creating a Personal Budget_video.mp4'),
  ('Managing Cash Flow',                        1, 'Practical Foundations',   10, 'Module 10_Managing Cash Flow_video.mp4'),
  ('Needs vs Wants',                            1, 'Practical Foundations',   11, 'Module 11 -Needs vs Wants_video_4k.mp4'),
  ('Building Better Money Habits',              1, 'Practical Foundations',   12, 'Module 12 -Building Better Money Habits_video_4k.mp4'),
  ('Emergency Funds',                           1, 'Protection & Debt',       13, 'Module 13 - Emergency Funds_video_4k.mp4'),
  ('Understanding Debt',                        1, 'Protection & Debt',       14, 'Module 14 - Understanding Debt_video_4k.mp4'),
  ('Assets vs Liabilities',                     1, 'Wealth Thinking',         15, 'Module 15 - Assets vs Liabilities_video_4k (1).mp4')
on conflict (pathway_id, sort_order) do nothing;


-- ── 3. Content progress (per-member completion) ─────────────────

create table if not exists public.content_progress (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  content_id   uuid not null references public.content_items(id) on delete cascade,
  completed_at timestamptz not null default now(),
  unique (user_id, content_id)
);

create index if not exists content_progress_user_idx on public.content_progress(user_id);


-- ── 4. Quizzes ────────────────────────────────────────────────

create table if not exists public.quizzes (
  id             uuid primary key default gen_random_uuid(),
  pathway_id     smallint not null unique references public.pathways(id),
  pass_mark      smallint not null default 6,
  question_count smallint not null default 8,
  created_at     timestamptz not null default now()
);

insert into public.quizzes (pathway_id, pass_mark, question_count)
select 1, 6, 8
where not exists (select 1 from public.quizzes where pathway_id = 1);


-- ── 5. Quiz questions — base table, member SELECT denied entirely ──

create table if not exists public.quiz_questions (
  id             uuid primary key default gen_random_uuid(),
  quiz_id        uuid not null references public.quizzes(id) on delete cascade,
  sort_order     smallint not null,
  section_label  text,
  question       text not null,
  options        jsonb not null,
  correct_index  smallint not null,
  created_at     timestamptz not null default now(),
  unique (quiz_id, sort_order)
);

insert into public.quiz_questions (quiz_id, sort_order, section_label, question, options, correct_index)
select q.id, v.sort_order, v.section_label, v.question, v.options::jsonb, v.correct_index
from public.quizzes q
cross join (values
  (1, 'A', 'The five core pillars of financial literacy are:',
    '["Earning, spending, saving, borrowing, and investing","Budgeting, banking, insurance, tax, and retirement","Income, credit, property, shares, and pension","Planning, tracking, cutting, growing, and protecting"]', 0),
  (2, 'A', 'The most effective first tool against emotional spending is:',
    '["Cancelling your bank cards","A deliberate 24–48 hour pause before unplanned purchases","Avoiding shops and online stores entirely","Increasing your income"]', 1),
  (3, 'A', 'A bank approving you for a loan means:',
    '["You can comfortably afford the repayments","The repayment fits your budget and long-term goals","The bank believes you are likely to repay it, based on their risk model","The bank has assessed your full financial wellbeing"]', 2),
  (4, 'B', 'If your essential expenses exceed your take-home pay no matter how carefully you budget, you have:',
    '["An expense problem","A debt problem","An income problem","A budgeting problem"]', 2),
  (5, 'C', 'Which figure should your monthly budget be built around?',
    '["Your gross salary","Your net (take-home) salary","Your salary before voluntary deductions","Your salary plus expected overtime"]', 1),
  (6, 'C', 'Under the 50/30/20 budgeting rule, the 20% is allocated to:',
    '["Wants such as entertainment and dining out","Needs such as rent and transport","Savings and debt repayment above the minimums","Emergency spending only"]', 2),
  (7, 'D', 'The target size for a full emergency fund is:',
    '["One month of gross salary","Three to six months of essential living expenses","A fixed P1,000","Ten percent of your annual income"]', 1),
  (8, 'E', 'An asset is best defined as something that:',
    '["Is expensive and impressive to own","Was bought with cash rather than credit","Puts money into your pocket or grows in value over time","Includes any property, including the home you live in"]', 2)
) as v(sort_order, section_label, question, options, correct_index)
where q.pathway_id = 1
on conflict (quiz_id, sort_order) do nothing;

-- View: everything EXCEPT correct_index. This is the only path members can
-- read quiz questions through — the base table below has no SELECT policy
-- for authenticated/anon at all. Deliberately NOT security_invoker: the
-- view must run with the OWNER's privileges to read past the base table's
-- RLS lockout while still only ever exposing these 6 columns.
create or replace view public.quiz_questions_public as
  select id, quiz_id, sort_order, section_label, question, options
  from public.quiz_questions;

grant select on public.quiz_questions_public to authenticated;


-- ── 6. Quiz attempts (append-only) ──────────────────────────────

create table if not exists public.quiz_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  quiz_id    uuid not null references public.quizzes(id),
  score      smallint not null,
  passed     boolean not null,
  answers    jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists quiz_attempts_user_idx on public.quiz_attempts(user_id);


-- ── 7. Certificates ──────────────────────────────────────────────

create table if not exists public.certificates (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  pathway_id        smallint not null references public.pathways(id),
  certificate_name  text not null,
  completed_on      date not null,
  created_at        timestamptz not null default now(),
  unique (user_id, pathway_id)
);


-- ── 8. RLS ─────────────────────────────────────────────────────
-- No HR/employer role policy anywhere below — per-member learning data
-- must stay invisible to HR (Batch 0 baseline: org_overview/org_report_data
-- only ever see aggregate, suppressed counts via points_events).

alter table public.pathways enable row level security;
drop policy if exists pathways_readable on public.pathways;
create policy pathways_readable on public.pathways
  for select to authenticated using (true);

alter table public.content_items enable row level security;
drop policy if exists content_items_readable on public.content_items;
create policy content_items_readable on public.content_items
  for select to authenticated using (true);

alter table public.content_progress enable row level security;
drop policy if exists content_progress_own on public.content_progress;
create policy content_progress_own on public.content_progress
  for select to authenticated
  using (user_id = auth.uid());
-- Deliberately no insert policy — content_progress rows are written only
-- by complete_video() (Batch 3, security definer).

alter table public.quizzes enable row level security;
drop policy if exists quizzes_readable on public.quizzes;
create policy quizzes_readable on public.quizzes
  for select to authenticated using (true);

alter table public.quiz_questions enable row level security;
-- Deliberately NO select/insert/update/delete policy for authenticated or
-- anon on this table at all — every column, including correct_index, is
-- unreachable by any client role. Only quiz_questions_public (above) and
-- the SECURITY DEFINER RPCs (Batch 3, run as table owner) can read it.

alter table public.quiz_attempts enable row level security;
drop policy if exists quiz_attempts_own on public.quiz_attempts;
create policy quiz_attempts_own on public.quiz_attempts
  for select to authenticated
  using (user_id = auth.uid());
-- Deliberately no insert policy — rows are written only by submit_quiz()
-- (Batch 3, security definer).

alter table public.certificates enable row level security;
drop policy if exists certificates_own on public.certificates;
create policy certificates_own on public.certificates
  for select to authenticated
  using (user_id = auth.uid());
-- Deliberately no insert policy — rows are written only by
-- issue_certificate() (Batch 3, security definer).


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as a real logged-in (non-admin) member, from the BROWSER
-- CONSOLE on the dev site (`sb.rpc(...)`/`sb.from(...)`), not the SQL
-- Editor (which runs as postgres and bypasses RLS):

-- 1. Correct answers are unreachable:
--      await sb.from('quiz_questions').select('correct_index');
--    Expect: an error (no select policy) or zero rows — never data.

-- 2. Public view returns all 8 questions, no answers:
--      await sb.from('quiz_questions_public').select('*').eq('quiz_id', '<quiz-1-id>');
--    Expect: 8 rows, each WITHOUT a correct_index key.

-- 3. Members cannot write progress/attempts/certificates directly:
--      await sb.from('quiz_attempts').insert({ user_id: (await sb.auth.getUser()).data.user.id, quiz_id: '<id>', score: 8, passed: true, answers: [] });
--      await sb.from('certificates').insert({ user_id: (await sb.auth.getUser()).data.user.id, pathway_id: 1, certificate_name: 'Hack', completed_on: '2020-01-01' });
--    Expect: an RLS error on both, no row inserted.

-- 4. Pathways/content_items/quizzes readable:
--      await sb.from('pathways').select('*');           -- 3 rows
--      await sb.from('content_items').select('*').eq('pathway_id', 1);  -- 15 rows
--      await sb.from('quizzes').select('*');             -- 1 row, pass_mark 6
-- ─────────────────────────────────────────────────────────────
