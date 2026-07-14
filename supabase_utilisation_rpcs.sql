-- ============================================================
-- Key Wellness — Org Webinars & Quarterly Thresholds: Batch 5a
-- Utilisation qualification + event-time award wiring.
-- Run in the Supabase SQL Editor AFTER supabase_webinar_learning_rpcs.sql.
-- Run once; safe to re-run (CREATE OR REPLACE / DROP TRIGGER IF EXISTS).
--
-- WARNING: dev and main share ONE Supabase project — production-live on
-- apply. Rollback: migrations/rollback-webinars-thresholds.sql SECTION C.
--
-- Contents:
--   1. award_points() v3 — extends the live (integrity-fix) definition with
--      the five new quarterly event types, all evidence-gated and
--      server-normalised. Existing branches are byte-carried from
--      supabase_points_integrity_fix.sql.
--   2. award_session_attended() trigger — admin marks attendance in
--      admin.html; the ledger row is written server-side for the MEMBER
--      (award_points() can't be used here: auth.uid() would be the admin).
--   3. utilisation_qualified(p_user, p_quarter) — owner-only, all four
--      pillars with AND logic. HR can never call it per-member.
--   4. my_rewards_qualification() — member-scoped wrapper for the Rewards
--      Progress card (own pillars only).
--
-- Timezone rule: quarter/window boundaries are computed in
-- Africa/Gaborone per the locked decisions. The points_events.season
-- stamp keeps the existing UTC to_char(now(),...) convention — season is
-- a display/points bucket; qualification reads raw timestamps, not season.
-- ============================================================


-- ── 1. award_points() v3 ─────────────────────────────────────────

create or replace function public.award_points(p_event_type text, p_ref_id text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_points int;
  v_active boolean;
  v_ref    text;
  v_season text;
  v_ok     boolean := false;
  v_rows   int;
  v_awarded boolean;
  v_total  bigint;
  v_cap    int;
  -- Gaborone-local quarter/window context for the new event types
  v_local_now   timestamp := now() at time zone 'Africa/Gaborone';
  v_gab_quarter text;
  v_qstart      date;
  v_window_idx  int;
  v_tool        text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select points, active into v_points, v_active
  from points_catalog where event_type = p_event_type;

  if v_points is null or not coalesce(v_active, false) then
    raise exception 'unknown or inactive event type: %', p_event_type;
  end if;

  v_gab_quarter := to_char(v_local_now, 'YYYY"-Q"Q');
  v_qstart := make_date(extract(year from v_local_now)::int,
                        ((extract(quarter from v_local_now)::int - 1) * 3) + 1, 1);
  v_window_idx := floor((v_local_now::date - v_qstart) / 14.0)::int;

  -- ── Server-normalised ref_id ───────────────────────────────────
  if p_event_type in ('monthly_checkin', 'assessment_complete') then
    v_ref := to_char(now(), 'YYYY-MM');
  elsif p_event_type in ('improvement', 'checkin_streak_3') then
    v_ref := to_char(now(), 'YYYY"-Q"Q');
  elsif p_event_type = 'onboarding_complete' then
    v_ref := 'once';

  elsif p_event_type = 'budget_saved' then
    -- Client names the month it saved; must be a real YYYY-MM.
    if p_ref_id is null or p_ref_id !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception 'budget_saved requires a YYYY-MM ref';
    end if;
    v_ref := p_ref_id;

  elsif p_event_type = 'checkin_logged' then
    -- Server decides the fortnight window — one credit per window, never
    -- more, regardless of what the client sends. Six check-ins in one week
    -- collide on the same ref and award once.
    v_ref := v_gab_quarter || ':W' || v_window_idx;

  elsif p_event_type = 'ef_tool_used' then
    -- First EF meaningful use per quarter.
    v_ref := v_gab_quarter;

  elsif p_event_type = 'tool_used' then
    -- First meaningful use per tool per quarter.
    if p_ref_id is null or length(trim(p_ref_id)) = 0 then
      raise exception 'ref_id required for event type: %', p_event_type;
    end if;
    v_tool := left(trim(p_ref_id), 40);
    v_ref := v_tool || ':' || v_gab_quarter;

  else
    -- Content events (article_read, video_watched, tool_first_use,
    -- session_booked, session_attended): client ref accepted, length-capped.
    if p_ref_id is null or length(trim(p_ref_id)) = 0 then
      raise exception 'ref_id required for event type: %', p_event_type;
    end if;
    v_ref := left(p_ref_id, 120);
  end if;

  -- ── Evidence: the event must have actually happened ────────────
  if p_event_type = 'assessment_complete' then
    v_ok := exists (
      select 1 from assessments
      where user_id = v_uid and created_at > now() - interval '1 hour'
    );

  elsif p_event_type = 'monthly_checkin' then
    v_ok := exists (
      select 1 from checkins
      where user_id = v_uid and created_at >= date_trunc('month', now())
    );

  elsif p_event_type = 'checkin_streak_3' then
    v_ok := (
      select count(distinct date_trunc('month', created_at)) >= 3
      from checkins
      where user_id = v_uid and created_at >= now() - interval '3 months'
    );

  elsif p_event_type = 'session_booked' then
    v_ok := exists (
      select 1 from bookings
      where user_id = v_uid and id::text = p_ref_id
    );

  elsif p_event_type = 'session_attended' then
    -- Normally written by the attendance trigger; this branch exists so a
    -- legitimate self-call (e.g. backfill) still demands a booking of the
    -- caller's own that an admin has verified.
    v_ok := exists (
      select 1 from bookings
      where user_id = v_uid and id::text = p_ref_id and attended = true
    );

  elsif p_event_type = 'onboarding_complete' then
    v_ok := exists (select 1 from profiles where id = v_uid);

  elsif p_event_type = 'improvement' then
    v_ok := coalesce((
      with latest2 as (
        select cat_scores, created_at
        from assessments
        where user_id = v_uid
        order by created_at desc
        limit 2
      ),
      ranked as (
        select cat_scores, row_number() over (order by created_at desc) as rn
        from latest2
      ),
      newest as (select cat_scores from ranked where rn = 1),
      older  as (select cat_scores from ranked where rn = 2)
      select exists (
        select 1
        from newest n
        cross join older o
        cross join lateral jsonb_each_text(n.cat_scores) as nd(key, val)
        join lateral jsonb_each_text(o.cat_scores) as od(key, val)
          on od.key = nd.key
        where nd.key <> '_insCount'
          and (nd.val::numeric - od.val::numeric) >= 5
      )
    ), false);

  elsif p_event_type = 'video_watched' then
    -- CHANGED (Batch 4/5): evidence is the once-per-quarter credit row
    -- written by record_video_progress()'s server-verified 80% rule, whose
    -- ref is '<content uuid>:<quarter>'. The old content_progress check no
    -- longer proves an in-quarter verified watch.
    v_ok := exists (
      select 1 from video_watch_credits w
      where w.user_id = v_uid
        and (w.video_id::text || ':' || w.quarter) = v_ref
    );

  elsif p_event_type = 'article_read' then
    v_ok := exists (
      select 1 from tool_data
      where user_id = v_uid
        and tool = 'articles_read'
        and coalesce(data->'read', '[]'::jsonb) ? p_ref_id
    );

  elsif p_event_type = 'budget_saved' then
    -- The month must actually exist in the member's saved budget blob.
    v_ok := exists (
      select 1 from tool_data
      where user_id = v_uid
        and tool = 'budget_planner'
        and coalesce(data->'budgets', '{}'::jsonb) ? v_ref
    );

  elsif p_event_type = 'checkin_logged' then
    -- A check-in row must exist inside the CURRENT fortnight window.
    v_ok := exists (
      select 1 from checkins
      where user_id = v_uid
        and floor((((created_at at time zone 'Africa/Gaborone')::date) - v_qstart) / 14.0)::int = v_window_idx
        and (created_at at time zone 'Africa/Gaborone')::date >= v_qstart
    );

  elsif p_event_type = 'ef_tool_used' then
    v_ok := exists (
      select 1 from tool_usage_events
      where user_id = v_uid
        and tool_key = 'emergency_fund'
        and to_char(created_at at time zone 'Africa/Gaborone', 'YYYY"-Q"Q') = v_gab_quarter
    );

  elsif p_event_type = 'tool_used' then
    -- EF has its own event; 'tool_used' is strictly for a DIFFERENT tool.
    v_ok := v_tool <> 'emergency_fund' and exists (
      select 1 from tool_usage_events
      where user_id = v_uid
        and tool_key = v_tool
        and to_char(created_at at time zone 'Africa/Gaborone', 'YYYY"-Q"Q') = v_gab_quarter
    );

  else
    -- tool_first_use (deactivated in Batch 1, branch kept for safety):
    -- engagement signal with no backing row; bounded by the cap below.
    v_ok := true;
  end if;

  -- ── Per-period volume caps (unchanged from the integrity fix) ──
  if v_ok then
    v_cap := case p_event_type
               when 'tool_first_use' then 20
               when 'article_read'   then 50
               when 'session_booked' then 8
               else null
             end;
    if v_cap is not null then
      select count(*) into v_rows
      from points_events
      where user_id = v_uid
        and event_type = p_event_type
        and season = to_char(now(), 'YYYY"-Q"Q');
      if v_rows >= v_cap then
        v_ok := false;
      end if;
    end if;
  end if;

  if not v_ok then
    select coalesce(sum(points), 0) into v_total from points_events where user_id = v_uid;
    return json_build_object('awarded', false, 'points', 0, 'total', v_total);
  end if;

  v_season := to_char(now(), 'YYYY"-Q"Q');

  with ins as (
    insert into points_events (user_id, event_type, ref_id, points, season)
    values (v_uid, p_event_type, v_ref, v_points, v_season)
    on conflict do nothing
    returning 1
  )
  select count(*) into v_rows from ins;

  v_awarded := v_rows > 0;

  select coalesce(sum(points), 0) into v_total from points_events where user_id = v_uid;

  return json_build_object(
    'awarded', v_awarded,
    'points',  case when v_awarded then v_points else 0 end,
    'total',   v_total
  );
end;
$$;

grant execute on function public.award_points(text, text) to authenticated;


-- ── 2. session_attended trigger ──────────────────────────────────
-- Fires when admin/Lone marks a booking attended in admin.html. Writes the
-- member's ledger row directly (catalog-priced, idempotent per booking).

create or replace function public.award_session_attended()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.attended is true
     and (old.attended is distinct from true)
     and new.user_id is not null then
    insert into points_events (user_id, event_type, ref_id, points, season)
    select new.user_id, 'session_attended', new.id::text, pc.points, to_char(now(), 'YYYY"-Q"Q')
    from points_catalog pc
    where pc.event_type = 'session_attended' and pc.active
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_award_session_attended on public.bookings;
create trigger trg_award_session_attended
  after update on public.bookings
  for each row
  execute function public.award_session_attended();


-- ── 3. utilisation_qualified(p_user, p_quarter) — owner-only ─────
-- All four pillars, AND logic. p_quarter: 'YYYY-QN'.

create or replace function public.utilisation_qualified(p_user uuid, p_quarter text)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_year   int;
  v_qtr    int;
  v_qstart date;
  v_qend   date;  -- exclusive
  v_budget_months_required int;
  v_windows_required       int;
  v_sessions_required      int;
  v_budget_count   int;
  v_window_count   int;
  v_sessions_count int;
  v_ef_used        boolean;
  v_other_tool     boolean;
  v_m1 text; v_m2 text; v_m3 text;
begin
  if p_quarter !~ '^[0-9]{4}-Q[1-4]$' then
    raise exception 'quarter must look like 2026-Q3';
  end if;
  v_year   := split_part(p_quarter, '-Q', 1)::int;
  v_qtr    := split_part(p_quarter, '-Q', 2)::int;
  v_qstart := make_date(v_year, (v_qtr - 1) * 3 + 1, 1);
  v_qend   := (v_qstart + interval '3 months')::date;
  v_m1 := to_char(v_qstart, 'YYYY-MM');
  v_m2 := to_char(v_qstart + interval '1 month', 'YYYY-MM');
  v_m3 := to_char(v_qstart + interval '2 months', 'YYYY-MM');

  select coalesce((value)::int, 3) into v_budget_months_required
  from threshold_config where key = 'budget_months_required';
  v_budget_months_required := coalesce(v_budget_months_required, 3);

  select coalesce((value)::int, 6) into v_windows_required
  from threshold_config where key = 'checkin_windows_required';
  v_windows_required := coalesce(v_windows_required, 6);

  select coalesce((value)::int, 1) into v_sessions_required
  from threshold_config where key = 'sessions_attended_required';
  v_sessions_required := coalesce(v_sessions_required, 1);

  -- 1. Budgets: a budget_saved ledger event per calendar month of the
  -- quarter, created (server timestamp) before quarter end. Retroactive
  -- creation inside the quarter counts — accepted v1 gaming vector,
  -- flagged in BUILD-NOTES.
  select count(distinct ref_id) into v_budget_count
  from points_events
  where user_id = p_user
    and event_type = 'budget_saved'
    and ref_id in (v_m1, v_m2, v_m3)
    and (created_at at time zone 'Africa/Gaborone')::date < v_qend;

  -- 2. Check-ins: distinct consecutive 14-day windows from quarter start.
  select count(distinct floor((((created_at at time zone 'Africa/Gaborone')::date) - v_qstart) / 14.0)::int)
  into v_window_count
  from checkins
  where user_id = p_user
    and (created_at at time zone 'Africa/Gaborone')::date >= v_qstart
    and (created_at at time zone 'Africa/Gaborone')::date <  v_qend;

  -- 3. Sessions: admin-verified attendance inside the quarter.
  select count(*) into v_sessions_count
  from bookings
  where user_id = p_user
    and attended = true
    and attendance_confirmed_at is not null
    and (attendance_confirmed_at at time zone 'Africa/Gaborone')::date >= v_qstart
    and (attendance_confirmed_at at time zone 'Africa/Gaborone')::date <  v_qend;

  -- 4. Tools: EF meaningful use (mandatory) + at least one other tool.
  select
    exists (select 1 from tool_usage_events t
            where t.user_id = p_user and t.tool_key = 'emergency_fund'
              and (t.created_at at time zone 'Africa/Gaborone')::date >= v_qstart
              and (t.created_at at time zone 'Africa/Gaborone')::date <  v_qend),
    exists (select 1 from tool_usage_events t
            where t.user_id = p_user and t.tool_key <> 'emergency_fund'
              and (t.created_at at time zone 'Africa/Gaborone')::date >= v_qstart
              and (t.created_at at time zone 'Africa/Gaborone')::date <  v_qend)
  into v_ef_used, v_other_tool;

  return jsonb_build_object(
    'budgets_met',      v_budget_count  >= v_budget_months_required,
    'budget_months',    v_budget_count,
    'budget_months_required', v_budget_months_required,
    'checkins_met',     v_window_count  >= v_windows_required,
    'checkin_windows',  v_window_count,
    'checkin_windows_required', v_windows_required,
    'sessions_met',     v_sessions_count >= v_sessions_required,
    'sessions_attended', v_sessions_count,
    'sessions_required', v_sessions_required,
    'tools_met',        (v_ef_used and v_other_tool),
    'ef_used',          v_ef_used,
    'other_tool_used',  v_other_tool,
    'qualified',        (v_budget_count >= v_budget_months_required
                         and v_window_count >= v_windows_required
                         and v_sessions_count >= v_sessions_required
                         and v_ef_used and v_other_tool)
  );
end;
$$;

-- Owner-only: never callable by clients or HR directly.
revoke execute on function public.utilisation_qualified(uuid, text) from public, anon, authenticated;


-- ── 4. my_rewards_qualification() — member-scoped ────────────────
-- Powers the member's own Rewards Progress card. Own rows only; exposes
-- nothing new to HR. Progress is deliberately ABSENT: its logic is
-- unchanged and stays where it already lives.

create or replace function public.my_rewards_qualification()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_quarter text := to_char(now() at time zone 'Africa/Gaborone', 'YYYY"-Q"Q');
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  return jsonb_build_object(
    'quarter',     v_quarter,
    'utilisation', utilisation_qualified(v_uid, v_quarter),
    'learning',    learning_qualified(v_uid, v_quarter)
  );
end;
$$;

grant execute on function public.my_rewards_qualification() to authenticated;


-- ── VERIFICATION CHECKLIST (after applying; fixtures per failure mode) ──
-- 1. 2/3 budgets: seed budget_saved events for 2 of the quarter's months →
--    utilisation_qualified(...)->>'budgets_met' = false; add the third → true.
-- 2. Six check-ins in one week → checkin_windows = 1 → checkins_met false.
--    One check-in in each of 6 different fortnight windows → true.
--    Duplicate award attempt inside a window: second
--    award_points('checkin_logged', ...) returns awarded:false (ref collision).
-- 3. Booked-but-not-attended booking → sessions_met false. Admin marks
--    attended in admin.html → points_events gains ONE session_attended row
--    (trigger), sessions_met true. Re-marking attendance → no second row.
-- 4. EF-only member (no second tool) → tools_met false; add one
--    tool_usage_events row for another tool → true.
-- 5. Fully compliant fixture → 'qualified': true.
-- 6. Clients cannot call utilisation_qualified directly (permission denied);
--    my_rewards_qualification() returns only the caller's own flags.
-- 7. session_booked now awards 10 (catalog change, Batch 1) — book a
--    session and check the toast/points row.
-- 8. Progress logic untouched: diff the org_rewards qualified_progress
--    expression (supabase_org_rewards_v2.sql) against
--    supabase_rewards_reshape.sql — identical; member card Progress bar
--    unchanged in index.html.
-- ─────────────────────────────────────────────────────────────────
