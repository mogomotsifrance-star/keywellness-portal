-- Key Wellness — Phase 1 assertions (the indicator library).
--
-- psql ONLY. Uses psql meta-commands and seeds throwaway data. It will NOT
-- run in the Supabase SQL editor and must never touch the live database.
--
-- Run it with: tests/run-phase0.sh
\set ON_ERROR_STOP on
\pset pager off

-- ── Seed ──────────────────────────────────────────────────────
-- A ten-member organisation with known, hand-counted answers. Sedimosa
-- and BOPEU already exist from the Phase 0 fixture; this adds a clean
-- one so the arithmetic is not entangled with earlier tests.

insert into organizations (id, name, invite_code)
  values ('44444444-4444-4444-4444-444444444444','Indicator Test Co','INDI-0001');

insert into org_units (id, org_id, parent_unit_id, name) values
  ('44440000-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444', null, 'North Site'),
  ('44440000-0000-0000-0000-000000000002','44444444-4444-4444-4444-444444444444', null, 'South Site');

-- Ten members, all registered a year ago.
do $$
declare i int;
begin
  for i in 1..10 loop
    insert into auth.users (id, email, created_at)
    values (('55550000-0000-0000-0000-0000000000' || lpad(i::text,2,'0'))::uuid,
            'ind' || i || '@example.com', now() - interval '365 days');
    insert into profiles (id, org_id, org_unit_id, first_name)
    values (('55550000-0000-0000-0000-0000000000' || lpad(i::text,2,'0'))::uuid,
            '44444444-4444-4444-4444-444444444444'::uuid,
            (case when i <= 6 then '44440000-0000-0000-0000-000000000001'
                             else '44440000-0000-0000-0000-000000000002' end)::uuid,
            'Member ' || i);
  end loop;
end $$;

-- DTI: 8 of 10 have income+debt captured.
--   members 1–3 over 45% (over-indebted), member 4 at 40% (strained),
--   members 5–8 comfortable, members 9–10 no financials at all.
update profiles set monthly_income = 10000, monthly_debt = 6000 where first_name in ('Member 1','Member 2','Member 3');
update profiles set monthly_income = 10000, monthly_debt = 4000 where first_name = 'Member 4';
update profiles set monthly_income = 10000, monthly_debt = 1000 where first_name in ('Member 5','Member 6','Member 7','Member 8');

-- Net worth: 5 captured, 2 negative.
update profiles set total_assets = 1000,  total_liabilities = 9000 where first_name in ('Member 1','Member 2');
update profiles set total_assets = 90000, total_liabilities = 1000 where first_name in ('Member 3','Member 4','Member 5');

-- Savings rate: 6 captured, 3 under 10%.
update profiles set monthly_savings = 200  where first_name in ('Member 1','Member 2','Member 3');
update profiles set monthly_savings = 2500 where first_name in ('Member 4','Member 5','Member 6');

-- Wills: 4 answered, 3 without one.
update profiles set will_status = 'no_will'  where first_name in ('Member 1','Member 2','Member 3');
update profiles set will_status = 'has_will' where first_name = 'Member 4';

-- Assessments. 7 of 10 assessed, all dated inside the period.
-- Members 1–4 score 30 on every dimension (below the 40 floor);
-- members 5–7 score 80 on every dimension.
do $$
declare i int; v_score int;
begin
  for i in 1..7 loop
    v_score := case when i <= 4 then 30 else 80 end;
    insert into assessments (user_id, score, cat_scores, created_at)
    values (('55550000-0000-0000-0000-0000000000' || lpad(i::text,2,'0'))::uuid,
            v_score,
            jsonb_build_object('emergency', v_score, 'spending', v_score,
                               'retirement', v_score, 'insurance', v_score,
                               'savings',   v_score, 'debt',     v_score,
                               'goals',     v_score, 'income',   v_score),
            now() - interval '30 days');
  end loop;
end $$;

