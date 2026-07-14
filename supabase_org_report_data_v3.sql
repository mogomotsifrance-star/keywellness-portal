-- ============================================================
-- Key Wellness — org_report_data() v3: live tool-fed scores
-- Run this in the Supabase SQL Editor AFTER (or instead of re-running)
-- supabase_org_report_data_v2.sql. Safe to re-run (CREATE OR REPLACE).
-- Companion to supabase_live_wellness.sql (same feature, employer
-- dashboard side) — the profiles.live_* column guards are repeated
-- here so either file can be applied first.
--
-- Change vs v2 — ONE section only:
--   • assessment_categories: a member's live_cat_scores (recomputed
--     client-side from their freshest tool figures — see
--     supabase_live_wellness.sql) replace their assessed cat_scores
--     when BOTH hold:
--       1. live_score_at >= their latest in-period assessment
--          (freshness — a newer assessment always wins), and
--       2. live_score_at::date <= p_end (period integrity — a closed
--          historical period is never rewritten by tool updates that
--          happened after it ended; this also keeps previous_period
--          comparisons purely historical).
--     The member cohort is unchanged: only members with an assessment
--     INSIDE the period appear, so assessed_count still means what the
--     funnel's completed_assessment means. Payload shape is
--     byte-identical to v2 — no renderer changes needed.
--
-- Everything else (funnel, sessions, demographics, learning,
-- kpi_summary, session_intensity, client_type_split,
-- demographics_cross incl. the "cnt" alias fix, program_activities,
-- wellness_areas, data_coverage, suppression rules, signatures,
-- grants) is byte-identical to v2.
--
-- Rollback: re-apply supabase_org_report_data_v2.sql unchanged.
-- ============================================================


-- ── profiles.live_* columns (idempotent; also in supabase_live_wellness.sql) ──
alter table public.profiles
  add column if not exists live_score      numeric,
  add column if not exists live_cat_scores jsonb,
  add column if not exists live_score_at   timestamptz;


-- ── Helper: suppress a rate when its underlying count is small ──
-- (unchanged from v2; re-included so this file is standalone)

create or replace function _suppress_rate(numerator int, denominator int)
returns jsonb
language sql
immutable
as $$
  select case
    when denominator is null or denominator = 0 then jsonb_build_object('value', null, 'suppressed', false)
    when numerator is null or numerator < 3      then jsonb_build_object('value', null, 'suppressed', true)
    else jsonb_build_object('value', round(100.0 * numerator / denominator, 1), 'suppressed', false)
  end;
$$;


