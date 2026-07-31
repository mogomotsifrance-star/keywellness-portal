-- ============================================================
-- Key Wellness — org_report_data() v4: unit-scoped reporting
-- Run in the Supabase SQL Editor AFTER supabase_org_report_data_v3.sql
-- and supabase_org_units_hr_scope.sql (Batch 3a). Safe to re-run.
--
-- Change vs v3 — ADDITIVE, no v3 output shape changes:
--   • _org_report_period_data gains a 4th arg `p_unit_ids uuid[]`. When
--     NULL the result is byte-identical to v3 (org-wide). When a unit set
--     is passed, EVERY member cohort is filtered to profiles.org_unit_id
--     IN that set, so the ≥5 cohort guard and <3 cell suppression apply
--     PER UNIT VIEW exactly as they do per org (locked decision 6).
--   • The original 3-arg _org_report_period_data is REPLACED by a thin
--     wrapper that calls the 4-arg with NULL — one copy of the body.
--   • Public org_report_data(uuid,date,date) is UNCHANGED (re-emitted as a
--     no-op so this file is standalone). v1 renderers are untouched.
--   • NEW overload org_report_data(uuid,date,date,uuid) — a scoped report
--     for one company/site, scope-validated server-side.
--   • NEW org_report_company_breakdown(uuid,date,date) — the fund
--     manager's per-company table (8 top-level companies; Debswana row =
--     Jwaneng+Orapa+DCC combined), each row independently guarded, plus a
--     count of members with no unit.
--
--   Program activities are ORG-level events (no unit attribution), so in a
--   unit-scoped report they are returned empty rather than mis-attributed
--   or double-counted across company rows — see BUILD-NOTES.md.
--
--   HR-data invariant preserved: still band counts / aggregates only — no
--   names, emails, or per-person financial direction anywhere.
--
-- Rollback: re-apply supabase_org_report_data_v3.sql (restores the 3-arg
-- body) and drop the new overloads (see migrations/rollback-org-units-batch3.sql).
-- ============================================================


-- ── _suppress_rate re-included (unchanged from v3) so this file stands alone.
create or replace function _suppress_rate(numerator int, denominator int)
returns jsonb language sql immutable as $$
  select case
    when denominator is null or denominator = 0 then jsonb_build_object('value', null, 'suppressed', false)
    when numerator is null or numerator < 3      then jsonb_build_object('value', null, 'suppressed', true)
    else jsonb_build_object('value', round(100.0 * numerator / denominator, 1), 'suppressed', false)
  end;
$$;


