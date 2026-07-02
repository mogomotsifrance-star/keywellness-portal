-- ============================================================
-- Key Wellness — Server-side Points Ledger (Batch 1 of the
-- points/rewards + leaderboard + HR financial indicators build)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (all statements use IF NOT EXISTS / OR REPLACE
-- / ON CONFLICT DO NOTHING).
--
-- Purely additive: two new tables, one new view, one new function.
-- Nothing existing is altered or dropped. Rollback statements are in
-- migrations/rollback-notes.md.
-- ============================================================


-- ── 1. Points catalog — authoritative point values ────────────
-- The client never supplies a points number; every award reads from here.

create table if not exists public.points_catalog (
  event_type text primary key,
  points     int not null check (points >= 0),
  active     boolean not null default true
);

insert into public.points_catalog (event_type, points) values
  ('onboarding_complete', 50),
  ('assessment_complete', 100),
  ('improvement',         150),
  ('monthly_checkin',     75),
  ('tool_first_use',      25),
  ('session_booked',      100),
  ('article_read',        15),
  ('video_watched',       25),
  ('quiz_passed',         50),
  ('checkin_streak_3',    150)
on conflict (event_type) do nothing;


-- ── 2. Immutable event ledger ──────────────────────────────────
-- unique(user_id, event_type, ref_id) is both the idempotency guard and the
-- recurrence enforcement (ref_id is normalised server-side inside award_points
-- for time-keyed events — see below — so the client cannot fake a fresh period).

create table if not exists public.points_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  event_type text not null references public.points_catalog(event_type),
  ref_id     text not null,
  points     int not null,
  season     text not null,
  created_at timestamptz not null default now(),
  unique (user_id, event_type, ref_id)
);

create index if not exists points_events_user_idx on public.points_events(user_id);


-- ── 3. RLS ──────────────────────────────────────────────────────

alter table public.points_catalog enable row level security;

drop policy if exists catalog_readable on public.points_catalog;
create policy catalog_readable on public.points_catalog
  for select to authenticated using (true);

alter table public.points_events enable row level security;

drop policy if exists own_events_readable on public.points_events;
create policy own_events_readable on public.points_events
  for select to authenticated
  using (user_id = auth.uid());

-- Deliberately NO insert/update/delete policy for authenticated. Writes happen
-- ONLY inside award_points() below (security definer). A direct client
-- `insert into points_events(...)` must fail with an RLS error — see
-- verification query 1.


-- ── 4. Awarding RPC ─────────────────────────────────────────────
-- Security definer so it can write past RLS; validates evidence itself so a
-- caller can never award points for something that didn't happen.

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
  -- The client's ref_id is IGNORED for these — the server decides the period,
  -- so a client cannot claim an earlier/later period than "now".
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
    -- Awards if ANY dimension rose by >=5 points. We deliberately do NOT record
    -- which dimension improved anywhere — the event is generic on purpose.
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

  else
    -- article_read / video_watched / tool_first_use: no server-checkable
    -- evidence exists for these (they are content-engagement signals with no
    -- backing row). Bounded by the unique constraint (once per ref_id) and the
    -- point caps in the catalog. Documented as an accepted gap in BUILD-NOTES.md.
    v_ok := true;
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


-- ── 5. Totals view ──────────────────────────────────────────────
-- security_invoker so RLS is evaluated as the CALLING user, not the view
-- owner — without this a view over an RLS-protected table can leak all rows.

create or replace view public.my_points
with (security_invoker = true) as
  select user_id,
         coalesce(sum(points), 0) as total_points,
         coalesce(sum(points) filter (where season = to_char(now(), 'YYYY"-Q"Q')), 0) as season_points
  from public.points_events
  group by user_id;

grant select on public.my_points to authenticated;


-- ── 6. Legacy carry-over ────────────────────────────────────────
-- One-time backfill so existing client-accumulated points aren't lost, but are
-- kept out of season totals (season='legacy') so the first real leaderboard
-- season starts fair for everyone.

insert into public.points_catalog (event_type, points) values ('legacy_migration', 0)
on conflict (event_type) do nothing;

insert into public.points_events (user_id, event_type, ref_id, points, season)
select user_id, 'legacy_migration', 'v1-carryover', coalesce(points, 0), 'legacy'
from public.badges
where coalesce(points, 0) > 0
on conflict do nothing;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these after applying, in order, and confirm the expected result before
-- any frontend work proceeds.

-- 1. Direct client insert must fail with an RLS error (no insert policy exists).
--    Run from the BROWSER CONSOLE on the dev site while logged in (anon key,
--    real session) — NOT in the SQL Editor, which runs as postgres and bypasses RLS:
--      await window._toolSb.from('points_events').insert({
--        user_id: (await window._toolSb.auth.getUser()).data.user.id,
--        event_type: 'monthly_checkin', ref_id: 'hack', points: 999999, season: '2099-Q1'
--      });
--    Expect: an error object, no row inserted.

-- 2. Idempotency regardless of client-supplied ref_id (run twice in the SQL
--    Editor as a real user via `set local role authenticated; set local
--    request.jwt.claim.sub = '<a real auth.users.id>';` or simpler: call via
--    the browser console as in (1) but with .rpc instead of .insert):
--      await window._toolSb.rpc('award_points', { p_event_type:'monthly_checkin', p_ref_id:'anything' });
--      await window._toolSb.rpc('award_points', { p_event_type:'monthly_checkin', p_ref_id:'something-else' });
--    Expect: first call {awarded:true,...}; second call {awarded:false,...} — the
--    server-normalised ref_id (YYYY-MM) makes both calls collide regardless of
--    what ref_id string was sent.

-- 3. Evidence gating — as a user with NO row in `assessments`:
--      await window._toolSb.rpc('award_points', { p_event_type:'assessment_complete', p_ref_id:'x' });
--    Expect: {awarded:false, points:0, total:...}. Complete a real assessment,
--    retry within the hour — expect {awarded:true, points:100, ...}.

-- 4. Legacy carry-over — for a user who had points > 0 in `badges` before this
--    migration ran:
--      select * from points_events where user_id = '<that user id>' and event_type = 'legacy_migration';
--      select * from my_points where user_id = '<that user id>';
--    Expect: total_points includes the legacy amount; season_points does NOT
--    (season = 'legacy', excluded from the current-quarter filter).

-- 5. Catalog is not writable by authenticated (run as the browser-console user):
--      await window._toolSb.from('points_catalog').update({ points: 99999 }).eq('event_type','monthly_checkin');
--    Expect: an error (no update policy exists), or 0 rows affected.
-- ─────────────────────────────────────────────────────────────