create or replace function _org_report_period_data(p_org_id uuid, p_start date, p_end date)
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
begin

  -- Registered cohort as of period end — period-accurate, not "current
  -- total," so the ≥5 guard applies independently per period. No
  -- profiles.created_at column exists; auth.users.created_at is the
  -- established tenure source in this codebase.
  select count(*) into n
  from profiles p
  join auth.users u on u.id = p.id
  where p.org_id = p_org_id
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

  -- Raw scalars reused below for kpi_summary/data_coverage suppression checks.
  select count(*) filter (where attended is true) into v_total_attended
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  select count(*) filter (where attended is false) into v_total_noshow
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  select count(*) into v_total_booked
  from bookings b join profiles p on p.id = b.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and u.created_at <= (p_end + interval '1 day')
    and b.created_at::date between p_start and p_end;

  -- Distinct members, not raw assessment rows — a member who submitted more
  -- than one assessment in the period must not inflate this above 100%.
  select count(distinct a.user_id) into v_assessed_raw
  from assessments a join profiles p on p.id = a.user_id join auth.users u on u.id = p.id
  where p.org_id = p_org_id and u.created_at <= (p_end + interval '1 day')
    and a.created_at::date between p_start and p_end;

  -- "Activated" = assessed OR used a tool OR booked OR attended, in period.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and u.created_at <= (p_end + interval '1 day')
  ),
  activated as (
    select c.id from cohort c
    where exists (select 1 from assessments a where a.user_id = c.id and a.created_at::date between p_start and p_end)
       or exists (select 1 from points_events pe where pe.user_id = c.id and pe.event_type = 'tool_first_use' and pe.created_at::date between p_start and p_end)
       or exists (select 1 from bookings b where b.user_id = c.id and b.created_at::date between p_start and p_end)
  )
  select count(*) into v_activated_count from activated;

  -- ── Assessment categories ────────────────────────────────────
  -- v3 CHANGE: band counts use each member's EFFECTIVE cat_scores — the
  -- live tool-fed snapshot (profiles.live_cat_scores) when it is fresher
  -- than their latest in-period assessment AND falls inside the period;
  -- otherwise the assessed cat_scores, exactly as v2. The cohort is
  -- unchanged (in-period assessors only), so assessed_count keeps its
  -- meaning. Still band counts only — no averages, no deltas, no
  -- per-person scores or direction.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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
  -- Current membership snapshot (not period-scoped — age is a live
  -- attribute, not an event). No gender column exists — see BUILD-NOTES.md.
  with cohort_ages as (
    select p.age
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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
  -- Sourced from points_events (article_read/video_watched/quiz_passed),
  -- which already exist server-side from the points-ledger build.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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

  -- ── KPI summary ───────────────────────────────────────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and u.created_at <= (p_end + interval '1 day')
  ),
  activity_touchpoints as (
    select coalesce(sum(attendee_count), 0) as cnt
    from program_activities
    where org_id = p_org_id and activity_date between p_start and p_end
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
    'total_touchpoints',   v_total_attended + (select cnt from activity_touchpoints)
  ) into v_kpi_summary;

  -- ── Session intensity — aggregate replacement for a per-client table ──
  -- "Client" unit = (user_id, client_type): a member and their dependent(s)
  -- booked under the same account count as up to 2 units, not one per
  -- real dependent (dependents have no separate identity in this schema
  -- — see BUILD-NOTES.md).
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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

  -- ── Client type split (member vs dependent reach) ──────────
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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
  -- Correct complementary suppression: a cell is suppressed if its raw
  -- count < 3; a row/column TOTAL is additionally suppressed only when
  -- EXACTLY ONE cell in that row/column is itself suppressed (otherwise
  -- total minus the other disclosed cells would reveal the hidden one).
  -- See BUILD-NOTES.md for why this axis (not age × gender/client_type)
  -- and the scope limits of this suppression rule.
  with cohort_members as (
    select p.id, p.age
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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
    select ab.age_band, t.tier
    from age_bands ab cross join tiers t
  ),
  counts as (
    select age_band, tier, count(*) as cnt
    from tiered
    where age_band is not null and tier is not null
    group by age_band, tier
  ),
  full_grid as (
    -- Column deliberately NOT named "n" — that collides with this
    -- function's own plpgsql variable `n` (the org headcount) and
    -- raises "column reference is ambiguous" (42702). Discovered live —
    -- see BUILD-NOTES.md.
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

  -- ── Programme activities (off-platform delivery) ───────────
  -- Events, not people — attendee_count is a staff-entered aggregate
  -- number, and the activity list describes events (title/date/count),
  -- never individuals. No suppression needed anywhere in this section.
  with acts as (
    select *
    from program_activities
    where org_id = p_org_id and activity_date between p_start and p_end
  ),
  by_type as (
    select activity_type, count(*) as activity_count, sum(attendee_count) as total_attendees
    from acts
    group by activity_type
  ),
  mode_counts as (
    select delivery_mode, count(*) as cnt
    from acts
    where delivery_mode is not null
    group by delivery_mode
  )
  select jsonb_build_object(
    'by_type', coalesce((
      select jsonb_object_agg(activity_type, jsonb_build_object(
        'activity_count', activity_count, 'total_attendees', total_attendees
      )) from by_type
    ), '{}'::jsonb),
    'mode_split', coalesce((select jsonb_object_agg(delivery_mode, cnt) from mode_counts), '{}'::jsonb),
    'total_activities', (select count(*) from acts),
    'total_attendees',  coalesce((select sum(attendee_count) from acts), 0),
    'activities_list', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'title', title, 'activity_date', activity_date, 'attendee_count', attendee_count,
          'activity_type', activity_type, 'delivery_mode', delivery_mode
        ) order by activity_date
      ) from acts
    ), '[]'::jsonb)
  ) into v_program_activities;

  -- ── Wellness areas: "most engaged" ranking by tool usage ───
  -- Additive alongside assessment_categories — one canonical dimension per
  -- tool file, no tool double-counted. See BUILD-NOTES.md for the full
  -- mapping and the two excluded tools.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
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
      where p.org_id = p_org_id and u.created_at <= (p_end + interval '1 day')
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

revoke all on function _org_report_period_data(uuid, date, date) from public, anon, authenticated;


-- ── Public RPC — unchanged signature, unchanged body ─────────
-- Recreated here only so this file is a complete, standalone application
-- (CREATE OR REPLACE is a no-op vs. the version already live).

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

  -- Immediately preceding period of equal length, independent cohort guard.
  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;

  v_previous := _org_report_period_data(p_org_id, v_prev_start, v_prev_end);

  return v_current || jsonb_build_object('previous_period', v_previous);
end;
$$;


-- ── VERIFICATION QUERIES ─────────────────────────────────────

-- 1. Live band movement — as a member with an in-period assessment, update
--    a tool (e.g. push the budget's savings up), reload the portal
--    dashboard (persists live_cat_scores), then regenerate the report for
--    the CURRENT period:
--    select org_report_data('<org-uuid>', '<period-start>', '<period-end>');
--    -- assessment_categories band counts should shift; assessed_count and
--    -- engagement_funnel.completed_assessment must NOT change (no new
--    -- assessment row).

-- 2. Period integrity — regenerate a CLOSED historical period (p_end in
--    the past, before any live_score_at):
--    -- assessment_categories must be byte-identical to the v2 output for
--    -- the same period. previous_period in call (1) must also be
--    -- unaffected by today's live values.

-- 3. Freshness — a member who reassesses AFTER their last tool update
--    must be banded by the new assessment, not the stale live snapshot.

-- 4. Shape check — diff the JSON tree keys of call (1) against a v2
--    response: identical key set everywhere (renderers in admin.html /
--    kw-report-charts.js are untouched).

-- 5. Privacy — re-run v2's checks: no user_id/email/name anywhere in the
--    payload; suppression cells unchanged (band counts of 1-2 still
--    render {"value": null, "suppressed": true}).
-- ─────────────────────────────────────────────────────────────