-- ══════════════════════════════════════════════════════════════
-- 4-arg scoped period function — the single source of the body.
-- p_unit_ids NULL => org-wide (identical to v3). Non-NULL => cohort
-- restricted to profiles.org_unit_id = any(p_unit_ids).
-- ══════════════════════════════════════════════════════════════
create or replace function _org_report_period_data(p_org_id uuid, p_start date, p_end date, p_unit_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n         int;
  v_funnel  jsonb;
  v_sessions jsonb;
  v_categories jsonb;
  v_demographics jsonb;
  v_learning jsonb;
  v_kpi_summary jsonb;
  v_session_intensity jsonb;
  v_client_type_split jsonb;
  v_demographics_cross jsonb;
  v_program_activities jsonb;
  v_wellness_areas jsonb;
  v_data_coverage jsonb;
  v_activated_count int;
  v_total_attended int;
  v_total_noshow int;
  v_total_booked int;
  v_assessed_raw int;
  v_touchpoints int;
begin

  -- Registered cohort as of period end, filtered to the requested units.
  select count(*) into n
  from profiles p
  join auth.users u on u.id = p.id
  where p.org_id = p_org_id
    and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
    and u.created_at <= (p_end + interval '1 day');

  if n < 5 then
    return jsonb_build_object('insufficient_cohort', true);
  end if;

  -- ── Engagement funnel ───────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  assessed as (
    select distinct a.user_id
    from assessments a
    join cohort c on c.id = a.user_id
    where a.created_at::date between p_start and p_end
  ),
  tool_used as (
    select distinct pe.user_id
    from points_events pe
    join cohort c on c.id = pe.user_id
    where pe.event_type = 'tool_first_use'
      and pe.created_at::date between p_start and p_end
  ),
  booked as (
    select distinct b.user_id
    from bookings b
    join cohort c on c.id = b.user_id
    where b.created_at::date between p_start and p_end
  ),
  attended_users as (
    select distinct b.user_id
    from bookings b
    join cohort c on c.id = b.user_id
    where b.attended is true
      and b.created_at::date between p_start and p_end
  ),
  unconfirmed as (
    select count(*) as cnt
    from bookings b
    join cohort c on c.id = b.user_id
    where b.attended is null
      and b.created_at::date between p_start and p_end
  )
  select jsonb_build_object(
    'registered',           n,
    'completed_assessment', _suppress_count((select count(*) from assessed)),
    'used_tool',            _suppress_count((select count(*) from tool_used)),
    'booked_session',       _suppress_count((select count(*) from booked)),
    'attended_session',     _suppress_count((select count(*) from attended_users)),
    'bookings_unconfirmed', (select cnt from unconfirmed)
  ) into v_funnel;

  -- ── Sessions ─────────────────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  period_bookings as (
    select b.*
    from bookings b
    join cohort c on c.id = b.user_id
    where b.created_at::date between p_start and p_end
  ),
  mode_counts as (
    select session_mode, count(*) filter (where attended is true) as attended_cnt
    from period_bookings
    where session_mode is not null
    group by session_mode
  ),
  monthly as (
    select
      date_trunc('month', created_at) as month,
      count(*) as booked_cnt,
      count(*) filter (where attended is true) as attended_cnt
    from period_bookings
    group by date_trunc('month', created_at)
  )
  select jsonb_build_object(
    'total_booked',   (select count(*) from period_bookings),
    'total_attended', (select count(*) filter (where attended is true) from period_bookings),
    'attendance_confirmation_coverage_pct', (
      select round(100.0 * count(*) filter (where attended is not null)::numeric / nullif(count(*), 0), 1)
      from period_bookings
    ),
    'mode_split', (
      select coalesce(jsonb_object_agg(session_mode, _suppress_count(attended_cnt)), '{}'::jsonb)
      from mode_counts
    ),
    'monthly_trend', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'month',    to_char(month, 'YYYY-MM'),
          'booked',   _suppress_count(booked_cnt),
          'attended', _suppress_count(attended_cnt)
        ) order by month
      ), '[]'::jsonb)
      from monthly
    )
  ) into v_sessions;

  -- Raw scalars reused below (all unit-scoped).
  select count(*) filter (where attended is true) into v_total_attended
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
    and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  select count(*) filter (where attended is false) into v_total_noshow
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
    and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  select count(*) into v_total_booked
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
    and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  select count(distinct a.user_id) into v_assessed_raw
  from assessments a join profiles p on p.id = a.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
    and u.created_at <= (p_end + interval '1 day')
    and a.created_at::date between p_start and p_end;

  -- "Activated" = assessed OR used a tool OR booked, in period.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  activated as (
    select c.id from cohort c
    where exists (select 1 from assessments a where a.user_id = c.id and a.created_at::date between p_start and p_end)
       or exists (select 1 from points_events pe where pe.user_id = c.id and pe.event_type = 'tool_first_use' and pe.created_at::date between p_start and p_end)
       or exists (select 1 from bookings b where b.user_id = c.id and b.created_at::date between p_start and p_end)
  )
  select count(*) into v_activated_count from activated;

  -- ── Assessment categories (effective live-or-assessed cat_scores) ──
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  latest_in_period as (
    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at
    from assessments a
    join cohort c on c.id = a.user_id
    where a.created_at::date between p_start and p_end
    order by a.user_id, a.created_at desc
  ),
  effective as (
    select lip.user_id,
      case when p.live_cat_scores is not null and p.live_score_at is not null
                and p.live_score_at >= lip.created_at
                and p.live_score_at::date <= p_end
           then p.live_cat_scores else lip.cat_scores end as cat_scores
    from latest_in_period lip
    join profiles p on p.id = lip.user_id
  ),
  dims as (
    select
      dim.key as dimension,
      (dim.value::text::numeric) as score
    from effective eff
    cross join lateral jsonb_each(eff.cat_scores) as dim(key, value)
    where dim.key <> '_insCount'
  ),
  dim_summary as (
    select
      dimension,
      count(*) as assessed_count,
      count(*) filter (where score < 50) as band_low,
      count(*) filter (where score >= 50 and score < 70) as band_mid,
      count(*) filter (where score >= 70) as band_high
    from dims
    group by dimension
  )
  select coalesce(jsonb_object_agg(
    dimension,
    jsonb_build_object(
      'assessed_count', _suppress_count(assessed_count),
      'band_under_50',  _suppress_count(band_low),
      'band_50_69',     _suppress_count(band_mid),
      'band_70_plus',   _suppress_count(band_high)
    )
  ), '{}'::jsonb) into v_categories
  from dim_summary;

  -- ── Demographics ──────────────────────────────────────────────
  with cohort_ages as (
    select p.age
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  )
  select jsonb_build_object(
    'age_bands', jsonb_build_object(
      '18_29',   _suppress_count((select count(*) from cohort_ages where age between 18 and 29)),
      '30_39',   _suppress_count((select count(*) from cohort_ages where age between 30 and 39)),
      '40_49',   _suppress_count((select count(*) from cohort_ages where age between 40 and 49)),
      '50_plus', _suppress_count((select count(*) from cohort_ages where age >= 50))
    ),
    'gender_note', 'Gender is not currently collected by the portal.'
  ) into v_demographics;

  -- ── Learning ──────────────────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  )
  select jsonb_build_object(
    'articles_read', _suppress_count((
      select count(distinct pe.user_id) from points_events pe join cohort c on c.id = pe.user_id
      where pe.event_type = 'article_read' and pe.created_at::date between p_start and p_end
    )),
    'videos_watched', _suppress_count((
      select count(distinct pe.user_id) from points_events pe join cohort c on c.id = pe.user_id
      where pe.event_type = 'video_watched' and pe.created_at::date between p_start and p_end
    )),
    'quizzes_passed', _suppress_count((
      select count(distinct pe.user_id) from points_events pe join cohort c on c.id = pe.user_id
      where pe.event_type = 'quiz_passed' and pe.created_at::date between p_start and p_end
    ))
  ) into v_learning;

  -- ── Programme activities — ORG-level events, no unit attribution ──
  -- Only meaningful org-wide; a unit-scoped report returns them empty so
  -- they are never mis-attributed to one company or double-counted across
  -- the per-company breakdown.
  if p_unit_ids is null then
    with acts as (
      select * from program_activities
      where org_id = p_org_id and activity_date between p_start and p_end
    ),
    by_type as (
      select activity_type, count(*) as activity_count, sum(attendee_count) as total_attendees
      from acts group by activity_type
    ),
    mode_counts as (
      select delivery_mode, count(*) as cnt from acts where delivery_mode is not null group by delivery_mode
    )
    select jsonb_build_object(
      'by_type', coalesce((
        select jsonb_object_agg(activity_type, jsonb_build_object(
          'activity_count', activity_count, 'total_attendees', total_attendees)) from by_type
      ), '{}'::jsonb),
      'mode_split', coalesce((select jsonb_object_agg(delivery_mode, cnt) from mode_counts), '{}'::jsonb),
      'total_activities', (select count(*) from acts),
      'total_attendees',  coalesce((select sum(attendee_count) from acts), 0),
      'activities_list', coalesce((
        select jsonb_agg(jsonb_build_object(
          'title', title, 'activity_date', activity_date, 'attendee_count', attendee_count,
          'activity_type', activity_type, 'delivery_mode', delivery_mode
        ) order by activity_date) from acts
      ), '[]'::jsonb)
    ) into v_program_activities;
    select coalesce(sum(attendee_count), 0) into v_touchpoints
    from program_activities where org_id = p_org_id and activity_date between p_start and p_end;
  else
    v_program_activities := jsonb_build_object(
      'by_type', '{}'::jsonb, 'mode_split', '{}'::jsonb,
      'total_activities', 0, 'total_attendees', 0, 'activities_list', '[]'::jsonb,
      'unit_scoped_note', 'Programme activities are recorded org-wide and are not shown in company-scoped reports.');
    v_touchpoints := 0;
  end if;

  -- ── KPI summary ───────────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  reach_units as (
    select distinct b.user_id, coalesce(b.client_type, 'member') as client_type
    from bookings b
    join cohort c on c.id = b.user_id
    where b.attended is true
      and b.created_at::date between p_start and p_end
  )
  select jsonb_build_object(
    'participation_rate', _suppress_rate(v_activated_count, n),
    'attendance_rate',     _suppress_rate(v_total_attended, nullif(v_total_attended + v_total_noshow, 0)),
    'total_reach',         (select count(*) from reach_units),
    'total_touchpoints',   v_total_attended + v_touchpoints
  ) into v_kpi_summary;

  -- ── Session intensity ──────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  reach_units as (
    select b.user_id, coalesce(b.client_type, 'member') as client_type, count(*) as session_count
    from bookings b
    join cohort c on c.id = b.user_id
    where b.attended is true
      and b.created_at::date between p_start and p_end
    group by b.user_id, coalesce(b.client_type, 'member')
  ),
  tiered as (
    select
      case when session_count = 1 then '1'
           when session_count = 2 then '2'
           else '3_plus' end as tier
    from reach_units
  )
  select jsonb_build_object(
    '1',      _suppress_count((select count(*) from tiered where tier = '1')),
    '2',      _suppress_count((select count(*) from tiered where tier = '2')),
    '3_plus', _suppress_count((select count(*) from tiered where tier = '3_plus'))
  ) into v_session_intensity;

  -- ── Client type split ──────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  reach_units as (
    select distinct b.user_id, coalesce(b.client_type, 'member') as client_type
    from bookings b
    join cohort c on c.id = b.user_id
    where b.attended is true
      and b.created_at::date between p_start and p_end
  )
  select jsonb_build_object(
    'member',    _suppress_count((select count(*) from reach_units where client_type = 'member')),
    'dependent', _suppress_count((select count(*) from reach_units where client_type = 'dependent'))
  ) into v_client_type_split;

  -- ── Demographics cross: age band × session-intensity tier ──
  with cohort_members as (
    select p.id, p.age
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  member_ages as (
    select id,
      case when age between 18 and 29 then '18_29'
           when age between 30 and 39 then '30_39'
           when age between 40 and 49 then '40_49'
           when age >= 50             then '50_plus'
           else null end as age_band
    from cohort_members
  ),
  session_counts as (
    select b.user_id, count(*) as cnt
    from bookings b
    where b.user_id in (select id from member_ages)
      and coalesce(b.client_type, 'member') = 'member'
      and b.attended is true
      and b.created_at::date between p_start and p_end
    group by b.user_id
  ),
  tiered as (
    select ma.id, ma.age_band,
      case when sc.cnt is null then null
           when sc.cnt = 1 then '1'
           when sc.cnt = 2 then '2'
           else '3_plus' end as tier
    from member_ages ma
    left join session_counts sc on sc.user_id = ma.id
  ),
  age_bands(age_band) as (values ('18_29'), ('30_39'), ('40_49'), ('50_plus')),
  tiers(tier) as (values ('1'), ('2'), ('3_plus')),
  grid as (
    select ab.age_band, t.tier from age_bands ab cross join tiers t
  ),
  counts as (
    select age_band, tier, count(*) as cnt
    from tiered
    where age_band is not null and tier is not null
    group by age_band, tier
  ),
  full_grid as (
    select g.age_band, g.tier, coalesce(c.cnt, 0) as cnt
    from grid g left join counts c using (age_band, tier)
  ),
  cell_flags as (
    select age_band, tier, cnt, (cnt < 3) as cell_suppressed
    from full_grid
  ),
  row_stats as (
    select age_band,
      sum(cnt) as row_total,
      count(*) filter (where cell_suppressed) as row_suppressed_count
    from cell_flags
    group by age_band
  ),
  col_stats as (
    select tier,
      sum(cnt) as col_total,
      count(*) filter (where cell_suppressed) as col_suppressed_count
    from cell_flags
    group by tier
  )
  select jsonb_build_object(
    'rows', (
      select coalesce(jsonb_object_agg(
        rs.age_band,
        jsonb_build_object(
          'cells', (
            select jsonb_object_agg(
              cf.tier,
              case when cf.cell_suppressed
                   then jsonb_build_object('value', null, 'suppressed', true)
                   else jsonb_build_object('value', cf.cnt, 'suppressed', false)
              end
            )
            from cell_flags cf where cf.age_band = rs.age_band
          ),
          'row_total', case when rs.row_suppressed_count = 1
                            then jsonb_build_object('value', null, 'suppressed', true)
                            else jsonb_build_object('value', rs.row_total, 'suppressed', false)
                       end
        )
      ), '{}'::jsonb)
      from row_stats rs
    ),
    'column_totals', (
      select coalesce(jsonb_object_agg(
        cs.tier,
        case when cs.col_suppressed_count = 1
             then jsonb_build_object('value', null, 'suppressed', true)
             else jsonb_build_object('value', cs.col_total, 'suppressed', false)
        end
      ), '{}'::jsonb)
      from col_stats cs
    )
  ) into v_demographics_cross;

  -- ── Wellness areas: "most engaged" ranking by tool usage ───
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
      and u.created_at <= (p_end + interval '1 day')
  ),
  tool_dim as (
    select pe.user_id,
      case pe.ref_id
        when 'budget_planner.html'      then 'spending'
        when 'expense_tracker.html'      then 'spending'
        when 'net_worth_tracker.html'    then 'spending'
        when 'goal_planner.html'         then 'goals'
        when 'debt_management_planner.html' then 'debt'
        when 'dti_calculator.html'       then 'debt'
        when 'loan_calculator.html'      then 'debt'
        when 'affordability_calculator.html' then 'debt'
        when 'rent_vs_buy.html'          then 'debt'
        when 'retirement_calculator.html' then 'retirement'
        when 'life_insurance_calculator.html' then 'insurance'
        when 'education_savings_calculator.html' then 'savings'
        when 'investment_calculator.html' then 'savings'
        when 'lifestyle_inflation_calculator.html' then 'savings'
        else null
      end as dimension
    from points_events pe
    join cohort c on c.id = pe.user_id
    where pe.event_type = 'tool_first_use'
      and pe.created_at::date between p_start and p_end
  ),
  ranked as (
    select dimension, count(distinct user_id) as engaged_count
    from tool_dim
    where dimension is not null
    group by dimension
  )
  select jsonb_build_object(
    'most_engaged', coalesce((
      select jsonb_agg(
        jsonb_build_object('dimension', dimension, 'engaged_count', _suppress_count(engaged_count))
        order by engaged_count desc
      )
      from ranked
    ), '[]'::jsonb)
  ) into v_wellness_areas;

  -- ── Data coverage ───────────────────────────────────────────
  select jsonb_build_object(
    'attendance_confirmation_pct', (
      select round(100.0 * count(*) filter (where attended is not null)::numeric / nullif(count(*), 0), 1)
      from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
      where p.org_id = p_org_id and (p_unit_ids is null or p.org_unit_id = any(p_unit_ids))
        and u.created_at <= (p_end + interval '1 day')
        and b.created_at::date between p_start and p_end
    ),
    'assessment_completion_pct', _suppress_rate(v_assessed_raw, n),
    'statement', 'Figures reflect confirmed portal data as of snapshot date.'
  ) into v_data_coverage;

  return jsonb_build_object(
    'insufficient_cohort',    false,
    'n_employees',            n,
    'period_start',           p_start,
    'period_end',             p_end,
    'engagement_funnel',      v_funnel,
    'sessions',               v_sessions,
    'assessment_categories',  v_categories,
    'demographics',           v_demographics,
    'learning',               v_learning,
    'kpi_summary',            v_kpi_summary,
    'session_intensity',      v_session_intensity,
    'client_type_split',      v_client_type_split,
    'demographics_cross',     v_demographics_cross,
    'program_activities',     v_program_activities,
    'wellness_areas',         v_wellness_areas,
    'data_coverage',          v_data_coverage
  );

