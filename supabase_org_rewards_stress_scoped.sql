-- ============================================================
-- Key Wellness — Company Units, Batch 3c: unit-scope stress + rewards
-- Run in the Supabase SQL Editor AFTER supabase_org_units_hr_scope.sql.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Scopes the remaining HR-facing member surfaces to the caller's unit,
-- using the same per-caller filter (hr_scoped_unit_ids()) as Batch 3b.
-- v_scope NULL = whole org (fund manager / legacy employer / admin) =>
-- byte-identical to the pre-existing behaviour. The ≥5 / <3 guards now
-- apply per unit view.
--
-- Bases (confirmed live):
--   • org_stress_summary(int)         — supabase_org_stress_summary.sql
--   • org_rewards(uuid,text)          — supabase_org_rewards_v2.sql
--   • org_rewards_summary(uuid,text)  — supabase_rewards_reshape.sql §2
--
-- Rollback: re-apply those three base files (see
-- migrations/rollback-org-rewards-stress-scoped.sql).
--
-- STILL org-wide (deliberately out of scope here; see BUILD-NOTES.md):
--   org_reward_history, record_reward_fulfilment, set_org_headcount.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- org_stress_summary() — aggregate stress bands + causes, unit-scoped
-- ══════════════════════════════════════════════════════════════
create or replace function public.org_stress_summary(p_window_days int default 90)
returns json
language plpgsql security definer set search_path = public as $$
declare
  target_org      uuid;
  v_scope         uuid[];
  v_cohort_n      int;
  v_low_n         bigint;
  v_moderate_n    bigint;
  v_high_n        bigint;
  v_bands         json;
  v_causes        json;
begin
  target_org := employer_org();
  if target_org is null then
    raise exception 'not authorised';
  end if;

  v_scope := hr_scoped_unit_ids();

  with latest as (
    select m.id as user_id, c.level
    from (
      select p.id from profiles p
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
    ) m
    cross join lateral (
      select sl.level
      from stress_logs sl
      where sl.user_id = m.id
        and sl.created_at >= now() - (p_window_days || ' days')::interval
      order by sl.created_at desc
      limit 1
    ) c
  )
  select
    count(*),
    count(*) filter (where level >= 7),
    count(*) filter (where level between 4 and 6),
    count(*) filter (where level <= 3)
  into v_cohort_n, v_low_n, v_moderate_n, v_high_n
  from latest;

  if v_cohort_n < 5 then
    return json_build_object('insufficient_cohort', true);
  end if;

  v_bands := json_build_object(
    'low',      json_build_object('count', _suppress_count(v_low_n),      'pct', _suppress_rate(v_low_n::int, v_cohort_n)),
    'moderate', json_build_object('count', _suppress_count(v_moderate_n), 'pct', _suppress_rate(v_moderate_n::int, v_cohort_n)),
    'high',     json_build_object('count', _suppress_count(v_high_n),     'pct', _suppress_rate(v_high_n::int, v_cohort_n))
  );

  with latest as (
    select m.id as user_id, c.tags
    from (
      select p.id from profiles p
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
    ) m
    cross join lateral (
      select sl.tags
      from stress_logs sl
      where sl.user_id = m.id
        and sl.created_at >= now() - (p_window_days || ' days')::interval
      order by sl.created_at desc
      limit 1
    ) c
  ),
  cause_counts as (
    select tag as cause, count(distinct user_id) as cnt
    from latest, unnest(tags) as tag
    group by tag
    having count(distinct user_id) >= 3
    order by count(distinct user_id) desc
    limit 3
  )
  select coalesce(json_agg(
    json_build_object(
      'cause',        cause,
      'member_count', _suppress_count(cnt),
      'pct',          _suppress_rate(cnt::int, v_cohort_n)
    ) order by cnt desc
  ), '[]'::json)
  into v_causes
  from cause_counts;

  return json_build_object(
    'insufficient_cohort', false,
    'cohort_size',         v_cohort_n,
    'window_days',         p_window_days,
    'bands',               v_bands,
    'top_causes',          v_causes
  );
end;
$$;

