-- ============================================================
-- Key Wellness — Learning Pathways Batch 3: RPCs
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE OR REPLACE FUNCTION).
--
-- WARNING: dev and main share one Supabase project — this is
-- production-immediate the moment it is applied. Rollback is recorded in
-- migrations/rollback-notes.md BEFORE this file (per project convention).
--
-- Reuses existing infrastructure confirmed in Batch 0 discovery:
--   - award_points(p_event_type text, p_ref_id text) — 'video_watched'
--     (25 pts) and 'quiz_passed' (50 pts, Tshenolo's confirmed value, not
--     the brief's 75 — see BATCH-0-LMS-FINDINGS.md) are already seeded in
--     points_catalog with category='learning'. No catalog changes needed.
--   - is_admin() (supabase_multitenancy.sql) — existing SECURITY DEFINER
--     helper checking the `admins` table by JWT email. Reused directly
--     instead of re-implementing an admin lookup in each RPC.
--
-- Admin handling: complete_video() and submit_quiz() both hard-reject
-- (raise exception) for admin callers — not just "skip points silently".
-- The brief's Batch 3 §1 says "Reject if caller is an admin account (no
-- points events for admins)"; read literally rather than as points-only
-- suppression, since admins are staff accounts that don't otherwise use
-- member-facing features in this app (see BUILD-NOTES.md for the
-- reasoning and its QA implication — admin accounts cannot exercise this
-- flow; testing needs a real member account). issue_certificate() has no
-- separate admin check: it requires a prior passing quiz_attempt, which an
-- admin account can never create (submit_quiz rejects them first), so it's
-- unreachable for admins by construction — no need to duplicate the guard.
-- ============================================================


-- ── 0. Batch 2 tightening: quiz_questions_public was also readable by the
-- `anon` role (this project's default schema privileges grant anon SELECT
-- on new objects; a view has no RLS of its own to narrow that). Not a
-- security issue (never exposes correct_index or per-member data), but
-- narrowed to authenticated-only for consistency with every other policy
-- in this batch.

revoke select on public.quiz_questions_public from anon;


-- ── 1. complete_video(p_content_id uuid) ────────────────────────

create or replace function public.complete_video(p_content_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid           uuid := auth.uid();
  v_item          record;
  v_prev_id       uuid;
  v_prev_done     boolean;
  v_reachable     boolean;
  v_first         boolean;
  v_rows          int;
  v_next_id       uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  if is_admin() then
    raise exception 'admin accounts cannot complete pathway videos';
  end if;

  select id, pathway_id, sort_order into v_item
  from content_items where id = p_content_id;

  if v_item.id is null then
    raise exception 'content item not found';
  end if;

  -- Welcome video (no pathway) is always allowed. Otherwise: the pathway
  -- must be reachable, and (if not the first lesson) the previous lesson
  -- in the same pathway must already be complete for this user.
  if v_item.pathway_id is not null then

    if v_item.pathway_id = (select min(id) from pathways) then
      v_reachable := true;
    else
      v_reachable := exists (
        select 1
        from quiz_attempts qa
        join quizzes q on q.id = qa.quiz_id
        where qa.user_id = v_uid
          and qa.passed = true
          and q.pathway_id = v_item.pathway_id - 1
      );
    end if;

    if not v_reachable then
      raise exception 'this pathway is not yet unlocked';
    end if;

    select id into v_prev_id
    from content_items
    where pathway_id = v_item.pathway_id and sort_order < v_item.sort_order
    order by sort_order desc
    limit 1;

    if v_prev_id is not null then
      v_prev_done := exists (
        select 1 from content_progress
        where user_id = v_uid and content_id = v_prev_id
      );
      if not v_prev_done then
        raise exception 'complete the previous lesson first';
      end if;
    end if;

  end if;

  with ins as (
    insert into content_progress (user_id, content_id)
    values (v_uid, p_content_id)
    on conflict (user_id, content_id) do nothing
    returning 1
  )
  select count(*) into v_rows from ins;

  v_first := v_rows > 0;

  if v_first then
    perform award_points('video_watched', p_content_id::text);
  end if;

  if v_item.pathway_id is not null then
    select id into v_next_id
    from content_items
    where pathway_id = v_item.pathway_id and sort_order = v_item.sort_order + 1;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'first_completion', v_first,
    'next_content_id', v_next_id
  );
end;
$$;

grant execute on function public.complete_video(uuid) to authenticated;


-- ── 2. submit_quiz(p_quiz_id uuid, p_answers jsonb) ─────────────
-- p_answers shape: [{"question_id":"<uuid>","selected_index":<0-3>}, ...]
-- Unanswered/unmatched questions grade as incorrect, never as an error —
-- a member can submit a partial attempt and see the real score.

