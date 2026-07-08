-- ============================================================
-- Key Wellness — Organisation Utilisation Report Pipeline
-- Batch 2: org_report_data() RPC
-- Run this AFTER supabase_org_reports.sql (Batch 1) in the Supabase SQL
-- Editor. Safe to re-run (CREATE OR REPLACE).
--
-- Design decisions recorded in BUILD-NOTES.md ("Batch 2 — org_report_data()
-- RPC design notes"). Rollback statements were recorded there before this
-- file was written.
-- ============================================================


-- ── Helper: <3 suppression wrapper ───────────────────────────
-- Every cell that counts distinct people in a bucket goes through this.

create or replace function _suppress_count(v int)
returns jsonb
language sql
immutable
as $$
  select case
    when v is null then jsonb_build_object('value', 0, 'suppressed', false)
    when v < 3     then jsonb_build_object('value', null, 'suppressed', true)
    else                jsonb_build_object('value', v, 'suppressed', false)
  end;
$$;


-- ── Helper: single-period aggregate computation ──────────────
-- security definer: must bypass RLS to read across all org members (HR has
-- deliberately no read policy on assessments/profiles/bookings, same as
-- org_overview()). EXECUTE is revoked from public/anon/authenticated below
-- so this cannot be called directly to skip org_report_data()'s authz check
-- — only org_report_data() (also security definer, running as the same
-- owner) can reach it.

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

  -- ── Assessment categories ────────────────────────────────────
  -- Keyed by real cat_scores dimension names (income, savings, emergency,
  -- debt, retirement, insurance, goals, spending), not the spec's
  -- illustrative labels — see BUILD-NOTES.md. No averages, no deltas, no
  -- per-person scores or direction — band counts only.
  with cohort as (
    select p.id
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and u.created_at <= (p_end + interval '1 day')
  ),
  latest_in_period as (
    select distinct on (a.user_id) a.user_id, a.cat_scores
    from assessments a
    join cohort c on c.id = a.user_id
    where a.created_at::date between p_start and p_end
    order by a.user_id, a.created_at desc
  ),
  dims as (
    select
      dim.key as dimension,
      (dim.value::text::numeric) as score
    from latest_in_period lip
    cross join lateral jsonb_each(lip.cat_scores) as dim(key, value)
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

  return jsonb_build_object(
    'insufficient_cohort',   false,
    'n_employees',           n,
    'period_start',          p_start,
    'period_end',            p_end,
    'engagement_funnel',     v_funnel,
    'sessions',              v_sessions,
    'assessment_categories', v_categories,
    'demographics',          v_demographics,
    'learning',              v_learning
  );

end;
$$;

revoke all on function _org_report_period_data(uuid, date, date) from public, anon, authenticated;


-- ── Public RPC ────────────────────────────────────────────────
-- Authorisation mirrors org_overview() exactly (see BUILD-NOTES.md Batch 0):
-- admin, or the HR manager of THIS org only, with the coalesce(...,false)
-- NULL-logic fix already applied (not the pre-fix version).

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
-- Run these per Batch 2's checklist.

-- 1. Grep this file case-insensitively for the banned score-direction
--    term from points_catalog (see BUILD-NOTES.md Batch 0/2): zero matches.

-- 2. Sample call (swap UUID + dates for a real org with ≥5 members):
--    select org_report_data('<org-uuid>', '2026-04-01', '2026-06-30');
--    Manually inspect the full JSON for any user_id/email/name — should be
--    none anywhere in the tree, including previous_period.

-- 3. Cohort <5 org (swap UUID for a small/dummy org):
--    select org_report_data('<small-org-uuid>', '2026-04-01', '2026-06-30');
--    -- expect {"insufficient_cohort": true}

-- 4. Suppression check — find an org/period with a category or age band
--    under 3 people and confirm that cell reads
--    {"value": null, "suppressed": true}.

-- 5. Unauthorised caller (run as a plain member, or as HR for a DIFFERENT
--    org than p_org_id) — should raise 'not authorised'.

-- 6. Direct call to the private helper should fail with a permission error:
--    select _org_report_period_data('<org-uuid>', '2026-04-01', '2026-06-30');
--    -- expect: permission denied for function _org_report_period_data
-- ─────────────────────────────────────────────────────────────
