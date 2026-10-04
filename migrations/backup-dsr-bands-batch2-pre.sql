-- ============================================================
-- BACKUP — the five function bodies as they were live immediately before
-- supabase_dsr_bands_batch2.sql, read with pg_get_functiondef on 4 Oct 2026.
--
-- FOR READING. The rollback (migrations/rollback-dsr-bands-batch2.sql)
-- restores from kw_fn_backup tag 'dsr-bands-batch2', which captured these
-- same bodies inside the migration itself. Use this file to see what changed,
-- or as a last resort if kw_fn_backup were ever lost.
--
-- The threshold_config row these read, 'indicator.dti', was NOT changed:
--   {"unit":"percent","label":"Debt-to-income","flag_band":"over_indebted",
--    "flag_label":"Over-indebted",
--    "expression":"monthly debt service ÷ gross monthly income × 100",
--    "bands":[{"key":"healthy","max":20,"label":"Healthy (under 20%)"},
--             {"key":"manageable","max":35,"label":"Manageable (20–34.9%)"},
--             {"key":"strained","max":45,"label":"Strained (35–44.9%)"},
--             {"key":"over_indebted","max":null,"label":"Over-indebted (45%+)"}]}
-- ============================================================

CREATE OR REPLACE FUNCTION public.kw_dti_band(p_dti numeric)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bands jsonb;
  v_band  jsonb;
begin
  if p_dti is null then
    return null;
  end if;

  v_bands := coalesce(kw_threshold('indicator.dti') -> 'bands', '[]'::jsonb);

  for v_band in select * from jsonb_array_elements(v_bands) loop
    if v_band ->> 'max' is null or p_dti < (v_band ->> 'max')::numeric then
      return v_band ->> 'key';
    end if;
  end loop;

  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.kw_is_over_indebted(p_dti numeric)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select kw_dti_band(p_dti)
       = coalesce(kw_threshold('indicator.dti') ->> 'flag_band', 'over_indebted');
$function$;

