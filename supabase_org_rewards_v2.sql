-- ============================================================
-- Key Wellness — Org Webinars & Quarterly Thresholds: Batch 5b
-- org_rewards() qualification switch (HR-facing).
-- Run in the Supabase SQL Editor AFTER supabase_utilisation_rpcs.sql.
-- Run once; safe to re-run (CREATE OR REPLACE — return shape unchanged).
--
-- WARNING: production-live on apply. Rollback: re-run the org_rewards()
-- definition in supabase_rewards_reshape.sql §2 (recorded in
-- migrations/rollback-webinars-thresholds.sql SECTION C).
--
-- WHAT CHANGES vs supabase_rewards_reshape.sql §2 — ONLY the two
-- qualification flags:
--   qualified_learning    → learning_qualified(user, season): watched ⅓ of
--                           the live library this quarter (supersedes the
--                           returning-member 150-point rule and the
--                           first-season 500-point rule).
--   qualified_utilisation → utilisation_qualified(user, season): all four
--                           pillars (budgets / fortnightly check-ins /
--                           attended session / EF + one other tool).
--   qualified_progress    → UNCHANGED, byte-identical points-threshold
--                           expression against reward_thresholds.progress.
-- Everything else (auth gate, opt-in filter, column list, category sums,
-- rank, tie-break, fulfilments) is byte-carried from the prior definition.
-- This file deliberately contains no reference to the private event type
-- excluded from category sums — see the prior file for that rationale.
-- ============================================================

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
    -- NEW: criteria-based qualification (owner-only helpers; per-member
    -- boolean flags only — no counts, positions, or per-pillar detail
    -- reach this HR-facing output).
    (utilisation_qualified(mb.user_id, v_season) ->> 'qualified')::boolean as qualified_utilisation,
    (learning_qualified(mb.user_id, v_season)    ->> 'qualified')::boolean as qualified_learning,
    -- UNCHANGED: Progress keeps the tenure-aware points threshold.
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


-- ── VERIFICATION CHECKLIST ───────────────────────────────────────
-- 1. Return shape identical to before (same 14 columns, same order) —
--    employer.html's Rewards tab renders without change.
-- 2. qualified_learning flips when a member crosses ⅓ of the library in
--    credited videos this quarter — NOT at any points value. A member with
--    600 learning points from articles alone shows qualified_learning=false.
-- 3. qualified_utilisation matches utilisation_qualified() fixtures
--    (see supabase_utilisation_rpcs.sql checklist).
-- 4. qualified_progress: unchanged behaviour — verify a member just
--    above/below the progress threshold flips exactly as before the run.
-- 5. Privacy: output contains only the same per-member fields as before
--    (booleans, category point sums) — no counts of budgets/check-ins/
--    videos, no window detail, no forbidden strings:
--      grep -ci <forbidden-term> supabase_org_rewards_v2.sql   → 0
-- 6. Auth gate regression: non-employer member calling org_rewards() gets
--    'not authorised'; employer of org A cannot pass org B's uuid.
-- ─────────────────────────────────────────────────────────────────
