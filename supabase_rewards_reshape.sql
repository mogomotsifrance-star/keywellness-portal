-- ============================================================
-- Key Wellness — org_rewards() Category Reshape + org_rewards_summary()
-- (Rewards-reshape Batch 4)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE TABLE IF NOT EXISTS, CREATE OR
-- REPLACE FUNCTION).
--
-- SAVE THE CURRENT org_rewards() DEFINITION (from supabase_leaderboard.sql
-- §3, also copied into migrations/rollback-notes.md) BEFORE running this —
-- it is being replaced with a different return shape, not just extended.
--
-- Dependency-ordering note (see BUILD-NOTES.md): org_rewards()'s
-- rewarded_categories column and org_rewards_summary()'s reported_headcount
-- field both need to read tables that ship their write-RPCs in later
-- batches (reward_fulfilments in Batch 5, org_headcount_reports in
-- Batch 7). Both tables are created here, idempotently (IF NOT EXISTS),
-- with RLS enabled and NO policies — nothing can read or write them
-- directly yet; Batch 5/7 re-declare them (no-op) alongside the RPCs
-- that are actually allowed to touch them.
-- ============================================================


-- ── 1. Pre-created tables (see dependency-ordering note above) ─

create table if not exists public.reward_fulfilments (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id),
  season text not null,
  category text not null check (category in ('utilisation','learning','progress','overall')),
  note text check (char_length(note) <= 200),
  fulfilled_by uuid not null,
  created_at timestamptz not null default now(),
  unique (org_id, user_id, season, category)
);

alter table public.reward_fulfilments enable row level security;
-- No policies for authenticated. Reads/writes arrive only via
-- record_reward_fulfilment()/org_reward_history() (Batch 5).

create table if not exists public.org_headcount_reports (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id),
  headcount int not null check (headcount > 0 and headcount < 1000000),
  reported_by uuid not null,
  created_at timestamptz not null default now()
);

alter table public.org_headcount_reports enable row level security;
-- No policies for authenticated. Reads arrive via org_rewards_summary
-- (below); writes only via set_org_headcount() (Batch 7).


-- ── 2. org_rewards() — reshaped for categories/qualification/tie-break ─
-- Mirrors org_overview()'s exact employer/admin auth gate. For opted-in
-- members of the employer's org ONLY. Category sums EXCLUDE 'private'
-- events (e.g. improvement) — overall_points INCLUDES them (a single
-- blended number is not decomposable; the word "improvement" and any
-- per-person improvement value never appear in this output).
--
-- The prior org_rewards(uuid,text) returned a different set of OUT columns
-- (first_name, last_name, season_points, rank) — Postgres refuses to
-- CREATE OR REPLACE a table-returning function when its column list
-- changes ("cannot change return type of existing function"), so the old
-- version must be dropped first. Its definition is already saved in
-- migrations/rollback-notes.md if this ever needs to be undone.

drop function if exists public.org_rewards(uuid, text);