end;
$$;

revoke all on function _org_report_period_data(uuid, date, date, uuid[]) from public, anon, authenticated;


-- ── 3-arg wrapper: identical org-wide result as v3, one body only. ──
create or replace function _org_report_period_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select _org_report_period_data(p_org_id, p_start, p_end, null::uuid[]);
$$;

revoke all on function _org_report_period_data(uuid, date, date) from public, anon, authenticated;


-- ── Public 3-arg org_report_data — UNCHANGED (org-wide, current+previous). ──
create or replace function org_report_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current  jsonb;
  v_previous jsonb;
  v_days     int;
  v_prev_start date;
  v_prev_end   date;
begin
  if not (is_admin() or coalesce(employer_org() = p_org_id, false)) then
    raise exception 'not authorised';
  end if;
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  v_current := _org_report_period_data(p_org_id, p_start, p_end);
  if coalesce((v_current->>'insufficient_cohort')::boolean, false) then
    return jsonb_build_object('insufficient_cohort', true);
  end if;

  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;
  v_previous := _org_report_period_data(p_org_id, v_prev_start, v_prev_end);

  return v_current || jsonb_build_object('previous_period', v_previous);
end;
$$;


-- ══════════════════════════════════════════════════════════════
-- NEW: 4-arg scoped report for a single company/site.
-- Scope-validated: a company manager can only pass their own unit or a
-- descendant; admins & whole-org employers may pass any unit in the org.
-- ══════════════════════════════════════════════════════════════
create or replace function org_report_data(p_org_id uuid, p_start date, p_end date, p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids      uuid[];
  v_current  jsonb;
  v_previous jsonb;
  v_days     int;
  v_prev_start date;
  v_prev_end   date;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  if p_unit_id is null then
    -- Whole-org: only admin or a whole-org-scoped employer of this org.
    if not (is_admin() or (coalesce(employer_org() = p_org_id, false) and hr_scoped_unit_ids() is null)) then
      raise exception 'not authorised';
    end if;
    v_ids := null;
  else
    if not hr_unit_in_scope(p_org_id, p_unit_id) then
      raise exception 'not authorised';
    end if;
    select array_agg(d.id) into v_ids from unit_descendants(p_unit_id) d;
  end if;

  v_current := _org_report_period_data(p_org_id, p_start, p_end, v_ids);
  if coalesce((v_current->>'insufficient_cohort')::boolean, false) then
    return jsonb_build_object('insufficient_cohort', true, 'unit_id', p_unit_id);
  end if;

  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;
  v_previous := _org_report_period_data(p_org_id, v_prev_start, v_prev_end, v_ids);

  return v_current || jsonb_build_object('previous_period', v_previous, 'unit_id', p_unit_id);
end;
$$;

grant execute on function org_report_data(uuid, date, date) to authenticated;
grant execute on function org_report_data(uuid, date, date, uuid) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- NEW: fund-manager per-company breakdown.
-- One row per top-level company (Debswana row = Jwaneng+Orapa+DCC
-- combined via descendants). Each row independently ≥5-guarded; a small
-- company returns { suppressed:true } with no numbers. Plus a count of
-- members with no unit (in org totals, in no company row).
-- ══════════════════════════════════════════════════════════════
create or replace function org_report_company_breakdown(p_org_id uuid, p_start date, p_end date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row       record;
  v_ids       uuid[];
  v_report    jsonb;
  v_companies jsonb := '[]'::jsonb;
  v_unassigned int;
begin
  -- Only admin or a whole-org employer (fund Wellness Manager).
  if not (is_admin() or (coalesce(employer_org() = p_org_id, false) and hr_scoped_unit_ids() is null)) then
    raise exception 'not authorised';
  end if;
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  for v_row in
    select id, name from org_units
    where org_id = p_org_id and parent_unit_id is null and is_active = true
    order by sort_order, name
  loop
    select array_agg(d.id) into v_ids from unit_descendants(v_row.id) d;
    v_report := _org_report_period_data(p_org_id, p_start, p_end, v_ids);
    if coalesce((v_report->>'insufficient_cohort')::boolean, false) then
      v_companies := v_companies || jsonb_build_array(jsonb_build_object(
        'unit_id', v_row.id, 'name', v_row.name, 'suppressed', true));
    else
      -- Compact row for the comparison table; full drill-down is available
      -- via org_report_data(p_org_id, p_start, p_end, unit_id).
      v_companies := v_companies || jsonb_build_array(jsonb_build_object(
        'unit_id',          v_row.id,
        'name',             v_row.name,
        'suppressed',       false,
        'n_employees',      v_report->'n_employees',
        'kpi_summary',      v_report->'kpi_summary',
        'engagement_funnel',v_report->'engagement_funnel'));
    end if;
  end loop;

  select count(*) into v_unassigned
  from profiles p
  where p.org_id = p_org_id and p.org_unit_id is null;

  return jsonb_build_object(
    'companies',           v_companies,
    'unassigned_members',  v_unassigned,
    'period_start',        p_start,
    'period_end',          p_end
  );
end;
$$;

grant execute on function org_report_company_breakdown(uuid, date, date) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- publish_org_report() — snapshot the SCOPED data when the draft carries
-- a unit_id, so a published company report records exactly what the
-- counsellor reviewed. Org-wide drafts (unit_id NULL) are byte-identical
-- to the previous version. is_admin() gate and auth.uid() are preserved
-- across the security-definer call (JWT-based), so the inner
-- org_report_data authz passes for the admin.
-- ══════════════════════════════════════════════════════════════
create or replace function publish_org_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      org_reports;
  v_snapshot jsonb;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select * into v_row from org_reports where id = p_report_id;
  if not found then
    raise exception 'report not found';
  end if;
  if v_row.status = 'published' then
    raise exception 'report is already published';
  end if;

  if v_row.unit_id is null then
    v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end);
  else
    v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end, v_row.unit_id);
  end if;

  if coalesce((v_snapshot->>'insufficient_cohort')::boolean, false) then
    raise exception 'cannot publish: fewer than 5 enrolled members for this period/scope';
  end if;

  update org_reports
  set data_snapshot = v_snapshot,
      status        = 'published',
      published_by  = auth.uid(),
      published_at  = now(),
      updated_at    = now()
  where id = p_report_id;
end;
$$;


-- ── VERIFICATION ─────────────────────────────────────────────
-- 1. Org-wide unchanged: org_report_data('<sedimosa>', s, e) equals the v3
--    payload (add previous_period diff — must be byte-identical).
-- 2. Scoped report: org_report_data('<sedimosa>', s, e, '<Mmila-unit>') with
--    <5 Mmila members -> { insufficient_cohort:true, unit_id:... }.
-- 3. Debswana combined: org_report_data('<sedimosa>', s, e, '<Debswana-unit>')
--    aggregates Jwaneng+Orapa+DCC; no site-level rows anywhere in the payload.
-- 4. Breakdown: org_report_company_breakdown('<sedimosa>', s, e) -> 8 company
--    rows (small ones suppressed) + unassigned_members count.
-- 5. Forged unit: as a company manager scoped to Mmila, calling
--    org_report_data('<sedimosa>', s, e, '<Debswana-unit>') must raise
--    'not authorised' (browser console, real HR session — NOT SQL Editor).
-- 6. Privacy grep on any payload: no user_id / email / name / per-person
--    financial direction values.
-- ============================================================
