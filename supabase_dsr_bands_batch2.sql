-- ============================================================
-- DSR bands, Batch 2 — SQL: every DSR band reads indicator.dsr
-- Applied to the live project 4 Oct 2026.
-- Rollback: migrations/rollback-dsr-bands-batch2.sql
-- Depends on: supabase_dsr_bands_batch1.sql (the indicator.dsr row)
--
-- WHAT CHANGES
--   kw_dti_band(), kw_is_over_indebted()
--       read 'indicator.dsr' (40/50/60) instead of 'indicator.dti' (20/35/45).
--   _org_indicator_catalogue()
--       definitions built from the config row instead of typed "45%" text.
--       IMMUTABLE → STABLE, because it now reads a table.
--   _org_indicator_counts()      (admin "Presenting issues"; admin/team lead only)
--   org_financial_indicators()   (HR Debt Health and admin Financial position)
--       denominator: gross salary where recorded, else take-home
--         coalesce(nullif(gross_income, 0), monthly_income)
--       bands: kw_dti_band() and the config labels, instead of a hard-coded
--       CASE 20/35/45.
--
-- WHAT DOES NOT CHANGE
--   Suppression. Cohort below 5 is still ineligible; a band of 1 or 2 is still
--   null + suppressed. Band KEYS are unchanged (healthy, manageable, strained,
--   over_indebted), so employer.html and admin.html read the same shape.
--   Published org reports: publish_org_report snapshots org_report_data(),
--   which carries no DSR, so nothing published moves.
--
-- HOW: the two big functions were last rewritten in place by B1, so their
-- disk files are history. Same method as B1: capture the live bodies into
-- kw_fn_backup, substitute exact strings, assert each substitution landed the
-- expected number of times, execute. A needle that is not found raises and
-- the whole migration rolls back.
--
-- Band counts before and after this change are NOT comparable: the bands
-- moved and, for members with a gross salary, so did the denominator.
-- ============================================================

-- ── 0. Capture the live bodies (idempotent) ──────────────────
insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'dsr-bands-batch2', p.proname, pg_get_function_identity_arguments(p.oid),
       pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('kw_dti_band','kw_is_over_indebted','_org_indicator_catalogue',
                     '_org_indicator_counts','org_financial_indicators')
   and not exists (select 1 from kw_fn_backup b
                    where b.tag = 'dsr-bands-batch2' and b.proname = p.proname
                      and b.identity_args = pg_get_function_identity_arguments(p.oid));

do $$
begin
  if (select count(*) from kw_fn_backup where tag = 'dsr-bands-batch2') <> 5 then
    raise exception 'expected 5 captured bodies under dsr-bands-batch2';
  end if;
end $$;

-- ── 1. kw_dti_band / kw_is_over_indebted ─────────────────────
create or replace function public.kw_dti_band(p_dti numeric)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_bands jsonb;
  v_band  jsonb;
begin
  if p_dti is null then
    return null;
  end if;

  -- indicator.dsr (4 Oct 2026). max is EXCLUSIVE: 40 is manageable,
  -- 50 is strained, 60 is over_indebted.
  v_bands := coalesce(kw_threshold('indicator.dsr') -> 'bands', '[]'::jsonb);

  for v_band in select * from jsonb_array_elements(v_bands) loop
    if v_band ->> 'max' is null or p_dti < (v_band ->> 'max')::numeric then
      return v_band ->> 'key';
    end if;
  end loop;

  return null;
end;
$function$;

create or replace function public.kw_is_over_indebted(p_dti numeric)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select kw_dti_band(p_dti)
       = coalesce(kw_threshold('indicator.dsr') ->> 'flag_band', 'over_indebted');
$function$;

-- ── 2. _org_indicator_catalogue: definitions from the config ──
create or replace function public._org_indicator_catalogue()
 returns table(key text, label text, grp text, source text, historical boolean, definition text)
 language sql
 stable
 set search_path to 'public'
as $function$
  with c as (
    select (kw_threshold('indicator.dsr') ->> 'over_indebted_line')::numeric as line,
           (select (b ->> 'max')::numeric
              from jsonb_array_elements(kw_threshold('indicator.dsr') -> 'bands') b
             where b ->> 'key' = 'manageable') as strained_from
  )
  select * from (values
    ('over_indebted',          'Overindebted',                     'pressure_now',    'profile',    false,
     format('Debt repayments at %s%% or more of gross monthly salary (take-home where gross is not recorded)', (select line from c))),
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
     'Debt dimension below the floor — the member''s own read, alongside the DSR figure'),
    ('dti_strained',           'Approaching the debt ceiling',     'library',         'profile',    false,
     format('DSR between %s%% and %s%% — not overindebted, but new credit will be difficult',
            (select strained_from from c), (select line from c))),
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

-- ── 3. _org_indicator_counts: gross-else-take-home denominator ──
do $$
declare
  v_src text; v_new text;
  n_base  text := 'p.monthly_income > 0 and p.monthly_debt is not null';
  n_ratio text := 'p.monthly_debt / p.monthly_income * 100';
  r_base  text := 'coalesce(nullif(p.gross_income, 0), p.monthly_income) > 0 and p.monthly_debt is not null';
  r_ratio text := 'p.monthly_debt / coalesce(nullif(p.gross_income, 0), p.monthly_income) * 100';