create or replace function public.org_rewards(target_org uuid default null, p_season text default null)
returns table (
  -- user_id is not in the original spec's column list, but the Reward
  -- button (Batch 6 UI) needs a stable identifier to pass to
  -- record_reward_fulfilment(p_user_id, ...) — email alone isn't a
  -- usable RPC argument. Adding it discloses nothing HR doesn't already
  -- see via name+email for the same (opted-in) row.
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
  with member_base as (
    -- auth.users.email is character varying(255); the RETURNS TABLE declares
    -- email as text, and Postgres requires an exact type match for table-
    -- returning functions ("structure of query does not match function
    -- result type") — cast explicitly rather than relying on an implicit cast.
    select p.id as user_id, p.first_name, p.last_name, u.email::text as email, u.created_at as joined_at
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = target_org and p.leaderboard_opt_in = true
  ),
  cat_points as (
    select
      mb.user_id,
      coalesce(sum(pe.points) filter (where pc.category = 'utilisation'), 0) as utilisation_points,
      coalesce(sum(pe.points) filter (where pc.category = 'learning'),    0) as learning_points,
      coalesce(sum(pe.points) filter (where pc.category = 'progress'),    0) as progress_points,
      -- Overall INCLUDES 'private' category points (e.g. improvement) — the
      -- one place a blended figure is acceptable. No category filter here.
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
    -- Every column here must be qualified with the rf. alias: org_rewards()'s
    -- RETURNS TABLE declares an OUT parameter also named user_id, so an
    -- unqualified `user_id` (or the other OUT-param-shaped names) inside the
    -- function body is ambiguous between the table column and the plpgsql
    -- variable — Postgres raises "column reference ... is ambiguous".
    select rf.user_id, array_agg(rf.category order by rf.category) as rewarded_categories
    from reward_fulfilments rf
    where rf.org_id = target_org and rf.season = v_season
    group by rf.user_id
  )
  select
    mb.user_id, mb.first_name, mb.last_name, mb.email,
    cp.utilisation_points, cp.learning_points, cp.progress_points, cp.overall_points,
    -- Tenure rule (identical to index.html's isFirstSeasonMember() and
    -- reward_thresholds' own definition — see BUILD-NOTES.md): first season
    -- = the calendar quarter containing account creation.
    (cp.utilisation_points >= case when to_char(mb.joined_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')
                                    then tu.first_season_points else tu.returning_points end) as qualified_utilisation,
    (cp.learning_points    >= case when to_char(mb.joined_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')
                                    then tl.first_season_points else tl.returning_points end) as qualified_learning,
    (cp.progress_points    >= case when to_char(mb.joined_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')
                                    then tp.first_season_points else tp.returning_points end) as qualified_progress,
    -- rank() with a fully-resolved tie-break (reached_total_at, then user_id)
    -- degenerates to a total order — every row gets a distinct rank.
    rank() over (
      order by cp.overall_points desc, cp.reached_total_at asc nulls last, mb.user_id asc
    ) as overall_rank,
    cp.reached_total_at,
    coalesce(f.rewarded_categories, array[]::text[]) as rewarded_categories
  from member_base mb
  join cat_points cp on cp.user_id = mb.user_id
  left join reward_thresholds tu on tu.category = 'utilisation'
  left join reward_thresholds tl on tl.category = 'learning'
  left join reward_thresholds tp on tp.category = 'progress'
  left join fulfilled f on f.user_id = mb.user_id
  order by overall_rank asc;
end;
$$;

grant execute on function public.org_rewards(uuid, text) to authenticated;


-- ── 3. org_rewards_summary() — header stats for the Rewards tab ────

create or replace function public.org_rewards_summary(target_org uuid default null, p_season text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_season           text;
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

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  select count(*) into v_org_member_count from profiles where org_id = target_org;
  select count(*) into v_opted_in_count
  from profiles where org_id = target_org and leaderboard_opt_in = true;

  select count(distinct pe.user_id) into v_active_count
  from points_events pe
  join profiles p on p.id = pe.user_id
  where p.org_id = target_org and pe.season = v_season and pe.season <> 'legacy';

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

  -- reported_headcount is self-reported/unverified — display denominator
  -- ONLY. Never feeds cohort guards or suppression logic anywhere else.
  select headcount, created_at into v_headcount, v_headcount_at
  from org_headcount_reports
  where org_id = target_org
  order by created_at desc
  limit 1;

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


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as real users via the browser console — while on employer.html
-- (HR/employer login), where the page's own top-level `const sb` is in scope
-- (type `sb.rpc(...)` directly; sb is NOT on window, and window._toolSb does
-- NOT exist on this page — that global only exists on the standalone tool
-- pages via kw-profile-sync.js),
-- NOT the SQL Editor — the SQL Editor runs as postgres and bypasses both
-- RLS and org_rewards()'s own auth.uid()/employer_org() checks.

-- 1. Improvement isolation — seed a test member with an 'improvement' event
--    (award_points('improvement', ...)), opt them in, then as their employer:
--      const { data } = await sb.rpc('org_rewards');
--      JSON.stringify(data).includes('improvement')  // expect false
--    Confirm their overall_points rose but utilisation/learning/progress_points
--    did not change from the improvement event.

-- 2. Qualification flags — seed a first-season member and a returning member
--    with identical utilisation_points just below/above the threshold; confirm
--    qualified_utilisation flips at the threshold and differs between the two
--    members if their tenure differs (first-season vs returning thresholds).

-- 3. Tie-break — seed two members with identical overall_points but different
--    reached_total_at; confirm the earlier reached_total_at ranks higher.

-- 4. Auth gate — as a non-employer member:
--      await sb.rpc('org_rewards');   // expect "not authorised"
--    As the org's employer: expect the opted-in members list.

-- 5. Legacy exclusion — a member with only 'legacy' season points shows
--    utilisation/learning/progress/overall_points all 0 (unless they also
--    have real current-season events).

-- 6. org_rewards_summary() sanity — as the org's employer:
--      await sb.rpc('org_rewards_summary');
--    Expect org_member_count/opted_in_count/active_this_season_count to
--    match manual counts, season_end_date = last day of the current
--    quarter, days_remaining >= 0, reported_headcount null until Batch 7's
--    set_org_headcount() has been called at least once for this org.
-- ─────────────────────────────────────────────────────────────
