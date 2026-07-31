-- ============================================================
-- Key Wellness — Company Units: post-apply verification (READ-ONLY)
-- Paste the whole block into the Supabase SQL Editor and Run.
-- Runs as `postgres` (bypasses RLS) — structural + data checks only.
-- Every `result` should equal its `expected`. Anything else = that batch
-- did not fully apply. RLS behaviour is checked in the browser (see foot).
--
-- NOTE: the SQL Editor shows only the LAST statement's result, so the
-- pass/fail table is placed LAST on purpose; the seed listing runs first.
-- ============================================================

-- ── Seed listing (runs first; scroll to the pass/fail table below it) ──
select u.sort_order, u.name, p.name as parent, u.is_active
from org_units u
left join org_units p on p.id = u.parent_unit_id
where u.org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
order by u.sort_order;

-- ── PASS/FAIL TABLE (this is the result the editor displays) ──
select seq, check_name, result, expected,
       case when result = expected then '✓' else '✗ CHECK' end as ok
from (
  -- ── Batch 1: schema, seed, account move ──
  select 1 as seq, 'org_units table' as check_name,
    coalesce(to_regclass('public.org_units')::text,'MISSING') as result, 'org_units' as expected
  union all select 2, 'hr_unit_scope table',
    coalesce(to_regclass('public.hr_unit_scope')::text,'MISSING'), 'hr_unit_scope'
  union all select 3, 'profiles.org_unit_id column',
    (select case when exists(select 1 from information_schema.columns
       where table_name='profiles' and column_name='org_unit_id') then 'present' else 'MISSING' end), 'present'
  union all select 4, 'Sedimosa unit count',
    (select count(*)::text from org_units
       where org_id=(select id from organizations where name ilike '%sedimosa%' limit 1)), '11'
  union all select 5, 'Debswana children',
    (select string_agg(c.name, ', ' order by c.sort_order)
       from org_units c join org_units p on p.id=c.parent_unit_id
       where p.name='Debswana'
         and c.org_id=(select id from organizations where name ilike '%sedimosa%' limit 1)), 'Jwaneng, Orapa, DCC'
  union all select 6, 'Tshenolo org / unit',
    (select coalesce(o.name,'?')||' / '||coalesce(ou.name,'?')
       from profiles pr join auth.users u on u.id=pr.id
       left join organizations o on o.id=pr.org_id
       left join org_units ou on ou.id=pr.org_unit_id
       where lower(u.email)='tshenolo@prolearn.co.bw'), 'Sedimosa / Mmila'
  union all select 7, 'set-once trigger present',
    (select case when exists(select 1 from pg_trigger
       where tgname='trg_lock_org_unit_id' and not tgisinternal) then 'present' else 'MISSING' end), 'present'

  -- ── Batch 3a: scope helpers + org_reports.unit_id ──
  union all select 8, 'org_reports.unit_id column',
    (select case when exists(select 1 from information_schema.columns
       where table_name='org_reports' and column_name='unit_id') then 'present' else 'MISSING' end), 'present'
  union all select 9, 'Debswana subtree count (data)',
    (with recursive tree as (
       select id from org_units where name='Debswana'
         and org_id=(select id from organizations where name ilike '%sedimosa%' limit 1)
       union all
       select c.id from org_units c join tree t on c.parent_unit_id=t.id
     ) select count(*)::text from tree), '4'
  union all select 10, 'unit_descendants() function exists',
    (select case when to_regprocedure('unit_descendants(uuid)') is not null then 'present' else 'MISSING' end), 'present'
  union all select 11, 'hr_scoped_unit_ids() exists',
    (select case when to_regprocedure('hr_scoped_unit_ids()') is not null then 'present' else 'MISSING' end), 'present'
  union all select 18, 'hr_unit_in_scope() exists',
    (select case when to_regprocedure('hr_unit_in_scope(uuid,uuid)') is not null then 'present' else 'MISSING' end), 'present'

  -- ── Batch 3: report builder (v4) ──
  union all select 12, 'org_report_data arities (3 & 4)',
    (select string_agg(distinct pronargs::text, ',' order by pronargs::text)
       from pg_proc where proname='org_report_data'), '3,4'
  union all select 13, '_org_report_period_data arities (3 & 4)',
    (select string_agg(distinct pronargs::text, ',' order by pronargs::text)
       from pg_proc where proname='_org_report_period_data'), '3,4'
  union all select 14, 'org_report_company_breakdown() exists',
    (select case when to_regprocedure('org_report_company_breakdown(uuid,date,date)') is not null then 'present' else 'MISSING' end), 'present'
  union all select 15, 'publish_org_report is unit-aware',
    (select case when pg_get_functiondef(to_regprocedure('publish_org_report(uuid)')) like '%unit_id%'
       then 'unit-aware' else 'OLD version' end), 'unit-aware'

  -- ── Batch 3b: live dashboard scoping ──
  union all select 16, 'org_overview is unit-scoped',
    (select case when pg_get_functiondef(to_regprocedure('org_overview(uuid)')) like '%hr_scoped_unit_ids%'
       then 'scoped' else 'NOT scoped' end), 'scoped'
  union all select 17, 'org_financial_indicators is unit-scoped',
    (select case when pg_get_functiondef(to_regprocedure('org_financial_indicators(uuid)')) like '%hr_scoped_unit_ids%'
       then 'scoped' else 'NOT scoped' end), 'scoped'
) checks
order by seq;

-- ============================================================
-- RLS + auth checks — the SQL Editor bypasses RLS, so these MUST be run in
-- the BROWSER console on the test site while logged in (not here):
--
--   • As a Test Co member:      await sb.from('org_units').select('name')   -> []      (no Sedimosa units)
--   • As Tshenolo (Sedimosa):   await sb.from('org_units').select('name')   -> 11 rows
--   • As an existing employer:  await sb.rpc('hr_scoped_unit_ids')          -> null    (whole-org, unchanged)
--   • As an existing employer:  await sb.rpc('org_overview')                -> same payload as before scoping
-- ============================================================