CREATE OR REPLACE FUNCTION public._org_indicator_catalogue()
 RETURNS TABLE(key text, label text, grp text, source text, historical boolean, definition text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select * from (values
    ('over_indebted',          'Over-indebted',                    'pressure_now',    'profile',    false,
     'Debt service above 45% of gross monthly income'),
    ('no_emergency_buffer',    'No emergency buffer',              'pressure_now',    'assessment', true,
     'Emergency-fund dimension below the floor'),
    ('living_beyond_means',    'Living beyond means',              'pressure_now',    'assessment', true,
     'Spending dimension below the floor'),
    ('retirement_shortfall',   'Retirement shortfall',             'future_exposure', 'assessment', true,
     'Retirement dimension below the floor'),
    ('cover_gap',              'Cover gap',                        'future_exposure', 'assessment', true,
     'Insurance dimension below the floor'),
    ('not_building_wealth',    'Not building wealth',              'future_exposure', 'assessment', true,
     'Savings dimension below the floor'),
    ('debt_strain',            'Debt strain (self-assessed)',      'library',         'assessment', true,
     'Debt dimension below the floor — the member''s own read, alongside the DTI figure'),
    ('dti_strained',           'Approaching the debt ceiling',     'library',         'profile',    false,
     'DTI between 35% and 45% — new credit will be difficult'),
    ('low_savings_rate',       'Saving under 10% of income',       'library',         'profile',    false,
     'Monthly savings below 10% of monthly income'),
    ('thin_emergency_months',  'Under one month of cover',         'library',         'planner',    false,
     'Emergency-fund planner shows less than one month of expenses saved'),
    ('negative_net_worth',     'Negative net worth',               'library',         'profile',    false,
     'Liabilities exceed assets'),
    ('no_will',                'No will in place',                 'library',         'profile',    false,
     'Answered "no will" on the estate question'),
    ('high_financial_stress',  'High financial stress',            'library',         'stress_log', true,
     'Most recent stress check-in at 7 or above out of 10'),
    ('goals_unclear',          'No clear financial goals',         'library',         'assessment', true,
     'Goals dimension below the floor'),
    ('single_income_reliance', 'Reliance on a single income source','library',        'assessment', true,
     'Income dimension below the floor. NOT a statement about pay levels')
  ) as t(key, label, grp, source, historical, definition);
$function$;

CREATE OR REPLACE FUNCTION public._org_indicator_counts(p_org_id uuid, p_unit_ids uuid[], p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_floor  numeric := coalesce((kw_threshold('indicator.dimension_flag_below'))::numeric, 40);
  v_months numeric := coalesce((kw_threshold('indicator.emergency_months_floor'))::numeric, 1);
  v_srate  numeric := coalesce((kw_threshold('indicator.savings_rate_floor_pct'))::numeric, 10);
  v_out    jsonb;
begin
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at::date <= p_as_of
  ),
  -- Latest assessment as at the snapshot date.
  latest as (
    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at, a.answers
    from assessments a
    join cohort c on c.id = a.user_id
    where a.created_at::date <= p_as_of
    order by a.user_id, a.created_at desc
  ),
  -- The live score wins when it is newer than that assessment and not
  -- itself in the future relative to the snapshot.
  eff as (
    select l.user_id,
      case when p.live_cat_scores is not null
                and p.live_score_at is not null
                and p.live_score_at >= l.created_at
                and p.live_score_at::date <= p_as_of
           then p.live_cat_scores else l.cat_scores end as cats,
      -- B1: scored = we have figures behind these dimensions. A habits-only
      -- row with no gated live score is behaviour answers alone.
      not (coalesce((l.answers->>'_habits_only')::boolean, false) and p.live_score is null) as scored
    from latest l
    join profiles p on p.id = l.user_id
  ),
  dims as (
    select
      count(*) as assessed,
      -- base = has the dimension at all; count = below the floor
      count(*) filter (where scored)               as scored_n,
      count(*) filter (where not scored)           as engaged_not_scored,
      count(*) filter (where scored and cats ? 'emergency')  as base_emergency,
      count(*) filter (where scored and cats ? 'emergency'  and (cats->>'emergency')::numeric  < v_floor) as no_emergency_buffer,
      count(*) filter (where scored and cats ? 'spending')   as base_spending,
      count(*) filter (where scored and cats ? 'spending'   and (cats->>'spending')::numeric   < v_floor) as living_beyond_means,
      count(*) filter (where scored and cats ? 'retirement') as base_retirement,
      count(*) filter (where scored and cats ? 'retirement' and (cats->>'retirement')::numeric < v_floor) as retirement_shortfall,
      count(*) filter (where scored and cats ? 'insurance')  as base_insurance,
      count(*) filter (where scored and cats ? 'insurance'  and (cats->>'insurance')::numeric  < v_floor) as cover_gap,
      count(*) filter (where scored and cats ? 'savings')    as base_savings,
      count(*) filter (where scored and cats ? 'savings'    and (cats->>'savings')::numeric    < v_floor) as not_building_wealth,
      count(*) filter (where scored and cats ? 'debt')       as base_debt_dim,
      count(*) filter (where scored and cats ? 'debt'       and (cats->>'debt')::numeric       < v_floor) as debt_strain,
      count(*) filter (where cats ? 'goals')      as base_goals,
      count(*) filter (where cats ? 'goals'      and (cats->>'goals')::numeric      < v_floor) as goals_unclear,
      count(*) filter (where cats ? 'income')     as base_income_dim,
      count(*) filter (where cats ? 'income'     and (cats->>'income')::numeric     < v_floor) as single_income_reliance
    from eff
  ),
  fin as (
    select
      count(*) filter (where p.monthly_income > 0 and p.monthly_debt is not null) as base_dti,
      count(*) filter (where p.monthly_income > 0 and p.monthly_debt is not null
                         and kw_is_over_indebted(p.monthly_debt / p.monthly_income * 100)) as over_indebted,
      count(*) filter (where p.monthly_income > 0 and p.monthly_debt is not null
                         and kw_dti_band(p.monthly_debt / p.monthly_income * 100) = 'strained') as dti_strained,
      count(*) filter (where p.total_assets is not null and p.total_liabilities is not null) as base_networth,
      count(*) filter (where p.total_assets is not null and p.total_liabilities is not null
                         and (p.total_assets - p.total_liabilities) < 0) as negative_net_worth,
      count(*) filter (where p.monthly_income > 0 and p.monthly_savings is not null) as base_savings_rate,
      count(*) filter (where p.monthly_income > 0 and p.monthly_savings is not null
                         and (p.monthly_savings / p.monthly_income * 100) < v_srate) as low_savings_rate,
      count(*) filter (where p.will_status is not null)        as base_will,
      count(*) filter (where p.will_status = 'no_will')        as no_will
    from profiles p
    join cohort c on c.id = p.id
  ),
  ef as (
    select
      count(*) as base_ef_months,
      count(*) filter (where (e.current_savings / e.monthly) < v_months) as thin_emergency_months
    from emergency_fund e
    join cohort c on c.id = e.user_id
    where e.monthly > 0 and e.current_savings is not null
  ),
  stress as (
    select
      count(*) as base_stress,
      count(*) filter (where s.level >= 7) as high_financial_stress
    from cohort c
    cross join lateral (
      select level from stress_logs
       where user_id = c.id and created_at::date <= p_as_of
       order by created_at desc limit 1
    ) s
  )
  select jsonb_build_object(
    'registered', (select count(*) from cohort),
    'assessed',   (select assessed from dims),
    -- B1: assessed, but with nothing behind the figures. Counted, never scored.
    'engaged_not_scored', (select engaged_not_scored from dims),
    'counts', jsonb_build_object(
      'over_indebted',          jsonb_build_object('count', f.over_indebted,          'base', f.base_dti),
      'no_emergency_buffer',    jsonb_build_object('count', d.no_emergency_buffer,    'base', d.base_emergency),
      'living_beyond_means',    jsonb_build_object('count', d.living_beyond_means,    'base', d.base_spending),
      'retirement_shortfall',   jsonb_build_object('count', d.retirement_shortfall,   'base', d.base_retirement),
      'cover_gap',              jsonb_build_object('count', d.cover_gap,              'base', d.base_insurance),
      'not_building_wealth',    jsonb_build_object('count', d.not_building_wealth,    'base', d.base_savings),
      'debt_strain',            jsonb_build_object('count', d.debt_strain,            'base', d.base_debt_dim),
      'goals_unclear',          jsonb_build_object('count', d.goals_unclear,          'base', d.base_goals),
      'single_income_reliance', jsonb_build_object('count', d.single_income_reliance, 'base', d.base_income_dim),
      'dti_strained',           jsonb_build_object('count', f.dti_strained,           'base', f.base_dti),
      'negative_net_worth',     jsonb_build_object('count', f.negative_net_worth,     'base', f.base_networth),
      'low_savings_rate',       jsonb_build_object('count', f.low_savings_rate,       'base', f.base_savings_rate),
      'no_will',                jsonb_build_object('count', f.no_will,                'base', f.base_will),
      'thin_emergency_months',  jsonb_build_object('count', e.thin_emergency_months,  'base', e.base_ef_months),
      'high_financial_stress',  jsonb_build_object('count', s.high_financial_stress,  'base', s.base_stress)
    )
  ) into v_out
  from dims d, fin f, ef e, stress s;

  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION public.org_financial_indicators(target_org uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_assessed_count int;
  v_scope          uuid[];
  v_dti_reported   int;
  v_dti_median     numeric;
  v_dti_bands      json;
  v_ret_reported   int;
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
  select count(*), percentile_cont(0.5) within group (order by ret_score)
  into v_ret_reported, v_ret_median
  from (
    select (eff.cats->>'retirement')::numeric as ret_score
    from profiles p
    cross join lateral (
      select cat_scores, created_at, answers from assessments where user_id = p.id order by created_at desc limit 1
    ) a
    cross join lateral (
      select case when p.live_cat_scores is not null and p.live_score_at is not null
                       and p.live_score_at >= a.created_at
                  then p.live_cat_scores else a.cat_scores end as cats
    ) eff
    where p.org_id = target_org
      and (v_scope is null or p.org_unit_id = any(v_scope))
      and eff.cats ? 'retirement'
      and not (coalesce((a.answers->>'_habits_only')::boolean, false)
               and p.live_score is null)
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
        select cat_scores, created_at, answers from assessments where user_id = p.id order by created_at desc limit 1
      ) a
      cross join lateral (
        select case when p.live_cat_scores is not null and p.live_score_at is not null
                         and p.live_score_at >= a.created_at
                    then p.live_cat_scores else a.cat_scores end as cats
      ) eff
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
        and eff.cats ? 'retirement'
        and not (coalesce((a.answers->>'_habits_only')::boolean, false)
                 and p.live_score is null)
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
      'reported_count', v_ret_reported,
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
$function$;