begin
  select replace(definition, E'\r', '') into v_src from kw_fn_backup
   where tag = 'dsr-bands-batch2' and proname = '_org_indicator_counts';
  if v_src is null then raise exception 'no backup body for _org_indicator_counts'; end if;

  if (length(v_src) - length(replace(v_src, n_base, ''))) / length(n_base) <> 3 then
    raise exception '_org_indicator_counts: expected 3 DTI base filters';
  end if;
  if (length(v_src) - length(replace(v_src, n_ratio, ''))) / length(n_ratio) <> 2 then
    raise exception '_org_indicator_counts: expected 2 DTI ratios';
  end if;

  v_new := replace(replace(v_src, n_base, r_base), n_ratio, r_ratio);
  execute v_new;
end $$;

-- ── 4. org_financial_indicators: denominator + bands from config ──
do $$
declare
  v_src text; v_new text;
  n_ratio text := 'select (monthly_debt / nullif(monthly_income, 0) * 100) as dti_pct';
  r_ratio text := 'select (monthly_debt / nullif(coalesce(nullif(gross_income, 0), monthly_income), 0) * 100) as dti_pct';
  n_base  text := 'and monthly_income is not null and monthly_income > 0';
  r_base  text := 'and coalesce(nullif(gross_income, 0), monthly_income) > 0';
  n_vals  text := E'  from (values\n'
               || E'    (''healthy'',       ''Healthy (<20%)'',        1),\n'
               || E'    (''manageable'',    ''Manageable (20–35%)'',   2),\n'
               || E'    (''strained'',      ''Strained (35–45%)'',     3),\n'
               || E'    (''over_indebted'', ''Over-indebted (>45%)'',  4)\n'
               || E'  ) as b(key, label, ord)';
  r_vals  text := E'  from (\n'
               || E'    -- Bands and labels from threshold_config ''indicator.dsr''.\n'
               || E'    select e.b ->> ''key'' as key, e.b ->> ''label'' as label, e.ord::int as ord\n'
               || E'      from jsonb_array_elements(kw_threshold(''indicator.dsr'') -> ''bands'') with ordinality as e(b, ord)\n'
               || E'  ) as b';
  n_case  text := E'      case\n'
               || E'        when dti_pct < 20 then ''healthy''\n'
               || E'        when dti_pct < 35 then ''manageable''\n'
               || E'        when dti_pct < 45 then ''strained''\n'
               || E'        else ''over_indebted''\n'
               || E'      end as band,';
  r_case  text := E'      kw_dti_band(dti_pct) as band,';
begin
  select replace(definition, E'\r', '') into v_src from kw_fn_backup
   where tag = 'dsr-bands-batch2' and proname = 'org_financial_indicators';
  if v_src is null then raise exception 'no backup body for org_financial_indicators'; end if;

  if (length(v_src) - length(replace(v_src, n_ratio, ''))) / length(n_ratio) <> 2 then
    raise exception 'org_financial_indicators: expected 2 DTI ratio selects';
  end if;
  if (length(v_src) - length(replace(v_src, n_base, ''))) / length(n_base) <> 2 then
    raise exception 'org_financial_indicators: expected 2 income filters';
  end if;
  if position(n_vals in v_src) = 0 then raise exception 'org_financial_indicators: DTI band values not found'; end if;
  if position(n_case in v_src) = 0 then raise exception 'org_financial_indicators: DTI CASE not found'; end if;

  v_new := replace(v_src, n_ratio, r_ratio);
  v_new := replace(v_new, n_base, r_base);
  v_new := replace(v_new, n_vals, r_vals);
  v_new := replace(v_new, n_case, r_case);
  execute v_new;
end $$;

-- ── 5. Assertions ────────────────────────────────────────────
do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'org_financial_indicators';
  if v_src ~ 'dti_pct < (20|35|45)' then raise exception 'org_financial_indicators still hard-codes DTI bands'; end if;
  if v_src !~ 'kw_dti_band\(dti_pct\)' then raise exception 'org_financial_indicators does not band through kw_dti_band'; end if;
  -- The retirement and stress blocks must be untouched.
  if v_src !~ 'when ret_score >= 85 then ''excellent''' then raise exception 'retirement bands damaged'; end if;
  if v_src !~ 'between 1 and 2' then raise exception 'suppression damaged'; end if;
  if v_src !~ '_habits_only' then raise exception 'B1 habits-only predicate lost'; end if;

  select prosrc into v_src from pg_proc where proname = '_org_indicator_counts';
  if v_src ~ 'p\.monthly_debt / p\.monthly_income' then raise exception '_org_indicator_counts still on take-home only'; end if;
  if v_src !~ '_habits_only' then raise exception 'B1 habits-only predicate lost from _org_indicator_counts'; end if;

  if kw_dti_band(39.99) <> 'healthy' or kw_dti_band(40) <> 'manageable'
     or kw_dti_band(49.99) <> 'manageable' or kw_dti_band(50) <> 'strained'
     or kw_dti_band(59.99) <> 'strained' or kw_dti_band(60) <> 'over_indebted'
     or kw_dti_band(null) is not null then
    raise exception 'kw_dti_band boundaries wrong';
  end if;
  if kw_is_over_indebted(59.99) or not kw_is_over_indebted(60) then
    raise exception 'kw_is_over_indebted boundary wrong';
  end if;
end $$;