-- An older, worse assessment for member 5, well before the period, so
-- the previous-period snapshot genuinely differs from the current one.
insert into assessments (user_id, score, cat_scores, created_at)
values ('55550000-0000-0000-0000-000000000005', 20,
        jsonb_build_object('emergency',20,'spending',20,'retirement',20,'insurance',20,
                           'savings',20,'debt',20,'goals',20,'income',20),
        now() - interval '200 days');

-- Emergency-fund planner: 4 users, 3 under one month.
insert into emergency_fund (user_id, monthly, current_savings) values
  ('55550000-0000-0000-0000-000000000001', 5000, 100),
  ('55550000-0000-0000-0000-000000000002', 5000, 500),
  ('55550000-0000-0000-0000-000000000003', 5000, 4999),
  ('55550000-0000-0000-0000-000000000004', 5000, 20000);

-- Stress: 5 logged, 2 currently high (most recent entry counts).
insert into stress_logs (user_id, level, created_at) values
  ('55550000-0000-0000-0000-000000000001', 9, now() - interval '5 days'),
  ('55550000-0000-0000-0000-000000000002', 8, now() - interval '5 days'),
  ('55550000-0000-0000-0000-000000000003', 2, now() - interval '5 days'),
  ('55550000-0000-0000-0000-000000000004', 3, now() - interval '5 days'),
  -- an old high reading that a newer calm one supersedes
  ('55550000-0000-0000-0000-000000000005', 10, now() - interval '90 days'),
  ('55550000-0000-0000-0000-000000000005', 1,  now() - interval '3 days');

set session "test.email" = 'admin@keywellness.co.bw';

-- Convenience: pull one indicator out of a result by key.
create or replace function ind(p_res jsonb, p_key text) returns jsonb
language sql stable as $$
  select r from jsonb_array_elements(
                  coalesce(p_res->'headline','[]'::jsonb) ||
                  coalesce(p_res->'library','[]'::jsonb)) r
   where r->>'key' = p_key;
$$;

create or replace function res() returns jsonb
language sql stable as $$
  select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                              (current_date - 90), current_date);
$$;


-- ══════════════════════════════════════════════════════════════
-- 11. Authorisation
-- ══════════════════════════════════════════════════════════════
set session "test.email" = 'nobody@example.com';
select t('11a a signed-in nobody is refused',
  raises($$select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                                       current_date - 90, current_date)$$, 'not authorised'));

set session "test.email" = 'adv@keywealth.co.bw';
select t('11b a plain advisor is refused — advisory scope is team lead and above',
  raises($$select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                                       current_date - 90, current_date)$$, 'not authorised'));

set session "test.email" = 'lead@keywealth.co.bw';
select t('11c the team lead is allowed', res() is not null);

set session "test.email" = 'admin@keywellness.co.bw';
select t('11d an admin is allowed', res() is not null);

select t('11e a nonsensical period is rejected',
  raises($$select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                                       current_date, current_date - 90)$$, 'invalid period'));
select t('11f a missing organisation is rejected',
  raises($$select admin_org_indicators(null, current_date - 90, current_date)$$,
         'organisation is required'));


-- ══════════════════════════════════════════════════════════════
-- 12. The cohort and the six headline indicators
-- ══════════════════════════════════════════════════════════════
select t('12a the cohort is the ten registered members',
  (res()->'cohort'->>'registered')::int = 10);
select t('12b seven of them have assessed',
  (res()->'cohort'->>'assessed')::int = 7);

select t('12c exactly six indicators are on the face of the panel',
  jsonb_array_length(res()->'headline') = 6);

select t('12d over-indebted counts 3 of the 8 with financials — not 3 of 10',
  (ind(res(),'over_indebted')->>'count')::int = 3
  and (ind(res(),'over_indebted')->>'base')::int = 8
  and (ind(res(),'over_indebted')->>'pct')::numeric = 37.5);

