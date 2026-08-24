-- ============================================================
-- Key Wellness — Organisation Account View, PHASE 1
-- The indicator library.
--
-- Run in the Supabase SQL Editor AFTER supabase_org_account_phase0.sql
-- and supabase_org_account_phase0a_picker.sql. Safe to re-run.
--
-- Rollback: migrations/rollback-org-account-phase1-indicators.sql
--
-- Spec: claude/org-account-view-spec.md (rev 3), §5.2 and §4
-- ============================================================
--
-- WHAT THIS IS
--
-- The presenting-issues answer, computed per organisation from data the
-- portal already holds. No tagging, no advisor behaviour change, and a
-- larger and less self-selected population than consultations reach.
--
-- Six headline indicators in two fixed rows, plus a wider library below
-- them. Every figure carries its own base, because an indicator computed
-- over 6 of 37 members is a different claim from one computed over 30.
--
-- ------------------------------------------------------------
-- DESIGN NOTES
--
-- * ONE INDICATOR, ONE SOURCE. Every indicator is derived from exactly
--   one place — an assessment dimension, or a profile field, or the
--   emergency-fund planner. Mixing sources ("dimension OR planner")
--   would produce a denominator nobody could state honestly in a
--   meeting, which is the whole point of the exercise.
--
-- * INDICATORS ARE A STOCK, NOT A FLOW. Unlike sessions, "how many are
--   over-indebted" is a position as at a date, not a count of events in
--   a window. Both snapshots are therefore "latest known value as at
--   date X": the period end, and the day before the period start.
--
-- * MOVEMENT IS ONLY REPORTED WHERE IT IS REAL. `assessments` are dated,
--   so dimension indicators can genuinely be re-computed as at a past
--   date. `profiles` financial fields are current values with no
--   history — there is no way to know what someone's DTI was in June.
--   Those indicators return movement = null with a stated reason rather
--   than a fabricated zero. Do not "fix" this by comparing a past
--   snapshot against present values; it would report every profile
--   indicator as unchanged forever.
--
-- * NO FLOOR INTERNALLY. Key Wellness staff see every figure at its true
--   base, including 2 of 3, with a low_base marker so nothing gets
--   quoted as a rate by accident. p_client_safe = true applies the
--   existing suppression rules for anything leaving the building.
--
-- * The dimension floor (40), the low-base threshold (5) and the DTI
--   bands all come from threshold_config. Nothing here hard-codes a
--   number that also exists somewhere else.
-- ------------------------------------------------------------


-- ── 1. One snapshot ──────────────────────────────────────────
-- Counts and bases for every indicator, as at a single date. Internal
-- helper: not granted to authenticated, only called by the RPC below.

