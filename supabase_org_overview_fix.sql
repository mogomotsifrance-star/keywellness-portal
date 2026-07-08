-- ============================================================
-- Key Wellness — org_overview() suppression fix
-- Remediates two related HR-data-audit findings (see BUILD-NOTES.md,
-- "org_overview() suppression fix — remediating audit findings #1 and #2"):
--   1. trend[] could disclose an individual member's real wellness score
--      when a historical quarter had exactly one assessor.
--   2. funnel/distribution/dimensions/distress had no <3 suppression at
--      all — only the whole-org n≥5 gate.
-- Also closes a broader version of the same bug found while implementing
-- the fix: summary.avg_score and dimensions.items[].avg can equal an
-- actual individual's score when very few members have been assessed,
-- even if the org itself has ≥5 total members.
--
-- Run this AFTER supabase_org_report_data.sql (defines _suppress_count(),
-- reused here for consistency, though this file also works standalone
-- since it doesn't call it — kept for future alignment).
--
-- CREATE OR REPLACE — safe to re-apply. Same signature as the live
-- function. Rollback: re-apply supabase_employer_dashboard.sql unchanged.
-- ============================================================

create or replace function org_overview(target_org uuid default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  n              int;
  v_assessed_n   int;  -- distinct members with >=1 assessment, org-wide (not period-scoped)
  v_summary      json;
  v_funnel       json;
  v_distribution json;
  v_dimensions   json;
  v_focus_dim    text;
  v_distress     json;
  v_trend        json;
begin

  -- ── Auth: resolve org (unchanged) ─────────────────────────
  if target_org is null then
    target_org := employer_org();
  end if;

  if target_org is null then
    raise exception 'not authorised';
  end if;

  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  -- ── Cohort guard (unchanged) ──────────────────────────────
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

  -- Assessed sub-cohort size, computed once — every section below that
  -- averages or bands assessment data is gated on this, not just n.
  select count(distinct a.user_id) into v_assessed_n
  from assessments a
  join profiles p on p.id = a.user_id
  where p.org_id = target_org;

  -- ── 1. Summary ────────────────────────────────────────────
  -- avg_score/participation_pct suppressed as a pair when v_assessed_n < 3
  -- — an average (or a percentage with a numerator that small) can equal
  -- or nearly reveal an actual individual's score. n_employees always shown
  -- (a raw headcount, not a derived aggregate — matches the whole-org
  -- suppressed state, which already discloses n_employees).
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
  end if;

  -- ── 2. Funnel ─────────────────────────────────────────────
  -- signed_up = n, always shown (whole-org total, already ≥5 by the outer
  -- gate). completed_assessment/did_checkin become null when < 3.
  with counts as (
    select
      (select count(distinct p2.id) from profiles p2
        where p2.org_id = target_org and exists (select 1 from assessments a2 where a2.user_id = p2.id)
      ) as assessed_cnt,
      (select count(distinct p3.id) from profiles p3
        where p3.org_id = target_org and exists (select 1 from checkins c where c.user_id = p3.id)
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
  -- Whole section suppressed when the assessed sub-cohort < 3 — with that
  -- few people, any single band count is attributable to 1-2 individuals.
  -- assessed_count (the raw headcount) is always shown.
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
      select distinct on (p.id) p.id, a.score
      from profiles p
      join assessments a on a.user_id = p.id
      where p.org_id = target_org
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
  -- Same gate as distribution (same underlying assessed sub-cohort) — a
  -- per-dimension average across 1-2 people is their actual score(s).
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
        select cat_scores
        from assessments
        where user_id = p.id
        order by created_at desc
        limit 1
      ) latest
      cross join lateral jsonb_each(latest.cat_scores) as dim(key, value)
      where p.org_id = target_org
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
  -- Own n_assessed gate (may differ slightly from v_assessed_n — only
  -- counts members whose latest assessment includes the 'emergency' key).
  -- n_assessed always shown; pct suppressed when it's < 3.
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
    'suppressed',             (count(*) < 3),
    'pct_low_emergency_fund', case when count(*) < 3 then null else
      round(100.0 * count(*) filter (where emergency_score < 40)::numeric / nullif(count(*), 0), 1)
    end,
    'n_assessed',             count(*),
    'label',                  'Share of assessed employees with emergency-fund coverage under 1–2 months of expenses'
  ) into v_distress
  from latest_emergency;

  -- ── 6. Trend ──────────────────────────────────────────────
  -- Each quarter suppressed independently — a quarter with < 3 assessors
  -- has both avg_score and participants nulled, regardless of how well
  -- other quarters or the current org total are populated.
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
      'avg_score',    case when participants < 3 then null else avg_score end,
      'participants', case when participants < 3 then null else participants end,
      'suppressed',   (participants < 3)
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
    'dimensions',   case when v_assessed_n < 3 then json_build_object('suppressed', true, 'items', null, 'focus_dimension', null)
                         else json_build_object('suppressed', false, 'items', v_dimensions, 'focus_dimension', v_focus_dim)
                    end,
    'distress',     v_distress,
    'trend',        v_trend
  );

end;
$$;


-- ── VERIFICATION QUERIES ─────────────────────────────────────

-- 1. Real org call (swap UUID for one with >=5 members and >=3 assessed):
--    select org_overview('<org-uuid>');
--    Confirm summary/distribution/dimensions/distress all show real data,
--    with suppressed:false where applicable.

-- 2. Construct or find an org with 5+ total members but < 3 assessments:
--    select org_overview('<org-uuid>');
--    -- expect: summary.avg_score/participation_pct = null,
--    --         distribution.suppressed = true (struggling/coping/thriving = null),
--    --         dimensions.suppressed = true (items/focus_dimension = null),
--    --         distress.suppressed = true if n_assessed < 3 (independently checked)

-- 3. Trend leak check — find/construct an org where some historical quarter
--    had exactly 1 or 2 assessors while other quarters (or the current
--    total) are well-populated:
--    select org_overview('<org-uuid>');
--    -- expect: that specific quarter's entry has avg_score: null,
--    --         participants: null, suppressed: true — even though other
--    --         quarters in the same array show real numbers.

-- 4. Grep this file case-insensitively for the banned score-direction
--    term from points_catalog (see BUILD-NOTES.md): zero matches.

-- 5. Confirm employer.html's Overview tab and admin.html's org-overview
--    banner both render the suppressed states as a visible "—" / privacy
--    note rather than blank space, NaN, or "null%".
-- ─────────────────────────────────────────────────────────────
