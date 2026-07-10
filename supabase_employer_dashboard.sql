-- ============================================================
-- Key Wellness — Extended org_overview() for HR Dashboard
-- Apply in Supabase SQL Editor BEFORE deploying employer.html.
-- Uses CREATE OR REPLACE — safe to re-apply.
-- Save the previous definition (supabase_fix_org_overview_authz.sql) for rollback.
--
-- Changes from v1:
--   • target_org now has DEFAULT NULL so employers call with no argument.
--   • Returns a richer JSON with six sections: summary, funnel, distribution,
--     dimensions, distress, trend.
--   • Authz and cohort guard (≥5) are unchanged.
--
-- Dimension keys (confirmed from wellness_assessment.html):
--   income, savings, emergency, debt, retirement, insurance, goals, spending
--
-- Tool-usage funnel step: omitted — tools write to localStorage only (v1 gap).
-- Distress proxy: cat_scores->>'emergency' < 40 (vulnerable emergency fund).
-- ============================================================

-- ── ROLLBACK SAVE ────────────────────────────────────────────
-- Before applying, save the current definition for instant rollback:
--   \copy (select pg_get_functiondef(oid) from pg_proc where proname='org_overview') to 'org_overview_v1_backup.txt'
-- Or just keep supabase_fix_org_overview_authz.sql — it is the current definition.
-- ─────────────────────────────────────────────────────────────