select t('12e the four dimension indicators count 4 of the 7 assessed',
  (ind(res(),'no_emergency_buffer')->>'count')::int = 4
  and (ind(res(),'no_emergency_buffer')->>'base')::int = 7
  and (ind(res(),'retirement_shortfall')->>'count')::int = 4
  and (ind(res(),'cover_gap')->>'count')::int = 4
  and (ind(res(),'not_building_wealth')->>'count')::int = 4);

select t('12f living beyond means reads the spending dimension',
  (ind(res(),'living_beyond_means')->>'count')::int = 4
  and (ind(res(),'living_beyond_means')->>'base')::int = 7);

select t('12g the headline keeps the order threshold_config declares',
  (res()->'headline'->0->>'key') = 'over_indebted'
  and (res()->'headline'->1->>'key') = 'no_emergency_buffer'
  and (res()->'headline'->2->>'key') = 'living_beyond_means'
  and (res()->'headline'->3->>'key') = 'retirement_shortfall'
  and (res()->'headline'->4->>'key') = 'cover_gap'
  and (res()->'headline'->5->>'key') = 'not_building_wealth');


-- ══════════════════════════════════════════════════════════════
-- 13. Every figure carries its own base
-- ══════════════════════════════════════════════════════════════
select t('13a negative net worth counts 2 of the 5 with a net-worth figure',
  (ind(res(),'negative_net_worth')->>'count')::int = 2
  and (ind(res(),'negative_net_worth')->>'base')::int = 5);

select t('13b saving under 10% counts 3 of the 6 with a savings figure',
  (ind(res(),'low_savings_rate')->>'count')::int = 3
  and (ind(res(),'low_savings_rate')->>'base')::int = 6);

select t('13c no will counts 3 of the 4 who answered, not 3 of 10',
  (ind(res(),'no_will')->>'count')::int = 3
  and (ind(res(),'no_will')->>'base')::int = 4);

select t('13d the emergency-fund planner is its own base, separate from the dimension',
  (ind(res(),'thin_emergency_months')->>'count')::int = 3
  and (ind(res(),'thin_emergency_months')->>'base')::int = 4);

select t('13e stress uses the most recent reading, so an old spike does not count',
  (ind(res(),'high_financial_stress')->>'count')::int = 2
  and (ind(res(),'high_financial_stress')->>'base')::int = 5);

select t('13f approaching the debt ceiling picks up the one strained member',
  (ind(res(),'dti_strained')->>'count')::int = 1
  and (ind(res(),'dti_strained')->>'base')::int = 8);

select t('13g a base under 5 is marked low_base',
  (ind(res(),'no_will')->>'low_base')::boolean = true);
select t('13h a healthy base is not',
  (ind(res(),'over_indebted')->>'low_base')::boolean = false);


-- ══════════════════════════════════════════════════════════════
-- 14. Movement is reported only where it is real
-- ══════════════════════════════════════════════════════════════
select t('14a a profile-derived indicator reports no movement',
  ind(res(),'over_indebted')->'movement' = 'null'::jsonb
  or ind(res(),'over_indebted')->>'movement' is null);

select t('14b and says why, rather than leaving a silent blank',
  ind(res(),'over_indebted')->>'movement_note' like '%no history%'
  or ind(res(),'over_indebted')->>'movement_note' like '%No history%');

select t('14c an assessment-derived indicator does report movement',
  ind(res(),'no_emergency_buffer')->'movement'->>'previous_base' is not null);

-- Before the period only member 5 had assessed, and badly: 1 of 1 at 100%.
-- Now it is 4 of 7 at 57.1%, so the share improved by 42.9 points.
select t('14d the previous snapshot uses only what was known back then',
  (ind(res(),'no_emergency_buffer')->'movement'->>'previous_count')::int = 1
  and (ind(res(),'no_emergency_buffer')->'movement'->>'previous_base')::int = 1);

select t('14e the delta is computed from the two shares',
  round((ind(res(),'no_emergency_buffer')->'movement'->>'delta_pct')::numeric, 1) = -42.9);

