-- ════════════════════════════════════════════════════════════════════
--  Points integrity hardening — audit findings P0-7 / P1-10
-- ════════════════════════════════════════════════════════════════════
--
--  ⚠️  REVIEW BEFORE RUNNING. This alters award_points() on the SHARED
--      production Supabase project. Apply it in a safe window and, right
--      after, sanity-check that legitimate point awards still work:
--        • complete a video in Learn  → video_watched still awarded
--        • read an article            → article_read still awarded
--        • open a tool                → tool_first_use still awarded (≤ cap)
--        • book a session             → session_booked still awarded (≤ cap)
--        • complete an assessment / check-in → unchanged
--
--  WHY: award_points() previously trusted the client for three content
--  events (article_read, video_watched, tool_first_use) via `v_ok := true`,
--  so a signed-in user could mint unlimited reward-bearing points from the
--  browser console by looping distinct ref_ids. Those points feed the HR
--  leaderboard / org_rewards payout list. This migration:
--    1. Gates `video_watched` on a real content_progress row (the legit
--       path — complete_video() — writes content_progress BEFORE awarding,
--       so it still passes; a direct console call with a fake id does not).
--    2. Gates `article_read` on the article title actually being in the
--       member's saved `articles_read` tool_data list.
--    3. Caps `tool_first_use`, `article_read`, and `session_booked` per
--       season/quarter so no event type can be farmed without bound
--       (tool_first_use fires on tool OPEN, before any row exists, so it
--       cannot be evidence-gated — a cap is the safe bound).
--  The amount is still read from points_catalog (never client-supplied),
--  and direct INSERTs into points_events remain blocked by RLS.
--
--  NOTE (badges forgery — separate follow-up, NOT applied here): the
--  `badges` table is directly client-writable and the leaderboard counts
--  public badges straight from that array, so badge_count is forgeable.
--  Fixing that safely needs a coordinated change (a SECURITY DEFINER
--  award-badge RPC + revoking direct write on badges + updating
--  kw-badges.js to call the RPC), which must not be half-applied or it
--  breaks saveBadges(). Tracked in AUDIT-REPORT.md P0-7; do that as its
--  own reviewed change.
-- ════════════════════════════════════════════════════════════════════

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
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select points, active into v_points, v_active
  from points_catalog where event_type = p_event_type;

  if v_points is null or not coalesce(v_active, false) then
    raise exception 'unknown or inactive event type: %', p_event_type;
  end if;

  -- ── Server-normalised ref_id for time-keyed events ─────────────
  if p_event_type in ('monthly_checkin', 'assessment_complete') then
    v_ref := to_char(now(), 'YYYY-MM');
  elsif p_event_type in ('improvement', 'checkin_streak_3') then
    v_ref := to_char(now(), 'YYYY"-Q"Q');
  elsif p_event_type = 'onboarding_complete' then
    v_ref := 'once';
  else
    -- Content events (article_read, video_watched, tool_first_use, session_booked):
    -- client ref_id accepted, length-capped, must be non-empty.
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

  elsif p_event_type = 'onboarding_complete' then
    v_ok := exists (select 1 from profiles where id = v_uid);

  elsif p_event_type = 'improvement' then
    -- Compare the two most recent assessments' cat_scores dimension-by-dimension.
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

  -- ── NEW: video_watched must have a real content_progress row ───
  -- complete_video() inserts content_progress BEFORE calling award_points,
  -- so the legitimate path passes; a direct console call with a fabricated
  -- content id has no matching row and earns nothing.
  elsif p_event_type = 'video_watched' then
    v_ok := exists (
      select 1 from content_progress
      where user_id = v_uid and content_id::text = p_ref_id
    );

  -- ── NEW: article_read must be in the member's saved read-list ──
  -- index.html writes the title into tool_data('articles_read').read BEFORE
  -- awarding, so the legitimate path passes.
  elsif p_event_type = 'article_read' then
    v_ok := exists (
      select 1 from tool_data
      where user_id = v_uid
        and tool = 'articles_read'
        and coalesce(data->'read', '[]'::jsonb) ? p_ref_id
    );

  else
    -- tool_first_use: fires on tool OPEN (before any row exists), so it has
    -- no reliable backing evidence. Left as an engagement signal, but bounded
    -- by the per-season cap below.
    v_ok := true;
  end if;

  -- ── NEW: per-period volume caps ────────────────────────────────
  -- Bound events that can't be strongly evidence-gated so no single event
  -- type can be farmed without limit even if a client fabricates ref_ids.
  if v_ok then
    v_cap := case p_event_type
               when 'tool_first_use' then 20   -- ~15 tools; generous headroom
               when 'article_read'   then 50   -- defense-in-depth atop evidence
               when 'session_booked' then 8    -- per quarter
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