grant execute on function public.org_stress_summary(int) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- org_rewards() — opt-in rewards leaderboard (named), unit-scoped
-- Only the member_base cohort changes; everything downstream derives
-- from it (fulfilments join on scoped member ids, so no leak).
-- ══════════════════════════════════════════════════════════════
create or replace function public.org_rewards(target_org uuid default null, p_season text default null)
returns table (
  user_id                uuid,
  first_name             text,
  last_name              text,
  email                  text,
  utilisation_points     bigint,
  learning_points        bigint,
  progress_points        bigint,
  overall_points         bigint,
  qualified_utilisation  boolean,
  qualified_learning     boolean,
  qualified_progress     boolean,
  overall_rank           bigint,
  reached_total_at       timestamptz,
  rewarded_categories    text[]
)
language plpgsql security definer set search_path = public as $$
declare
  v_season text;
  v_scope  uuid[];
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

  v_scope := hr_scoped_unit_ids();
  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with member_base as (
    select p.id as user_id, p.first_name, p.last_name, u.email::text as email, u.created_at as joined_at
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = target_org
      and p.leaderboard_opt_in = true
      and (v_scope is null or p.org_unit_id = any(v_scope))
  ),
  cat_points as (
    select
      mb.user_id,
      coalesce(sum(pe.points) filter (where pc.category = 'utilisation'), 0) as utilisation_points,
      coalesce(sum(pe.points) filter (where pc.category = 'learning'),    0) as learning_points,
      coalesce(sum(pe.points) filter (where pc.category = 'progress'),    0) as progress_points,
      coalesce(sum(pe.points), 0) as overall_points,
      max(pe.created_at) as reached_total_at
    from member_base mb
    left join points_events pe
      on pe.user_id = mb.user_id
      and pe.season = v_season
      and pe.season <> 'legacy'
    left join points_catalog pc on pc.event_type = pe.event_type
    group by mb.user_id
  ),
  fulfilled as (
    select rf.user_id, array_agg(rf.category order by rf.category) as rewarded_categories
    from reward_fulfilments rf
    where rf.org_id = target_org and rf.season = v_season
    group by rf.user_id
  )
  select
    mb.user_id, mb.first_name, mb.last_name, mb.email,
    cp.utilisation_points, cp.learning_points, cp.progress_points, cp.overall_points,
    (utilisation_qualified(mb.user_id, v_season) ->> 'qualified')::boolean as qualified_utilisation,
    (learning_qualified(mb.user_id, v_season)    ->> 'qualified')::boolean as qualified_learning,
    (cp.progress_points    >= case when to_char(mb.joined_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')
                                    then tp.first_season_points else tp.returning_points end) as qualified_progress,
    rank() over (
      order by cp.overall_points desc, cp.reached_total_at asc nulls last, mb.user_id asc
    ) as overall_rank,
    cp.reached_total_at,
    coalesce(f.rewarded_categories, array[]::text[]) as rewarded_categories
  from member_base mb
  join cat_points cp on cp.user_id = mb.user_id
  left join reward_thresholds tp on tp.category = 'progress'
  left join fulfilled f on f.user_id = mb.user_id
  order by overall_rank asc;
end;
$$;

grant execute on function public.org_rewards(uuid, text) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- org_rewards_summary() — rewards tab counts, unit-scoped
-- reported_headcount is an ORG-level self-reported figure with no unit
-- attribution, so it is withheld (null) in a unit-scoped view.
-- ══════════════════════════════════════════════════════════════
create or replace function public.org_rewards_summary(target_org uuid default null, p_season text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_season           text;
  v_scope            uuid[];
  v_org_member_count int;
  v_opted_in_count   int;
  v_active_count     int;
  v_year             int;
  v_qtr              int;
  v_season_start     date;
  v_season_end       date;
  v_days_remaining   int;
  v_headcount        int;
  v_headcount_at     timestamptz;
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

  v_scope := hr_scoped_unit_ids();
  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  select count(*) into v_org_member_count
  from profiles
  where org_id = target_org
    and (v_scope is null or org_unit_id = any(v_scope));

  select count(*) into v_opted_in_count
  from profiles
  where org_id = target_org and leaderboard_opt_in = true
    and (v_scope is null or org_unit_id = any(v_scope));

  select count(distinct pe.user_id) into v_active_count
  from points_events pe
  join profiles p on p.id = pe.user_id
  where p.org_id = target_org and pe.season = v_season and pe.season <> 'legacy'
    and (v_scope is null or p.org_unit_id = any(v_scope));

  if v_season ~ '^[0-9]{4}-Q[1-4]$' then
    v_year         := split_part(v_season, '-Q', 1)::int;
    v_qtr          := split_part(v_season, '-Q', 2)::int;
    v_season_start := make_date(v_year, (v_qtr - 1) * 3 + 1, 1);
    v_season_end   := (v_season_start + interval '3 months' - interval '1 day')::date;
    v_days_remaining := greatest(0, (v_season_end - current_date));
  else
    v_season_end := null;
    v_days_remaining := null;
  end if;

  -- Org-level self-reported headcount: not unit-attributable, so withheld
  -- for a unit-scoped caller (whole-org callers see it as before).
  if v_scope is null then
    select headcount, created_at into v_headcount, v_headcount_at
    from org_headcount_reports
    where org_id = target_org
    order by created_at desc
    limit 1;
  else
    v_headcount := null;
    v_headcount_at := null;
  end if;

  return json_build_object(
    'org_member_count',              v_org_member_count,
    'opted_in_count',                v_opted_in_count,
    'active_this_season_count',      v_active_count,
    'season_key',                    v_season,
    'season_end_date',               v_season_end,
    'days_remaining',                v_days_remaining,
    'reported_headcount',            v_headcount,
    'reported_headcount_updated_at', v_headcount_at
  );
end;
$$;

grant execute on function public.org_rewards_summary(uuid, text) to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- 1. Legacy no-op: as an existing whole-org employer, org_stress_summary /
--    org_rewards / org_rewards_summary return the SAME payloads as before.
-- 2. Scoped manager: seed hr_unit_scope for a test HR account scoped to a
--    unit; each RPC reflects only that unit's members (stress cohort,
--    rewards leaderboard, and summary counts all narrow; reported_headcount
--    becomes null in the summary).
-- 3. <5 unit: org_stress_summary returns { insufficient_cohort:true }.
-- 4. Confirm the three functions are now scoped:
--    select proname,
--      pg_get_functiondef(oid) like '%hr_scoped_unit_ids%' as scoped
--    from pg_proc
--    where proname in ('org_stress_summary','org_rewards','org_rewards_summary');
--    -- all three -> scoped = true
-- ============================================================