create or replace function _org_indicator_counts(
  p_org_id   uuid,
  p_unit_ids uuid[],
  p_as_of    date
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
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
    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at
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
           then p.live_cat_scores else l.cat_scores end as cats
    from latest l
    join profiles p on p.id = l.user_id
  ),
  dims as (
    select
      count(*) as assessed,
      -- base = has the dimension at all; count = below the floor
      count(*) filter (where cats ? 'emergency')  as base_emergency,
      count(*) filter (where cats ? 'emergency'  and (cats->>'emergency')::numeric  < v_floor) as no_emergency_buffer,
      count(*) filter (where cats ? 'spending')   as base_spending,
      count(*) filter (where cats ? 'spending'   and (cats->>'spending')::numeric   < v_floor) as living_beyond_means,
      count(*) filter (where cats ? 'retirement') as base_retirement,
      count(*) filter (where cats ? 'retirement' and (cats->>'retirement')::numeric < v_floor) as retirement_shortfall,
      count(*) filter (where cats ? 'insurance')  as base_insurance,
      count(*) filter (where cats ? 'insurance'  and (cats->>'insurance')::numeric  < v_floor) as cover_gap,
      count(*) filter (where cats ? 'savings')    as base_savings,
      count(*) filter (where cats ? 'savings'    and (cats->>'savings')::numeric    < v_floor) as not_building_wealth,
      count(*) filter (where cats ? 'debt')       as base_debt_dim,
      count(*) filter (where cats ? 'debt'       and (cats->>'debt')::numeric       < v_floor) as debt_strain,
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
$$;


-- ── 2. The catalogue ─────────────────────────────────────────
-- Label, grouping, source and plain-English definition for each key.
-- `historical` says whether a past snapshot is meaningful: assessments
-- are dated, profile fields are not.
--
-- NAMING NOTE. The assessment's `income` dimension measures reliance on
-- a single income source, NOT whether people are paid enough. Labelled
-- "income problem" on a page an HR director is reading, it will be heard
-- as "your salaries are too low" — a fight with no upside. Hence the
-- label below, and hence it is not one of the headline six.

create or replace function _org_indicator_catalogue()
returns table (
  key text, label text, grp text, source text, historical boolean, definition text
)
language sql
immutable
set search_path to 'public'
as $$
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
$$;


-- ── 3. Small helper: position of a value in a jsonb array ────
-- Keeps the headline in the order threshold_config declares.

create or replace function _jsonb_array_pos(p_arr jsonb, p_val text)
returns int
language sql
immutable
set search_path to 'public'
as $$
  select min(ord)::int
  from jsonb_array_elements_text(coalesce(p_arr, '[]'::jsonb)) with ordinality as e(val, ord)
  where e.val = p_val;
$$;


-- ── 4. The RPC ───────────────────────────────────────────────

create or replace function admin_org_indicators(
  p_org_id      uuid,
  p_start       date,
  p_end         date,
  p_unit_id     uuid    default null,
  p_client_safe boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_units     uuid[];
  v_now       jsonb;
  v_prev      jsonb;
  v_low_base  int := coalesce((kw_threshold('indicator.low_base'))::int, 5);
  v_order     jsonb;
  v_registered int;
  v_rows      jsonb;
begin
  -- Advisory scope reaches the indicator panel; commercial data does not
  -- (see admin_org_commercial, Phase 5). Deliberately NO employer_org()
  -- branch: nothing advisor-derived reaches employer.html.
  if not (is_admin() or is_team_lead()) then
    raise exception 'not authorised';
  end if;

  if p_org_id is null then
    raise exception 'an organisation is required';
  end if;

  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'invalid period';
  end if;

  if p_unit_id is not null then
    select array_agg(id) into v_units from unit_descendants(p_unit_id);
  end if;

  v_now  := _org_indicator_counts(p_org_id, v_units, p_end);
  v_prev := _org_indicator_counts(p_org_id, v_units, (p_start - 1));

  v_registered := (v_now->>'registered')::int;

  -- Client-safe output hides an organisation that is too small to
  -- report on at all, exactly as org_overview() does.
  if p_client_safe and v_registered < v_low_base then
    return jsonb_build_object(
      'org_id',      p_org_id,
      'suppressed',  true,
      'client_safe', true,
      'registered',  v_registered,
      'message',     'Aggregates appear once at least ' || v_low_base ||
                     ' employees have enrolled, to protect individual privacy.'
    );
  end if;

  v_order := coalesce(kw_threshold('panel3.headline'), '{}'::jsonb);

  select jsonb_agg(row_to_json(t)::jsonb order by t.sort_order, t.label)
    into v_rows
  from (
    select
      cat.key,
      cat.label,
      cat.definition,
      cat.source,
      -- Placement and order come from threshold_config so the panel can
      -- be rearranged without a code change; cat.grp is the fallback if
      -- that config row is ever missing, so the six never silently
      -- collapse into the library.
      case
        when v_order -> 'row_1' @> to_jsonb(cat.key) then 'row_1'
        when v_order -> 'row_2' @> to_jsonb(cat.key) then 'row_2'
        when v_order -> 'row_1' is null and cat.grp = 'pressure_now'    then 'row_1'
        when v_order -> 'row_2' is null and cat.grp = 'future_exposure' then 'row_2'
        else 'library'
      end as placement,
      case
        when v_order -> 'row_1' @> to_jsonb(cat.key)
          then coalesce(_jsonb_array_pos(v_order->'row_1', cat.key), 99)
        when v_order -> 'row_2' @> to_jsonb(cat.key)
          then 100 + coalesce(_jsonb_array_pos(v_order->'row_2', cat.key), 99)
        else 1000
      end as sort_order,
      n.cnt  as count,
      n.base as base,
      case when n.base > 0 then round(100.0 * n.cnt / n.base, 1) end as pct,
      (n.base < v_low_base) as low_base,
      case
        when not cat.historical then null
        when pv.base = 0 or pv.base is null then null
        else jsonb_build_object(
               'previous_count', pv.cnt,
               'previous_base',  pv.base,
               'previous_pct',   round(100.0 * pv.cnt / pv.base, 1),
               'delta_pct',      round(100.0 * n.cnt / nullif(n.base,0), 1)
                                 - round(100.0 * pv.cnt / pv.base, 1)
             )
      end as movement,
      case when cat.historical then null
           else 'No history: this is a current profile value, so it cannot be re-computed as at a past date.'
      end as movement_note
    from _org_indicator_catalogue() cat
    cross join lateral (
      select coalesce((v_now  -> 'counts' -> cat.key ->> 'count')::int, 0) as cnt,
             coalesce((v_now  -> 'counts' -> cat.key ->> 'base')::int,  0) as base
    ) n
    cross join lateral (
      select coalesce((v_prev -> 'counts' -> cat.key ->> 'count')::int, 0) as cnt,
             coalesce((v_prev -> 'counts' -> cat.key ->> 'base')::int,  0) as base
    ) pv
  ) t;

  -- Client-safe blanks any figure resting on too small a base. Internal
  -- output keeps everything and relies on the low_base marker.
  if p_client_safe then
    select jsonb_agg(
             case when (r->>'low_base')::boolean
                 then r || jsonb_build_object('count', null, 'pct', null,
                                              'movement', null, 'suppressed', true)
                 else r || jsonb_build_object('suppressed', false) end)
      into v_rows
    from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) r;
  end if;

  return jsonb_build_object(
    'org_id',       p_org_id,
    'org_name',     (select name from organizations where id = p_org_id),
    'unit_id',      p_unit_id,
    'unit_label',   case when p_unit_id is null then null else kw_unit_label(p_unit_id) end,
    'period_start', p_start,
    'period_end',   p_end,
    'client_safe',  p_client_safe,
    'suppressed',   false,
    'cohort', jsonb_build_object(
      'registered',         v_registered,
      'assessed',           (v_now->>'assessed')::int,
      'registered_before',  (v_prev->>'registered')::int,
      'low_base_threshold', v_low_base
    ),
    'headline', coalesce((
      select jsonb_agg(r order by (r->>'sort_order')::int)
      from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r
      where r->>'placement' in ('row_1','row_2')), '[]'::jsonb),
    'library', coalesce((
      select jsonb_agg(r order by (r->>'pct')::numeric desc nulls last)
      from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r
      where r->>'placement' = 'library'), '[]'::jsonb),
    'note', 'Prevalence among the population each figure can be computed for — '
         || 'not the whole workforce. State the base whenever quoting one.'
  );
end;
$$;

grant execute on function admin_org_indicators(uuid, date, date, uuid, boolean) to authenticated;


-- ── 5. Verification ──────────────────────────────────────────
--
-- 5a. The six headline indicators, in fixed order:
--   select r->>'label' as indicator, r->>'count' as n, r->>'base' as base,
--          r->>'pct' as pct, r->>'low_base' as low_base
--     from jsonb_array_elements(
--            admin_org_indicators('<org_id>', date '2026-01-01', current_date)
--            -> 'headline') r;
--
-- 5b. The library, ranked by prevalence:
--   select r->>'label', r->>'count', r->>'base', r->>'pct'
--     from jsonb_array_elements(
--            admin_org_indicators('<org_id>', date '2026-01-01', current_date)
--            -> 'library') r;
--
-- 5c. Client-safe output blanks small bases:
--   select admin_org_indicators('<org_id>', date '2026-01-01', current_date, null, true);
--
-- 5d. Movement is null for profile-derived indicators, and says why:
--   select r->>'label', r->'movement', r->>'movement_note'
--     from jsonb_array_elements(
--            admin_org_indicators('<org_id>', date '2026-01-01', current_date)
--            -> 'headline') r
--    where r->>'source' = 'profile';
--
-- 5e. An HR manager must NOT be able to call this:
--   -- signed in as an employer: expect 'not authorised'
--   select admin_org_indicators('<org_id>', date '2026-01-01', current_date);
-- ============================================================