select t('14f the naming trap is defused — the income dimension is relabelled',
  ind(res(),'single_income_reliance')->>'label' = 'Reliance on a single income source');
select t('14g and it is kept out of the headline six',
  ind(res(),'single_income_reliance')->>'placement' = 'library');


-- ══════════════════════════════════════════════════════════════
-- 15. Unit scoping
-- ══════════════════════════════════════════════════════════════
select t('15a scoping to North Site narrows the cohort to its six members',
  (admin_org_indicators('44444444-4444-4444-4444-444444444444',
     current_date - 90, current_date,
     '44440000-0000-0000-0000-000000000001')->'cohort'->>'registered')::int = 6);

select t('15b and the indicator bases narrow with it',
  ((admin_org_indicators('44444444-4444-4444-4444-444444444444',
      current_date - 90, current_date,
      '44440000-0000-0000-0000-000000000001') -> 'headline' -> 0 ->> 'base')::int) = 6);

select t('15c the unit label comes through for the report header',
  (admin_org_indicators('44444444-4444-4444-4444-444444444444',
     current_date - 90, current_date,
     '44440000-0000-0000-0000-000000000001')->>'unit_label') = 'North Site');


-- ══════════════════════════════════════════════════════════════
-- 16. Internal vs client-safe
-- ══════════════════════════════════════════════════════════════
select t('16a internally, a low-base figure is still shown',
  (ind(res(),'no_will')->>'count')::int = 3);

select t('16b client-safe blanks that same figure',
  (select (ind(r,'no_will')->>'count') is null and (ind(r,'no_will')->>'suppressed')::boolean
     from (select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                    current_date - 90, current_date, null, true) as r) x));

select t('16c but keeps the ones with a healthy base',
  (select (ind(r,'over_indebted')->>'count')::int = 3
     from (select admin_org_indicators('44444444-4444-4444-4444-444444444444',
                    current_date - 90, current_date, null, true) as r) x));

select t('16d an organisation below the floor is hidden entirely in client-safe output',
  (select (r->>'suppressed')::boolean
     from (select admin_org_indicators('11111111-1111-1111-1111-111111111111',
                    current_date - 90, current_date, null, true) as r) x));

select t('16e and is still readable internally',
  (select (r->>'suppressed')::boolean = false
     from (select admin_org_indicators('11111111-1111-1111-1111-111111111111',
                    current_date - 90, current_date) as r) x));


-- ══════════════════════════════════════════════════════════════
-- 17. Definitions follow threshold_config, not hard-coded numbers
-- ══════════════════════════════════════════════════════════════
-- Raising the dimension floor to 90 must reclassify the 80-scorers.
update threshold_config set value = to_jsonb(90) where key = 'indicator.dimension_flag_below';
select t('17a raising the dimension floor changes the counts',
  (ind(res(),'no_emergency_buffer')->>'count')::int = 7);
update threshold_config set value = to_jsonb(40) where key = 'indicator.dimension_flag_below';
select t('17b and putting it back restores them',
  (ind(res(),'no_emergency_buffer')->>'count')::int = 4);

-- The DTI band edges are the same ones the advisor portal reads.
update threshold_config
   set value = jsonb_set(value, '{bands,3,max}', 'null')
 where key = 'indicator.dti';
select t('17c over-indebted follows the shared DTI definition',
  (ind(res(),'over_indebted')->>'count')::int = 3);

select t('17d every indicator states its definition in plain English',
  not exists (select 1 from jsonb_array_elements(
                            coalesce(res()->'headline','[]'::jsonb) ||
                            coalesce(res()->'library','[]'::jsonb)) r
               where coalesce(r->>'definition','') = ''));

select t('17e and names the source it was computed from',
  not exists (select 1 from jsonb_array_elements(
                            coalesce(res()->'headline','[]'::jsonb) ||
                            coalesce(res()->'library','[]'::jsonb)) r
               where r->>'source' not in ('assessment','profile','planner','stress_log')));

\echo ''
\echo '  All Phase 1 tests passed.'
\echo ''
