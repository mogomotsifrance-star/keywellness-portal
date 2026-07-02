-- ============================================================
-- Key Wellness — Leaderboard & Rewards RPCs (Batch 4)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE OR REPLACE).
--
-- Purely additive: three new functions. Nothing existing is altered.
-- Requires Batch 1 (points ledger) and Batch 3 (leaderboard_opt_in /
-- display_alias) to already be applied.
--
-- Column discipline: none of these functions select any assessment, checkin,
-- or financial column, and none return names/emails except org_rewards()
-- (HR-only, first/last name — the whole point of that function).
-- ============================================================


-- ── 1. org_leaderboard(p_season) — member-facing ───────────────
-- Returns top-50 opted-in members of the caller's org for a season (default
-- current quarter), plus the caller's own row if they're opted in but outside
-- the top 50. Never selects assessment/checkin/financial columns, never
-- returns a name or email — alias only.

create or replace function public.org_leaderboard(p_season text default null)
returns table (
  alias         text,
  season_points bigint,
  badge_count   int,
  rank          bigint,
  is_self       boolean
)
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_season text;
  -- Kept in sync with kw-badges.js's `public: true` badges — see BUILD-NOTES.md.
  v_public_badges text[] := array[
    'first_login','first_assessment','booked_session','ef_t1',
    'checkin_streak_t1','checkin_streak_t2','checkin_streak_t3',
    'learning_t1','learning_t2','learning_t3',
    'budget_year_t1','budget_year_t2','budget_year_t3','budget_year_t4',
    'budget_year_t5','budget_year_t6','budget_year_t7','budget_year_t8',
    'budget_year_t9','budget_year_t10','budget_year_t11','budget_year_t12'
  ];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select org_id into v_org from profiles where id = v_uid;
  if v_org is null then
    return; -- not in an org: empty result, not an error
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select pe.user_id, coalesce(sum(pe.points), 0) as season_points
    from points_events pe
    join profiles p on p.id = pe.user_id
    where p.org_id = v_org and pe.season = v_season
    group by pe.user_id
  ),
  badge_counts as (
    select b.user_id, count(*) as badge_count
    from badges b
    cross join lateral unnest(b.earned_badge_ids) as bid(id)
    where bid.id = any(v_public_badges)
    group by b.user_id
  ),
  ranked as (
    select
      p.id as user_id,
      coalesce(op.season_points, 0) as season_points,
      coalesce(nullif(trim(p.display_alias), ''), 'Member') as alias,
      coalesce(bc.badge_count, 0) as badge_count,
      rank() over (order by coalesce(op.season_points, 0) desc) as rnk
    from profiles p
    left join org_points   op on op.user_id = p.id
    left join badge_counts bc on bc.user_id = p.id
    where p.org_id = v_org and p.leaderboard_opt_in = true
  )
  select r.alias, r.season_points, r.badge_count, r.rnk as rank, (r.user_id = v_uid) as is_self
  from ranked r
  where r.rnk <= 50 or r.user_id = v_uid
  order by r.rnk asc;
end;
$$;

grant execute on function public.org_leaderboard(text) to authenticated;


-- ── 2. org_leaderboard_self_rank(p_season) — private rank ──────
-- "You're #7 of 43" for members who are NOT opted in (or opted-in members who
-- want their true org-wide rank). Includes every org member regardless of
-- opt-in status for the ranking itself, but returns only the CALLER's row —
-- never anyone else's — so this cannot be used to infer another member's rank.

create or replace function public.org_leaderboard_self_rank(p_season text default null)
returns table (
  my_rank       bigint,
  total_members bigint,
  season_points bigint,
  opted_in      boolean
)
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_season text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select org_id into v_org from profiles where id = v_uid;
  if v_org is null then
    return;
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select p.id as user_id,
           coalesce(sum(pe.points) filter (where pe.season = v_season), 0) as season_points
    from profiles p
    left join points_events pe on pe.user_id = p.id
    where p.org_id = v_org
    group by p.id
  ),
  ranked as (
    select user_id, season_points,
           rank() over (order by season_points desc) as rnk,
           count(*) over () as total
    from org_points
  )
  select r.rnk, r.total, r.season_points,
         (select leaderboard_opt_in from profiles where id = v_uid)
  from ranked r
  where r.user_id = v_uid;
end;
$$;

grant execute on function public.org_leaderboard_self_rank(text) to authenticated;


-- ── 3. org_rewards(target_org, p_season) — HR-facing ────────────
-- Mirrors org_overview()'s exact employer/admin auth gate. Returns opted-in
-- members of the employer's org ONLY: first_name, last_name, season_points,
-- rank. No badges, no aliases, no activity, no assessment linkage — this
-- exists solely so HR can hand out prizes to opted-in members.

create or replace function public.org_rewards(target_org uuid default null, p_season text default null)
returns table (
  first_name    text,
  last_name     text,
  season_points bigint,
  rank          bigint
)
language plpgsql security definer set search_path = public as $$
declare
  v_season text;
begin
  if target_org is null then
    target_org := employer_org();
  end if;

  if target_org is null then
    raise exception 'not authorised';
  end if;

  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select p.id as user_id, coalesce(sum(pe.points), 0) as season_points
    from profiles p
    left join points_events pe on pe.user_id = p.id and pe.season = v_season
    where p.org_id = target_org and p.leaderboard_opt_in = true
    group by p.id
  )
  select p.first_name, p.last_name, op.season_points,
         rank() over (order by op.season_points desc) as rank
  from org_points op
  join profiles p on p.id = op.user_id
  order by rank asc;
end;
$$;

grant execute on function public.org_rewards(uuid, text) to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as real users via the browser console (window._toolSb.rpc(...)),
-- NOT in the SQL Editor — the SQL Editor runs as postgres and bypasses both
-- RLS and the security-definer functions' own auth.uid()/employer_org() checks.

-- 1. Cross-org isolation + no-org empty result:
--    As a member of Org A: await window._toolSb.rpc('org_leaderboard');
--    Expect: only Org A opted-in members. As a user with org_id = null:
--    expect an empty array, not an error.

-- 2. Non-opted-in privacy:
--    As a non-opted-in member: confirm you do NOT appear in another member's
--    org_leaderboard() result, but org_leaderboard_self_rank() still returns
--    your own {my_rank, total_members, season_points, opted_in:false}.

-- 3. badge_count never counts private badges:
--    Seed a test user with 'debt_destroyer_t1' (private) and 'first_login'
--    (public) earned, opt them in, and confirm org_leaderboard()'s
--    badge_count for that row is 1, not 2.

-- 4. Employer gate:
--    As a non-employer member: await window._toolSb.rpc('org_rewards');
--    Expect: an error ("not authorised"). As the org's employer: expect the
--    opted-in members list.

-- 5. Legacy points excluded from season sums — same check as Batch 1's
--    verification query 4, but confirmed here via org_leaderboard's
--    season_points column instead of my_points.
-- ─────────────────────────────────────────────────────────────
