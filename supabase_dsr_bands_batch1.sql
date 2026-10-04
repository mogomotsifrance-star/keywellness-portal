-- ============================================================
-- DSR bands, Batch 1 — the configuration row (additive)
-- Applied to the live project 4 Oct 2026.
-- Rollback: migrations/rollback-dsr-bands-batch1.sql
--
-- WHAT
--   One new threshold_config row, indicator.dsr, holding the debt service
--   ratio bands decided for this build:
--     healthy        below 40%
--     manageable     40% up to below 50%
--     strained       50% up to below 60%
--     over_indebted  60% and above      (label "Overindebted")
--   plus the two numbers the explanations are built on:
--     benchmark          40   the Key Wellness wellbeing benchmark
--     over_indebted_line 60   the over-indebtedness line used for risk flags
--
--   "max" is EXCLUSIVE, exactly as kw_dti_band() already reads it, so
--   40 is manageable, 50 is strained and 60 is over_indebted.
--
-- WHY A NEW ROW AND NOT AN EDIT OF indicator.dti
--   The database is shared by the test site (dev) and the live site (main).
--   advisor.html on main reads indicator.dti and takes its lending norm
--   from bands[manageable].max. Editing that row in place would move every
--   live advisor's lending norm from 35 to 50 the moment this ran, on the
--   old take-home denominator, before any of the new code was merged.
--   A new row lets dev read the new bands while main keeps the old ones
--   until Tshenolo merges. indicator.dti is retired after that merge.
--
-- WHY benchmark IS ITS OWN KEY
--   Under the old bands, manageable.max happened to be the 35% lending norm,
--   and kwLendingNorm() and the Debt Rehab norm read it from there. Under the
--   new bands manageable.max is 50, which is NOT the norm. The benchmark has
--   to be named, or the norm silently moves to 50.
--
-- WHY THERE ARE NO NEW COLUMNS
--   The brief asked for institution / outstanding_balance / term_months on
--   "the liabilities table". There is no such table: advisor liabilities are
--   a JSON array in advisor_clients.assessment->'liabilities', saved by the
--   browser. institution and balance (relabelled "Outstanding balance") are
--   already keys there. termMonths is a new key added by the advisor page in
--   Batch 3; no schema change is needed and RLS on advisor_clients covers it
--   automatically (own advisor, team lead, admin, the linked member; no HR).
--
-- Nothing reads this row until Batch 2.
-- ============================================================

insert into threshold_config (key, value)
values ('indicator.dsr', jsonb_build_object(
  'unit',               'percent',
  'label',              'Debt service ratio',
  'expression',         'total monthly debt repayments ÷ gross monthly salary × 100 (take-home where gross is not recorded)',
  'benchmark',          40,
  'over_indebted_line', 60,
  'flag_band',          'over_indebted',
  'flag_label',         'Overindebted',
  'bands', jsonb_build_array(
    jsonb_build_object('key','healthy',       'max',40,   'label','Healthy (below 40%)'),
    jsonb_build_object('key','manageable',    'max',50,   'label','Manageable (40 to 49.99%)'),
    jsonb_build_object('key','strained',      'max',60,   'label','Strained (50 to 59.99%)'),
    jsonb_build_object('key','over_indebted', 'max',null, 'label','Overindebted (60% and above)')
  )
))
on conflict (key) do nothing;

-- ── Verification (read-only) ────────────────────────────────
-- The same loop kw_dti_band() runs, against the new row. Expect:
--   39.99 healthy · 40 manageable · 49.99 manageable · 50 strained
--   59.99 strained · 60 over_indebted · null null
select v.pct,
       (select b->>'key'
          from jsonb_array_elements((select value->'bands' from threshold_config where key='indicator.dsr'))
               with ordinality as e(b, ord)
         where v.pct is not null
           and (b->>'max' is null or v.pct < (b->>'max')::numeric)
         order by ord limit 1) as band
  from (values (39.99::numeric),(40),(49.99),(50),(59.99),(60),(null)) v(pct);
