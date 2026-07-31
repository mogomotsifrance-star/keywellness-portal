-- ============================================================
-- Key Wellness — Company Units, Batch 3b: unit-scoped HR dashboard
-- Run in the Supabase SQL Editor AFTER supabase_live_wellness.sql and
-- supabase_org_units_hr_scope.sql. Safe to re-run (CREATE OR REPLACE).
--
-- Base = supabase_live_wellness.sql (the confirmed-live org_overview /
-- org_financial_indicators). The ONLY change: each member cohort is
-- additionally filtered by the caller's resolved unit scope
-- (hr_scoped_unit_ids()). Scope is resolved from the CALLER's identity, so
-- employer.html needs NO changes — a company/Debswana manager who logs in
-- automatically sees only their scope; a fund manager, a legacy whole-org
-- employer, and admins all resolve to NULL scope => byte-identical output
-- to live_wellness.sql. The ≥5 / assessed<3 / <3-cell guards now apply per
-- unit view exactly as they did per org (locked decision 6).
--
-- Rollback: re-apply supabase_live_wellness.sql (drops the scope filter).
-- ============================================================


-- ── org_overview() — live-aware + unit-scoped ────────────────
create or replace function org_overview(target_org uuid default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  n              int;
  v_assessed_n   int;
  v_scope        uuid[];
  v_summary      json;
  v_funnel       json;
  v_distribution json;
  v_dimensions   json;
  v_focus_dim    text;
  v_distress     json;
  v_trend        json;
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

  -- Caller's unit scope (NULL = whole org: fund manager / legacy employer / admin).
  v_scope := hr_scoped_unit_ids();

  -- ── Cohort guard (now per-scope) ──────────────────────────
  select count(*) into n
  from profiles
  where org_id = target_org
    and (v_scope is null or org_unit_id = any(v_scope));

  if n < 5 then
    return json_build_object(
      'suppressed',   true,
      'n_employees',  n,
      'message',      'Aggregates appear once at least 5 employees have enrolled, to protect individual privacy.'
    );
  end if;

  select count(distinct a.user_id) into v_assessed_n
  from assessments a
  join profiles p on p.id = a.user_id
  where p.org_id = target_org
    and (v_scope is null or p.org_unit_id = any(v_scope));

  -- ── 1. Summary ────────────────────────────────────────────
  if v_assessed_n < 3 then
    v_summary := json_build_object(
      'n_employees',       n,
      'participation_pct', null,
      'avg_score',         null
    );
  else
    select json_build_object(
      'n_employees',       n,
      'participation_pct', round(100.0 * v_assessed_n::numeric / nullif(n, 0), 1),
      'avg_score',         round(avg(
        case when p.live_score is not null and p.live_score_at is not null
                  and p.live_score_at >= a.created_at
             then p.live_score else a.score end
      )::numeric, 1)
    ) into v_summary
    from profiles p
    left join lateral (
      select user_id, score, created_at
      from assessments
      where user_id = p.id
      order by created_at desc
      limit 1
    ) a on true
    where p.org_id = target_org
      and (v_scope is null or p.org_unit_id = any(v_scope));
  end if;

  -- ── 2. Funnel ─────────────────────────────────────────────
  with counts as (
    select
      (select count(distinct p2.id) from profiles p2
        where p2.org_id = target_org
          and (v_scope is null or p2.org_unit_id = any(v_scope))
          and exists (select 1 from assessments a2 where a2.user_id = p2.id)
      ) as assessed_cnt,
      (select count(distinct p3.id) from profiles p3
        where p3.org_id = target_org
          and (v_scope is null or p3.org_unit_id = any(v_scope))
          and exists (select 1 from checkins c where c.user_id = p3.id)
      ) as checkin_cnt
  )
  select json_build_object(
    'signed_up',            n,
    'completed_assessment', case when assessed_cnt < 3 then null else assessed_cnt end,
    'did_checkin',          case when checkin_cnt < 3 then null else checkin_cnt end,
    'tool_tracking_note',   'Tool-usage step omitted: calculators write to localStorage. Flag for a future tracking batch.'
  ) into v_funnel
  from counts;

  -- ── 3. Distribution ───────────────────────────────────────
  if v_assessed_n < 3 then
    v_distribution := json_build_object(
      'suppressed',     true,
      'assessed_count', v_assessed_n,
      'struggling',     null,
      'coping',         null,
      'thriving',       null
    );
  else
    with latest_scores as (
      select distinct on (p.id) p.id,
        case when p.live_score is not null and p.live_score_at is not null
                  and p.live_score_at >= a.created_at
             then p.live_score else a.score end as score
      from profiles p
      join assessments a on a.user_id = p.id
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
      order by p.id, a.created_at desc
    )
    select json_build_object(
      'suppressed', false,
      'assessed_count', count(*),
      'struggling', json_build_object(
        'label',   'Struggling (0–39)',
        'count',   count(*) filter (where score between 0  and 39),
        'pct',     round(100.0 * count(*) filter (where score between 0  and 39)::numeric / nullif(count(*),0), 1)
      ),
      'coping', json_build_object(
        'label',   'Coping (40–64)',
        'count',   count(*) filter (where score between 40 and 64),
        'pct',     round(100.0 * count(*) filter (where score between 40 and 64)::numeric / nullif(count(*),0), 1)
      ),
      'thriving', json_build_object(
        'label',   'Thriving (65–100)',
        'count',   count(*) filter (where score between 65 and 100),
        'pct',     round(100.0 * count(*) filter (where score between 65 and 100)::numeric / nullif(count(*),0), 1)
      )
    ) into v_distribution
    from latest_scores;
  end if;

  -- ── 4. Dimensions ─────────────────────────────────────────
  if v_assessed_n < 3 then
    v_dimensions := null;
    v_focus_dim := null;
  else
    with dim_avgs as (
      select
        dim.key                                    as dimension,
        round(avg(dim.value::text::numeric)::numeric, 1) as avg_score
      from profiles p
      cross join lateral (
        select cat_scores, created_at
        from assessments
        where user_id = p.id
        order by created_at desc
        limit 1
      ) latest
      cross join lateral jsonb_each(
        case when p.live_cat_scores is not null and p.live_score_at is not null
                  and p.live_score_at >= latest.created_at
             then p.live_cat_scores else latest.cat_scores end
      ) as dim(key, value)
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
        and dim.key <> '_insCount'
      group by dim.key
    )
    select
      json_agg(
        json_build_object('dimension', dimension, 'avg', avg_score)
        order by avg_score asc
      ),
      min(dimension) filter (where avg_score = (select min(avg_score) from dim_avgs))
    into v_dimensions, v_focus_dim
    from dim_avgs;
  end if;

  -- ── 5. Distress ───────────────────────────────────────────
  with latest_emergency as (
    select distinct on (p.id)
      p.id,
      (eff.cats->>'emergency')::numeric as emergency_score
    from profiles p
    join assessments a on a.user_id = p.id
    cross join lateral (
      select case when p.live_cat_scores is not null and p.live_score_at is not null
                       and p.live_score_at >= a.created_at
                  then p.live_cat_scores else a.cat_scores end as cats
    ) eff
    where p.org_id = target_org
      and (v_scope is null or p.org_unit_id = any(v_scope))
      and eff.cats ? 'emergency'
    order by p.id, a.created_at desc
  )
  select json_build_object(
    'suppressed',             (count(*) < 3),
    'pct_low_emergency_fund', case when count(*) < 3 then null else
      round(100.0 * count(*) filter (where emergency_score < 40)::numeric / nullif(count(*), 0), 1)
    end,
    'n_assessed',             count(*),
    'label',                  'Share of assessed employees with emergency-fund coverage under 1–2 months of expenses'
  ) into v_distress
  from latest_emergency;

  -- ── 6. Trend (historical assessments, unit-scoped cohort) ──
  with quarterly as (
    select
      date_trunc('quarter', a.created_at)  as period,
      round(avg(a.score)::numeric, 1)       as avg_score,
      count(distinct a.user_id)             as participants
    from assessments a
    where a.user_id in (
      select id from profiles
      where org_id = target_org
        and (v_scope is null or org_unit_id = any(v_scope))
    )
    group by date_trunc('quarter', a.created_at)
    order by period desc
    limit 6
  )
  select json_agg(
    json_build_object(
      'period',       to_char(period, 'YYYY "Q"Q'),
      'avg_score',    case when participants < 3 then null else avg_score end,
      'participants', case when participants < 3 then null else participants end,
      'suppressed',   (participants < 3)
    )
    order by period asc
  ) into v_trend
  from quarterly;

  return json_build_object(
    'suppressed',   false,
    'summary',      v_summary,
    'funnel',       v_funnel,
    'distribution', v_distribution,
    'dimensions',   case when v_assessed_n < 3 then json_build_object('suppressed', true, 'items', null, 'focus_dimension', null)
                         else json_build_object('suppressed', false, 'items', v_dimensions, 'focus_dimension', v_focus_dim)
                    end,
    'distress',     v_distress,
    'trend',        v_trend
  );

end;
$$;

grant execute on function public.org_overview(uuid) to authenticated;


-- ── org_financial_indicators() — live-aware + unit-scoped ────
create or replace function public.org_financial_indicators(target_org uuid default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_assessed_count int;
  v_scope          uuid[];
  v_dti_reported   int;
  v_dti_median     numeric;
  v_dti_bands      json;
  v_ret_median     numeric;
  v_ret_bands      json;
  v_stress_reported int;
  v_stress_median   numeric;
  v_stress_bands    json;
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

  select count(distinct a.user_id) into v_assessed_count
  from assessments a
  join profiles p on p.id = a.user_id
  where p.org_id = target_org
    and (v_scope is null or p.org_unit_id = any(v_scope));

  if v_assessed_count < 5 then
    return json_build_object('eligible', false, 'assessed_count', v_assessed_count);
  end if;

  -- ── DTI ──
  select count(*), percentile_cont(0.5) within group (order by dti_pct)
  into v_dti_reported, v_dti_median
  from (
    select (monthly_debt / nullif(monthly_income, 0) * 100) as dti_pct
    from profiles
    where org_id = target_org
      and (v_scope is null or org_unit_id = any(v_scope))
      and monthly_income is not null and monthly_income > 0
      and monthly_debt is not null
  ) dti_vals;

  select json_agg(
    json_build_object(
      'key', b.key, 'label', b.label,
      'count', case when coalesce(dc.n, 0) between 1 and 2 then null else coalesce(dc.n, 0) end,
      'suppressed', coalesce(dc.n, 0) between 1 and 2
    ) order by b.ord
  ) into v_dti_bands
  from (values
    ('healthy',       'Healthy (<20%)',        1),
    ('manageable',    'Manageable (20–35%)',   2),
    ('strained',      'Strained (35–45%)',     3),
    ('over_indebted', 'Over-indebted (>45%)',  4)
  ) as b(key, label, ord)
  left join (
    select
      case
        when dti_pct < 20 then 'healthy'
        when dti_pct < 35 then 'manageable'
        when dti_pct < 45 then 'strained'
        else 'over_indebted'
      end as band,
      count(*) as n
    from (
      select (monthly_debt / nullif(monthly_income, 0) * 100) as dti_pct
      from profiles
      where org_id = target_org
        and (v_scope is null or org_unit_id = any(v_scope))
        and monthly_income is not null and monthly_income > 0
        and monthly_debt is not null
    ) v
    group by band
  ) dc on dc.band = b.key;

  -- ── Retirement readiness ──
  select percentile_cont(0.5) within group (order by ret_score)
  into v_ret_median
  from (
    select (eff.cats->>'retirement')::numeric as ret_score
    from profiles p
    cross join lateral (
      select cat_scores, created_at from assessments where user_id = p.id order by created_at desc limit 1
    ) a
    cross join lateral (
      select case when p.live_cat_scores is not null and p.live_score_at is not null
                       and p.live_score_at >= a.created_at
                  then p.live_cat_scores else a.cat_scores end as cats
    ) eff
    where p.org_id = target_org
      and (v_scope is null or p.org_unit_id = any(v_scope))
      and eff.cats ? 'retirement'
  ) x;

  select json_agg(
    json_build_object(
      'key', b.key, 'label', b.label,
      'count', case when coalesce(rc.n, 0) between 1 and 2 then null else coalesce(rc.n, 0) end,
      'suppressed', coalesce(rc.n, 0) between 1 and 2
    ) order by b.ord
  ) into v_ret_bands
  from (values
    ('excellent',  'Excellent (85+)',      1),
    ('good',       'Good (70–84)',         2),
    ('fair',       'Fair (55–69)',         3),
    ('needs_work', 'Needs Work (40–54)',   4),
    ('critical',   'Critical (<40)',       5)
  ) as b(key, label, ord)
  left join (
    select
      case
        when ret_score >= 85 then 'excellent'
        when ret_score >= 70 then 'good'
        when ret_score >= 55 then 'fair'
        when ret_score >= 40 then 'needs_work'
        else 'critical'
      end as band,
      count(*) as n
    from (
      select (eff.cats->>'retirement')::numeric as ret_score
      from profiles p
      cross join lateral (
        select cat_scores, created_at from assessments where user_id = p.id order by created_at desc limit 1
      ) a
      cross join lateral (
        select case when p.live_cat_scores is not null and p.live_score_at is not null
                         and p.live_score_at >= a.created_at
                    then p.live_cat_scores else a.cat_scores end as cats
      ) eff
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
        and eff.cats ? 'retirement'
    ) y
    group by band
  ) rc on rc.band = b.key;

  -- ── Financial Stress ──
  select count(*), percentile_cont(0.5) within group (order by lvl)
  into v_stress_reported, v_stress_median
  from (
    select sl.level as lvl
    from profiles p
    cross join lateral (
      select level from stress_logs where user_id = p.id order by created_at desc limit 1
    ) sl
    where p.org_id = target_org
      and (v_scope is null or p.org_unit_id = any(v_scope))
  ) x;

  select json_agg(
    json_build_object(
      'key', b.key, 'label', b.label,
      'count', case when coalesce(sc.n, 0) between 1 and 2 then null else coalesce(sc.n, 0) end,
      'suppressed', coalesce(sc.n, 0) between 1 and 2
    ) order by b.ord
  ) into v_stress_bands
  from (values
    ('low',      'Low (1–3)',      1),
    ('moderate', 'Moderate (4–6)', 2),
    ('high',     'High (7–10)',    3)
  ) as b(key, label, ord)
  left join (
    select
      case
        when lvl <= 3 then 'low'
        when lvl <= 6 then 'moderate'
        else 'high'
      end as band,
      count(*) as n
    from (
      select sl.level as lvl
      from profiles p
      cross join lateral (
        select level from stress_logs where user_id = p.id order by created_at desc limit 1
      ) sl
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
    ) v
    group by band
  ) sc on sc.band = b.key;

  return json_build_object(
    'eligible', true,
    'assessed_count', v_assessed_count,
    'dti', json_build_object(
      'reported_count', v_dti_reported,
      'median', round(v_dti_median, 1),
      'bands', v_dti_bands
    ),
    'retirement', json_build_object(
      'median', round(v_ret_median, 1),
      'bands', v_ret_bands
    ),
    'stress', json_build_object(
      'reported_count', v_stress_reported,
      'median', round(v_stress_median, 1),
      'bands', v_stress_bands
    )
  );
end;
$$;

grant execute on function public.org_financial_indicators(uuid) to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- 1. Legacy no-op: as an existing whole-org employer, await sb.rpc('org_overview')
--    returns the SAME payload as before (v_scope is null).
-- 2. Scoped manager: seed hr_unit_scope for a test HR account scoped to a
--    unit with ≥5 members; await sb.rpc('org_overview') returns only that
--    unit's aggregates; a unit with <5 members returns { suppressed:true }.
-- 3. Debswana manager (scoped to the Debswana parent) sees Jwaneng+Orapa+DCC
--    combined — one figure set, no site breakdown.
-- 4. Privacy: no user_id/email/name anywhere; all <3 cells still suppressed.
-- ============================================================
