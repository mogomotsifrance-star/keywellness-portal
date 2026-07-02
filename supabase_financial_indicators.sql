-- ============================================================
-- Key Wellness — org_financial_indicators() RPC (Batch 6)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE OR REPLACE).
--
-- Purely additive: one new function. Nothing existing is altered.
--
-- Schema notes (see BUILD-NOTES.md for full detail):
--   • DTI is NOT stored in `assessments` — the raw ratio only ever reaches
--     localStorage from wellness_assessment.html. It IS persisted to
--     profiles.monthly_debt / profiles.monthly_income on every assessment
--     (and monthly_income/monthly_expenses on every budget save), so DTI here
--     is computed from `profiles`, not `assessments`.
--   • Retirement readiness uses assessments.cat_scores->>'retirement' (0-100
--     composite), latest assessment per member — same lateral-join pattern
--     already used by org_overview().
--   • Pension contribution % is never persisted anywhere and is OMITTED from
--     this function's output rather than invented.
--
-- Structurally incapable of returning a per-member row: every value returned
-- is an aggregate (count/median) computed inside the function body.
-- ============================================================

create or replace function public.org_financial_indicators(target_org uuid default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_assessed_count int;
  v_dti_reported   int;
  v_dti_median     numeric;
  v_dti_bands      json;
  v_ret_median     numeric;
  v_ret_bands      json;
begin
  -- ── Auth: same gate as org_overview() ──────────────────────────
  if target_org is null then
    target_org := employer_org();
  end if;

  if target_org is null then
    raise exception 'not authorised';
  end if;

  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  -- ── Cohort guard: gated on ASSESSED members, not total enrolled ────
  select count(distinct a.user_id) into v_assessed_count
  from assessments a
  join profiles p on p.id = a.user_id
  where p.org_id = target_org;

  if v_assessed_count < 5 then
    return json_build_object('eligible', false, 'assessed_count', v_assessed_count);
  end if;

  -- ── DTI: reported count + median (profiles.monthly_debt/monthly_income) ──
  select count(*), percentile_cont(0.5) within group (order by dti_pct)
  into v_dti_reported, v_dti_median
  from (
    select (monthly_debt / nullif(monthly_income, 0) * 100) as dti_pct
    from profiles
    where org_id = target_org
      and monthly_income is not null and monthly_income > 0
      and monthly_debt is not null
  ) dti_vals;

  -- DTI bands with cell suppression: any band with 1-2 members hides its
  -- count (null, suppressed:true) — the true small count never leaves this
  -- function. Zero is shown as-is (not suppressed).
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
        and monthly_income is not null and monthly_income > 0
        and monthly_debt is not null
    ) v
    group by band
  ) dc on dc.band = b.key;

  -- ── Retirement readiness: latest assessment per member ─────────
  select percentile_cont(0.5) within group (order by ret_score)
  into v_ret_median
  from (
    select (a.cat_scores->>'retirement')::numeric as ret_score
    from profiles p
    cross join lateral (
      select cat_scores from assessments where user_id = p.id order by created_at desc limit 1
    ) a
    where p.org_id = target_org and a.cat_scores ? 'retirement'
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
      select (a.cat_scores->>'retirement')::numeric as ret_score
      from profiles p
      cross join lateral (
        select cat_scores from assessments where user_id = p.id order by created_at desc limit 1
      ) a
      where p.org_id = target_org and a.cat_scores ? 'retirement'
    ) y
    group by band
  ) rc on rc.band = b.key;

  -- ── Assemble. No pension_contrib_pct key — not derivable (see notes above).
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
    )
  );
end;
$$;

grant execute on function public.org_financial_indicators(uuid) to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run as real users via the browser console (window._toolSb.rpc(...)), not
-- the SQL Editor, so the employer/admin auth gate is actually exercised.

-- 1. Ineligible org (<5 assessed members):
--    await window._toolSb.rpc('org_financial_indicators');
--    Expect: {eligible:false, assessed_count:N} and NOTHING else in the
--    payload — inspect the raw network response, not just the rendered UI.

-- 2. Eligible org with a 1-2 member band:
--    Expect that band's bucket in `dti.bands` / `retirement.bands` to have
--    count:null, suppressed:true. Confirm the true count never appears
--    anywhere in the response (check Network tab, not just what the UI shows).

-- 3. Response contains no user ids, no per-user values, no min/max — inspect
--    the full JSON payload directly.

-- 4. Non-employer, non-admin caller:
--    await window._toolSb.rpc('org_financial_indicators');
--    Expect: an error ("not authorised").
-- ─────────────────────────────────────────────────────────────
