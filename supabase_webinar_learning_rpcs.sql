-- ============================================================
-- Key Wellness — Org Webinars & Quarterly Thresholds: Batch 4
-- Server-verified video completion + Learning qualification.
-- Run in the Supabase SQL Editor AFTER supabase_webinars_thresholds_schema.sql.
-- Run once; safe to re-run (CREATE OR REPLACE).
--
-- WARNING: dev and main share ONE Supabase project — production-live on
-- apply. Rollback: migrations/rollback-webinars-thresholds.sql SECTION B.
--
-- What changes:
--   • record_video_progress() — the ONLY write path into
--     video_watch_progress / video_watch_credits. "Watched" = server-side
--     position ≥ 80% of duration. Learning credit at most once per video
--     per quarter (DB-enforced by video_watch_credits' primary key), with
--     the rewatch rule (rewatches credit only at 100% lifetime library
--     completion). Webinars (kind='webinar') NEVER earn Learning credit.
--   • learning_qualified() — watched ⅓ of the live library this quarter.
--     Library size computed live, never hardcoded. Owner-only (no grant):
--     callable only from inside other SECURITY DEFINER functions
--     (org_rewards, my_rewards_qualification) — HR can never invoke it
--     directly for an arbitrary member.
--   • complete_video() — reshaped: still owns content_progress + the
--     sequential-unlock chain, but NO LONGER awards points (credit moved
--     to record_video_progress's 80% rule). Rejects webinar items.
--   • The 150-pt Returning Learning threshold (reward_thresholds.learning)
--     is superseded — org_rewards()/the member card stop reading it in
--     Batch 5. The row itself is deprecated in place, not dropped.
-- ============================================================


-- ── 1. record_video_progress(p_content_id, p_position_seconds, p_duration_seconds)
-- Called by the player: every ~15s, on pause, and on ended — for lessons
-- AND webinars. Returns a truthful payload; never lies about credit.

create or replace function public.record_video_progress(
  p_content_id      uuid,
  p_position_seconds int,
  p_duration_seconds int
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_item       record;
  v_quarter    text := to_char(now() at time zone 'Africa/Gaborone', 'YYYY"-Q"Q');
  v_pos        int;
  v_dur        int;
  v_row        record;
  v_completed  boolean := false;
  v_newly_done boolean := false;
  v_credited   boolean := false;
  v_reason     text := null;
  v_points     int := 0;
  v_prev_id    uuid;
  v_lifetime_done_before boolean;
  v_lib_size   int;
  v_done_count int;
  v_award      json;
  v_rows       int;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- Admin preview sessions record nothing and can never mint points.
  if is_admin() then
    return jsonb_build_object('recorded', false, 'credited', false, 'reason', 'admin_account');
  end if;

  select id, kind, pathway_id, sort_order, duration_seconds
  into v_item
  from content_items where id = p_content_id;

  if v_item.id is null then
    raise exception 'content item not found';
  end if;

  -- Sanitize client-reported values. The stored duration prefers the
  -- content_items metadata when present (admin-controlled) over the
  -- client-reported figure.
  v_pos := greatest(0, least(coalesce(p_position_seconds, 0), 6 * 3600));
  v_dur := coalesce(v_item.duration_seconds, nullif(greatest(coalesce(p_duration_seconds, 0), 0), 0));
  if v_dur is null or v_dur <= 0 then
    -- No usable duration: record the position, but completion can't be judged.
    v_reason := 'no_duration';
  else
    -- A position can never exceed the video itself — protects against a
    -- longer video's position being misattributed to a shorter one.
    v_pos := least(v_pos, v_dur);
  end if;

  insert into video_watch_progress as vwp (user_id, video_id, max_position_seconds, duration_seconds, updated_at)
  values (v_uid, p_content_id, v_pos, v_dur, now())
  on conflict (user_id, video_id) do update
    set max_position_seconds = greatest(vwp.max_position_seconds, excluded.max_position_seconds),
        duration_seconds     = coalesce(excluded.duration_seconds, vwp.duration_seconds),
        updated_at           = now()
  returning * into v_row;

  -- Was this video ever completed BEFORE this call? (drives the rewatch rule)
  v_lifetime_done_before := v_row.completed_at is not null;

  v_completed := v_dur is not null and v_row.max_position_seconds >= ceil(0.8 * v_dur);

  if v_completed and not v_lifetime_done_before then
    update video_watch_progress set completed_at = now()
    where id = v_row.id and completed_at is null;
    v_newly_done := true;
  end if;

  -- ── Learning credit (lessons only) ────────────────────────────
  if not v_completed then
    v_reason := coalesce(v_reason, 'not_completed');
  elsif v_item.kind = 'webinar' then
    -- Locked decision: webinars award NO Learning-category credit, ever.
    v_reason := 'webinar_no_credit';
  elsif v_item.pathway_id is null then
    -- Welcome video: not part of the countable library.
    v_reason := 'not_in_library';
  else
    -- Sequence guard, mirroring complete_video(): credit only for lessons
    -- the member could legitimately reach.
    select id into v_prev_id
    from content_items
    where pathway_id = v_item.pathway_id and kind = 'lesson' and sort_order < v_item.sort_order
    order by sort_order desc limit 1;

    if v_prev_id is not null and not exists (
      select 1 from content_progress where user_id = v_uid and content_id = v_prev_id
    ) and not exists (
      select 1 from video_watch_progress
      where user_id = v_uid and video_id = v_prev_id and completed_at is not null
    ) then
      v_reason := 'sequence_locked';
    else
      -- Rewatch rule: a video completed in an earlier session credits again
      -- only if the member has completed 100% of the current library
      -- lifetime (union of new-system completions and legacy
      -- content_progress rows, so early adopters aren't penalised).
      if v_lifetime_done_before then
        select count(*) into v_lib_size
        from content_items ci
        join pathways p on p.id = ci.pathway_id
        where p.status = 'active' and ci.kind = 'lesson' and ci.published = true;

        select count(distinct ci.id) into v_done_count
        from content_items ci
        join pathways p on p.id = ci.pathway_id
        where p.status = 'active' and ci.kind = 'lesson' and ci.published = true
          and (
            exists (select 1 from video_watch_progress w
                    where w.user_id = v_uid and w.video_id = ci.id and w.completed_at is not null)
            or exists (select 1 from content_progress cp
                       where cp.user_id = v_uid and cp.content_id = ci.id)
          );

        if v_lib_size = 0 or v_done_count < v_lib_size then
          v_reason := 'rewatch_locked';
        end if;
      end if;

      if v_reason is null then
        with ins as (
          insert into video_watch_credits (user_id, video_id, quarter)
          values (v_uid, p_content_id, v_quarter)
          on conflict (user_id, video_id, quarter) do nothing
          returning 1
        )
        select count(*) into v_rows from ins;

        if v_rows > 0 then
          v_credited := true;
          -- Ledger award — same catalog-driven path as everything else.
          -- Ref embeds the quarter so the unique(user,event,ref) constraint
          -- matches the once-per-quarter credit exactly.
          v_award := award_points('video_watched', p_content_id::text || ':' || v_quarter);
          v_points := coalesce((v_award ->> 'points')::int, 0);
        else
          v_reason := 'already_credited_this_quarter';
        end if;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'recorded',       true,
    'completed',      v_completed,
    'first_completion', v_newly_done,
    'credited',       v_credited,
    'reason',         v_reason,
    'points_awarded', v_points,
    'quarter',        v_quarter
  );
end;
$$;

grant execute on function public.record_video_progress(uuid, int, int) to authenticated;


-- ── 2. learning_qualified(p_user, p_quarter) ─────────────────────
-- Owner-only helper (NO grant to authenticated): distinct credited library
-- videos in the quarter ≥ ceil(live library size × configured fraction).

create or replace function public.learning_qualified(p_user uuid, p_quarter text)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_lib_size int;
  v_fraction numeric;
  v_needed   int;
  v_credited int;
begin
  select count(*) into v_lib_size
  from content_items ci
  join pathways p on p.id = ci.pathway_id
  where p.status = 'active' and ci.kind = 'lesson' and ci.published = true;

  select coalesce((value)::numeric, 0.3333) into v_fraction
  from threshold_config where key = 'learning_library_fraction';
  v_fraction := coalesce(v_fraction, 0.3333);

  v_needed := ceil(v_lib_size * v_fraction);

  select count(distinct vwc.video_id) into v_credited
  from video_watch_credits vwc
  join content_items ci on ci.id = vwc.video_id
  join pathways p on p.id = ci.pathway_id
  where vwc.user_id = p_user
    and vwc.quarter = p_quarter
    and p.status = 'active' and ci.kind = 'lesson' and ci.published = true;

  return jsonb_build_object(
    'credited_videos', v_credited,
    'library_size',    v_lib_size,
    'needed',          v_needed,
    'qualified',       v_lib_size > 0 and v_credited >= v_needed
  );
end;
$$;

-- Deliberately NO grant: only other SECURITY DEFINER functions (running as
-- the owner) may call this. HR cannot probe members with it.
revoke execute on function public.learning_qualified(uuid, text) from public, anon, authenticated;


-- ── 3. complete_video() — reshaped: unlock chain only, no points ──
-- Identical to the supabase_lms_rpcs.sql version EXCEPT:
--   (a) webinar items are rejected (they are not lessons);
--   (b) the award_points('video_watched', ...) call is REMOVED — Learning
--       points now come exclusively from record_video_progress()'s
--       server-verified 80% rule.

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

  select id, kind, pathway_id, sort_order into v_item
  from content_items where id = p_content_id;

  if v_item.id is null then
    raise exception 'content item not found';
  end if;

  if v_item.kind = 'webinar' then
    raise exception 'webinars are not pathway lessons';
  end if;

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
    where pathway_id = v_item.pathway_id and kind = 'lesson' and sort_order < v_item.sort_order
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

  if v_item.pathway_id is not null then
    select id into v_next_id
    from content_items
    where pathway_id = v_item.pathway_id and kind = 'lesson' and sort_order = v_item.sort_order + 1;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'first_completion', v_first,
    'next_content_id', v_next_id
  );
end;
$$;

grant execute on function public.complete_video(uuid) to authenticated;


-- ── VERIFICATION CHECKLIST (run after applying, as a real member) ──
-- 1. Watch a lesson to 80%:
--      await sb.rpc('record_video_progress', { p_content_id:'<lesson-id>', p_position_seconds: <80% of dur>, p_duration_seconds: <dur> });
--    Expect: {recorded:true, completed:true, credited:true, points_awarded:25}.
--    points_events gains exactly ONE row (event_type video_watched,
--    ref '<id>:<quarter>'). video_watch_credits gains one row.
--
-- 2. Call it again with the same position (rewatch, same quarter):
--    Expect: {credited:false, reason:'already_credited_this_quarter'}, no new
--    ledger row (verify count unchanged).
--
-- 3. As a member who has NOT completed the whole library, next quarter,
--    rewatch a completed video to 80%:
--    Expect: {credited:false, reason:'rewatch_locked'}.
--    As a member with 100% lifetime completion: {credited:true}.
--
-- 4. Webinar: record 100% progress on a kind='webinar' item:
--    Expect: {completed:true, credited:false, reason:'webinar_no_credit'};
--    zero rows in video_watch_credits/points_events for it. Resume position
--    stored in video_watch_progress.
--
-- 5. Sequence bypass: report 100% on lesson 5 with lesson 4 unwatched:
--    Expect: {credited:false, reason:'sequence_locked'}.
--
-- 6. complete_video() still gates the unlock chain and no longer awards:
--    finish a lesson via the player (ended event) and confirm NO
--    points_events row appears from complete_video itself (the only
--    video_watched row has the ':<quarter>' ref from step 1's RPC).
--
-- 7. learning_qualified is not callable by clients:
--      await sb.rpc('learning_qualified', { p_user:'<any>', p_quarter:'2026-Q3' });
--    Expect: permission-denied error.
--
-- 8. Privacy guard: case-insensitive grep of this file for the forbidden
--    HR-facing term (see Batch 6 guard) must return zero hits — the word is
--    deliberately not written here so the file greps clean.
-- ─────────────────────────────────────────────────────────────────
