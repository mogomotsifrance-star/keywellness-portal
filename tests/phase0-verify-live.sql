-- ============================================================
-- Key Wellness — Phase 0 verification for the LIVE database
--
-- Paste into the Supabase SQL Editor and run AFTER
-- supabase_org_account_phase0.sql. Plain SQL: no psql meta-commands,
-- no test data, and READ-ONLY — it writes nothing and changes nothing,
-- so it is safe to run as many times as you like.
--
-- There are three queries. The editor shows one result grid at a time,
-- so run them one at a time: select the query you want and press Run.
--
--   QUERY 1  Did the migration land?          (catalog only — safe anytime)
--   QUERY 2  What did it do to your data?     (after only)
--   QUERY 3  Is the DTI definition live?      (after only)
--
-- The psql test harness (tests/run-phase0.sh) is the thorough one — 47
-- assertions against a throwaway database. This is the quick confirmation
-- that the real thing is in the state you expect.
-- ============================================================


-- ── QUERY 1 ── Did the migration land? ───────────────────────
-- Every row should read PASS. Safe to run before the migration too;
-- it will simply report what is missing.

select
  check_name,
  case when actual = expected then 'PASS' else 'FAIL' end as result,
  actual,
  expected,
  note
from (
  select 'columns added' as check_name,
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'advisor_clients'
        and column_name in ('org_unit_id','no_org','org_mismatch')) as actual,
    3 as expected,
    'org_unit_id, no_org, org_mismatch' as note
  union all
  select 'constraints added',
    (select count(*) from pg_constraint
      where conname in ('advisor_clients_org_required','advisor_clients_unit_needs_org')
        and convalidated),
    2,
    'both present and validated'
  union all
  select 'triggers added',
    (select count(*) from pg_trigger
      where tgname in ('trg_validate_client_unit','trg_sync_advisor_client_org')
        and not tgisinternal),
    2,
    'unit validation on advisor_clients, org sync on profiles'
  union all
  select 'functions added',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('kw_threshold','kw_dti_band','kw_is_over_indebted',
                          'kw_unit_label','kw_validate_client_unit',
                          'kw_sync_advisor_client_org','admin_attribution_queue')),
    7,
    'kw_* helpers plus the attribution queue'
  union all
  select 'threshold keys seeded',
    (select count(*) from threshold_config
      where key in ('indicator.dti','indicator.dimension_flag_below',
                    'indicator.high_cost_credit_rate','indicator.low_base',
                    'indicator.emergency_months_floor','indicator.savings_rate_floor_pct',
                    'panel3.headline')),
    7,
    'indicator definitions and the Panel 3 layout'
  union all
  select 'reward thresholds untouched',
    (select count(*) from threshold_config
      where key in ('sessions_attended_required','learning_library_fraction',
                    'checkin_windows_required','budget_months_required')),
    4,
    'the pre-existing rows must survive'
  union all
  select 'advisor_clients_list carries new fields',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'advisor_clients_list'
        and pg_get_functiondef(p.oid) like '%unit_label%'),
    1,
    'the advisor portal can read org_unit_id, unit_label, no_org, org_mismatch'
) checks
order by result desc, check_name;


-- ── QUERY 2 ── What did it do to your data? ──────────────────
-- Attribution after the backfill. No PASS/FAIL here — this is the
-- picture to look at and sanity-check against what you know.

select
  coalesce(o.name, '(no organisation)')                as organisation,
  count(*) filter (where ac.status = 'active')         as active_clients,
  count(*) filter (where ac.status = 'archived')       as archived_clients,
  count(*) filter (where ac.member_user_id is not null) as linked_to_a_member,
  count(*) filter (where ac.org_unit_id is not null)   as with_a_site,
  count(*) filter (where ac.no_org)                    as private_clients,
  count(*) filter (where ac.org_mismatch)              as needs_review,
  -- Must be zero everywhere. The constraint makes it impossible, so a
  -- non-zero here means the constraint is not actually on.
  count(*) filter (where ac.org_id is null
                     and ac.no_org is not true)        as not_declared
from advisor_clients ac
left join organizations o on o.id = ac.org_id
group by 1
order by active_clients desc, organisation;

-- The same thing as the admin screen will show it. Anything in
-- 'mismatched' needs a human to decide which organisation is right —
-- the migration deliberately did not guess.
--
--   select admin_attribution_queue();


-- ── QUERY 3 ── Is the DTI definition live? ───────────────────
-- The first six rows are the band boundaries. The rest are your actual
-- consultation records, banded by the agreed definition, so you can see
-- what "flagged for debt" will report before any panel is built.

with boundaries as (
  select v.dti, 'boundary check' as source, null::text as client
  from (values (12.0),(28.0),(41.0),(44.9),(45.0),(81.3)) v(dti)
),
live as (
  select
    round(
      100 * (select sum(coalesce((l->>'monthlyInstalment')::numeric, 0))
               from jsonb_array_elements(ac.assessment->'liabilities') l)
          / nullif(
              coalesce((ac.assessment->'income'->>'monthlySalary')::numeric, 0)
            + coalesce((ac.assessment->'income'->>'spouseIncome')::numeric, 0)
            + coalesce((ac.assessment->'income'->>'rentals')::numeric, 0)
            + coalesce((ac.assessment->'income'->>'dividends')::numeric, 0)
            + coalesce((ac.assessment->'income'->>'businessIncome')::numeric, 0), 0)
    , 1) as dti,
    'live consultation record' as source,
    trim(coalesce(ac.first_name,'') || ' ' || coalesce(ac.last_name,'')) as client
  from advisor_clients ac
  where ac.assessment is not null
)
select
  source,
  client,
  dti as dti_pct,
  kw_dti_band(dti)          as band,
  kw_is_over_indebted(dti)  as flagged_for_debt
from (select * from boundaries union all select * from live) x
order by source, dti;

-- Expected on the boundary rows:
--   12.0  healthy        false
--   28.0  manageable     false
--   41.0  strained       false
--   44.9  strained       false
--   45.0  over_indebted  TRUE   <- the boundary is inclusive at the top,
--   81.3  over_indebted  TRUE      matching org_financial_indicators()
--
-- If you want the band labels themselves:
--   select jsonb_pretty(kw_threshold('indicator.dti'));
-- ============================================================