create or replace function org_overview(target_org uuid default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  n              int;
  v_summary      json;
  v_funnel       json;
  v_distribution json;
  v_dimensions   json;
  v_focus_dim    text;
  v_distress     json;
  v_trend        json;
begin

  -- ── Auth: resolve org ─────────────────────────────────────
  -- Employers call with no arg → use their own org.
  -- Admins may pass an explicit org id.
  if target_org is null then
    target_org := employer_org();
  end if;

  if target_org is null then
    raise exception 'not authorised';
  end if;

  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  -- ── Cohort guard ──────────────────────────────────────────
  select count(*) into n
  from profiles
  where org_id = target_org;

  if n < 5 then
    return json_build_object(
      'suppressed',   true,
      'n_employees',  n,
      'message',      'Aggregates appear once at least 5 employees have enrolled, to protect individual privacy.'
    );
  end if;

  -- ── 1. Summary ────────────────────────────────────────────
  -- n_employees, participation_pct (≥1 assessment), avg_score of latest per member.
  select json_build_object(
    'n_employees',       n,
    'participation_pct', round(
      100.0 * count(distinct a.user_id)::numeric / nullif(n, 0), 1
    ),
    'avg_score',         round(avg(a.score)::numeric, 1)
  ) into v_summary
  from profiles p
  left join lateral (
    select user_id, score
    from assessments
    where user_id = p.id
    order by created_at desc
    limit 1
  ) a on true
  where p.org_id = target_org;

  -- ── 2. Funnel ─────────────────────────────────────────────
  -- Shows HR where adoption drops off.
  -- "used_tool" step omitted — tool usage is in localStorage only (v1).
  select json_build_object(
    'signed_up',            n,
    'completed_assessment', (
      select count(distinct p2.id)
      from profiles p2
      where p2.org_id = target_org
        and exists (
          select 1 from assessments a2 where a2.user_id = p2.id
        )
    ),
    'did_checkin',          (
      select count(distinct p3.id)
      from profiles p3
      where p3.org_id = target_org
        and exists (
          select 1 from checkins c where c.user_id = p3.id
        )
    ),
    'tool_tracking_note',   'Tool-usage step omitted: calculators write to localStorage. Flag for a future tracking batch.'
  ) into v_funnel;

  -- ── 3. Distribution ───────────────────────────────────────
  -- Band thresholds: struggling 0–39, coping 40–64, thriving 65–100.
  -- Based on each member's LATEST assessment score only.
  with latest_scores as (
    select distinct on (p.id) p.id, a.score
    from profiles p
    join assessments a on a.user_id = p.id
    where p.org_id = target_org
    order by p.id, a.created_at desc
  )
  select json_build_object(
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
    ),
    'assessed_count', count(*)
  ) into v_distribution
  from latest_scores;

  -- ── 4. Dimensions ─────────────────────────────────────────
  -- Average per dimension across the org using each member's latest assessment.
  -- Keys confirmed: income, savings, emergency, debt, retirement, insurance, goals, spending.
  -- focus_dimension = lowest avg (HR's recommended priority).
  with dim_avgs as (
    select
      dim.key                                    as dimension,
      round(avg(dim.value::text::numeric)::numeric, 1) as avg_score
    from profiles p
    cross join lateral (
      select cat_scores
      from assessments
      where user_id = p.id
      order by created_at desc
      limit 1
    ) latest
    cross join lateral jsonb_each(latest.cat_scores) as dim(key, value)
    where p.org_id = target_org
      and dim.key <> '_insCount'   -- exclude internal bookkeeping key
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

  -- ── 5. Distress ───────────────────────────────────────────
  -- Proxy: members whose latest emergency-fund dimension score is < 40.
  -- Framed as a readiness band, not a pula figure.
  with latest_emergency as (
    select distinct on (p.id)
      p.id,
      (a.cat_scores->>'emergency')::numeric as emergency_score
    from profiles p
    join assessments a on a.user_id = p.id
    where p.org_id = target_org
      and a.cat_scores ? 'emergency'
    order by p.id, a.created_at desc
  )
  select json_build_object(
    'pct_low_emergency_fund', round(
      100.0 * count(*) filter (where emergency_score < 40)::numeric
             / nullif(count(*), 0),
      1
    ),
    'n_assessed',             count(*),
    'label',                  'Share of assessed employees with emergency-fund coverage under 1–2 months of expenses'
  ) into v_distress
  from latest_emergency;

  -- ── 6. Trend ──────────────────────────────────────────────
  -- Quarterly average score, last 6 periods, ordered ascending.
  -- Includes only periods with ≥1 assessment from this org's members.
  with quarterly as (
    select
      date_trunc('quarter', a.created_at)  as period,
      round(avg(a.score)::numeric, 1)       as avg_score,
      count(distinct a.user_id)             as participants
    from assessments a
    where a.user_id in (
      select id from profiles where org_id = target_org
    )
    group by date_trunc('quarter', a.created_at)
    order by period desc
    limit 6
  )
  select json_agg(
    json_build_object(
      'period',       to_char(period, 'YYYY "Q"Q'),
      'avg_score',    avg_score,
      'participants', participants
    )
    order by period asc
  ) into v_trend
  from quarterly;

  -- ── Assemble ──────────────────────────────────────────────
  return json_build_object(
    'suppressed',   false,
    'summary',      v_summary,
    'funnel',       v_funnel,
    'distribution', v_distribution,
    'dimensions',   json_build_object(
                      'items',           v_dimensions,
                      'focus_dimension', v_focus_dim
                    ),
    'distress',     v_distress,
    'trend',        v_trend
  );

end;
$$;


-- ── VERIFICATION QUERIES ─────────────────────────────────────
-- Run these in the SQL Editor after applying the function.
-- Replace placeholders with real values from your organizations table.

-- 1. Admin call for a specific org (swap UUID):
--    select org_overview('<your-org-uuid>');

-- 2. Suppressed state — org with <5 members (swap UUID):
--    select org_overview('<small-org-uuid>');

-- 3. Employer self-call (run as an employer user via the API or test session):
--    select org_overview();   -- no arg; resolves via employer_org()

-- 4. Unauthorised access (run as a regular member — should raise exception):
--    select org_overview('<any-org-uuid>');

-- 5. Confirm focus_dimension matches the lowest item in dimensions.items:
--    Check result->'dimensions'->>'focus_dimension' == min avg in items array.
-- ─────────────────────────────────────────────────────────────