create or replace function public.submit_quiz(p_quiz_id uuid, p_answers jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid            uuid := auth.uid();
  v_quiz           record;
  v_total_lessons  int;
  v_done_lessons   int;
  v_score          smallint;
  v_per_question   boolean[];
  v_passed         boolean;
  v_already_passed boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  if is_admin() then
    raise exception 'admin accounts cannot take pathway quizzes';
  end if;

  select id, pathway_id, pass_mark into v_quiz
  from quizzes where id = p_quiz_id;

  if v_quiz.id is null then
    raise exception 'quiz not found';
  end if;

  select count(*) into v_total_lessons
  from content_items where pathway_id = v_quiz.pathway_id;

  select count(*) into v_done_lessons
  from content_progress cp
  join content_items ci on ci.id = cp.content_id
  where cp.user_id = v_uid and ci.pathway_id = v_quiz.pathway_id;

  if v_total_lessons = 0 or v_done_lessons < v_total_lessons then
    raise exception 'complete every video in this pathway before taking the quiz';
  end if;

  with answer_pairs as (
    select (elem->>'question_id')::uuid as question_id,
           (elem->>'selected_index')::smallint as selected_index
    from jsonb_array_elements(coalesce(p_answers, '[]'::jsonb)) as elem
  ),
  graded as (
    select qq.sort_order,
           (ap.selected_index is not null and ap.selected_index = qq.correct_index) as is_correct
    from quiz_questions qq
    left join answer_pairs ap on ap.question_id = qq.id
    where qq.quiz_id = p_quiz_id
  )
  select count(*) filter (where is_correct), array_agg(is_correct order by sort_order)
  into v_score, v_per_question
  from graded;

  v_passed := v_score >= v_quiz.pass_mark;

  v_already_passed := exists (
    select 1 from quiz_attempts
    where user_id = v_uid and quiz_id = p_quiz_id and passed = true
  );

  insert into quiz_attempts (user_id, quiz_id, score, passed, answers)
  values (v_uid, p_quiz_id, v_score, v_passed, coalesce(p_answers, '[]'::jsonb));

  if v_passed and not v_already_passed then
    perform award_points('quiz_passed', p_quiz_id::text);
  end if;

  return jsonb_build_object(
    'score', v_score,
    'passed', v_passed,
    'pass_mark', v_quiz.pass_mark,
    'per_question', to_jsonb(v_per_question)
  );
end;
$$;

grant execute on function public.submit_quiz(uuid, jsonb) to authenticated;


-- ── 3. issue_certificate(p_pathway_id smallint, p_name text) ────

create or replace function public.issue_certificate(p_pathway_id smallint, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid          uuid := auth.uid();
  v_quiz_id      uuid;
  v_name         text;
  v_completed_on date;
  v_cert         record;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_name := trim(p_name);
  if v_name = '' or length(v_name) > 60 then
    raise exception 'certificate name must be between 1 and 60 characters';
  end if;

  select id into v_quiz_id from quizzes where pathway_id = p_pathway_id;
  if v_quiz_id is null then
    raise exception 'no quiz configured for this pathway';
  end if;

  select min(created_at)::date into v_completed_on
  from quiz_attempts
  where user_id = v_uid and quiz_id = v_quiz_id and passed = true;

  if v_completed_on is null then
    raise exception 'pathway quiz not yet passed';
  end if;

  insert into certificates (user_id, pathway_id, certificate_name, completed_on)
  values (v_uid, p_pathway_id, v_name, v_completed_on)
  on conflict (user_id, pathway_id)
  do update set certificate_name = excluded.certificate_name
  returning * into v_cert;

  return to_jsonb(v_cert);
end;
$$;

grant execute on function public.issue_certificate(smallint, text) to authenticated;


-- ── VERIFICATION CHECKLIST ─────────────────────────────────────────
-- Run as a real logged-in (non-admin) member from the BROWSER CONSOLE:

-- 1. Sequence bypass rejected — try completing lesson 5 before lesson 4
--    (use a real content_items.id from `select id,title,sort_order from
--    content_items where pathway_id=1 order by sort_order`):
--      await sb.rpc('complete_video', { p_content_id: '<lesson-5-id>' });
--    Expect: an error ("complete the previous lesson first").

-- 2. Quiz submit with videos incomplete rejected:
--      await sb.rpc('submit_quiz', { p_quiz_id: '<quiz-1-id>', p_answers: [] });
--    Expect: an error ("complete every video...") unless all 15 are done.

-- 3. After legitimately completing all 15 lessons in order, then passing
--    the quiz once, submit again with all-correct answers:
--      await sb.rpc('submit_quiz', { p_quiz_id: '<quiz-1-id>', p_answers: [...8 correct pairs] });
--    Expect: {score:8, passed:true, ...} but NO second points toast/award —
--    check `select * from points_events where event_type='quiz_passed' and
--    user_id='<uid>'` in the SQL Editor returns exactly one row.

-- 4. Certificate before pass rejected (use a fresh test user with no
--    passing attempt):
--      await sb.rpc('issue_certificate', { p_pathway_id: 1, p_name: 'Test User' });
--    Expect: an error ("pathway quiz not yet passed").

-- 5. completed_on stable across re-issues — call issue_certificate twice
--    with different names after a real pass:
--      await sb.rpc('issue_certificate', { p_pathway_id: 1, p_name: 'First Name' });
--      await sb.rpc('issue_certificate', { p_pathway_id: 1, p_name: 'Corrected Name' });
--    Expect: certificate_name changes, completed_on is identical both times.

-- 6. Admin gets no points events / cannot use the RPCs — log in as an
--    admin account (present in the `admins` table) and try:
--      await sb.rpc('complete_video', { p_content_id: '<welcome-id>' });
--    Expect: an error ("admin accounts cannot complete pathway videos").

-- 7. grep this file for "improvement" — must return nothing (no HR-facing
--    logic leaked into these RPCs):
--      grep -i improvement supabase_lms_rpcs.sql   -- expect zero matches

-- 8. org_overview()/org_report_data() outputs unchanged from the Batch 0
--    baseline — run the existing org_report_data() RPC for a test org
--    before and after a real member completes videos/passes the quiz;
--    only the aggregate 'learning' counts (videos_watched, quizzes_passed)
--    should move, never per-member rows, and no new fields should appear.
-- ─────────────────────────────────────────────────────────────
