-- Key Wellness — Phase 0 assertions.
--
-- psql ONLY. This file uses psql meta-commands (\set, \pset, \echo) and seeds
-- throwaway test data. It will NOT run in the Supabase SQL editor, and must
-- never be run against the live database.
--
-- Run it with: tests/run-phase0.sh
-- To verify the LIVE database after applying the migration, use
-- tests/phase0-verify-live.sql instead.
\set ON_ERROR_STOP on
\pset pager off

create or replace function t(p_name text, p_pass boolean) returns void
language plpgsql as $$
begin
  if p_pass then raise notice 'PASS  %', p_name;
  else raise exception 'FAIL  %', p_name; end if;
end $$;

create or replace function raises(p_sql text, p_fragment text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return position(lower(p_fragment) in lower(sqlerrm)) > 0;
end $$;

-- ── Seed ──────────────────────────────────────────────────────
insert into admins (email) values ('admin@keywellness.co.bw');

insert into organizations (id, name, invite_code) values
  ('11111111-1111-1111-1111-111111111111','BOPEU','BOPE-6073'),
  ('22222222-2222-2222-2222-222222222222','Sedimosa','S3DI-M185');

-- Sedimosa: a company with two sites, plus a standalone company.
insert into org_units (id, org_id, parent_unit_id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222', null, 'Head Office Co'),
  ('aaaaaaaa-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','Gaborone'),
  ('aaaaaaaa-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','Francistown'),
  ('aaaaaaaa-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222', null, 'Standalone Co'),
  ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111', null, 'BOPEU Main');

update org_units set is_active = false where id = 'aaaaaaaa-0000-0000-0000-000000000003';

insert into advisors (id, email, full_name, is_team_lead) values
  ('cccccccc-0000-0000-0000-000000000001','adv@keywealth.co.bw','Test Advisor', false),
  ('cccccccc-0000-0000-0000-000000000002','lead@keywealth.co.bw','Team Lead', true);

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001','member.sed@example.com'),
  ('dddddddd-0000-0000-0000-000000000002','member.new@example.com'),
  ('dddddddd-0000-0000-0000-000000000003','member.bopeu@example.com');

-- A member already attached to Sedimosa / Gaborone.
insert into profiles (id, org_id, org_unit_id, first_name)
  values ('dddddddd-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
          'aaaaaaaa-0000-0000-0000-000000000002','Sed');
-- A member with no org yet — signed up, no invite code entered.
insert into profiles (id, first_name) values ('dddddddd-0000-0000-0000-000000000002','New');
-- A BOPEU member.
insert into profiles (id, org_id, first_name)
  values ('dddddddd-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Bo');

set session "test.email" = 'adv@keywealth.co.bw';


-- ══════════════════════════════════════════════════════════════
-- 1. The constraint
-- ══════════════════════════════════════════════════════════════
select t('1a  unattributed client with no_org=false is rejected',
  raises($$insert into advisor_clients (advisor_id, first_name, last_name)
           values ('cccccccc-0000-0000-0000-000000000001','No','Org')$$,
         'advisor_clients_org_required'));

insert into advisor_clients (id, advisor_id, first_name, last_name, no_org)
  values ('eeee0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','Private','Client', true);
select t('1b  private client with no_org=true is accepted',
  (select no_org from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000001'));

select t('1c  a unit without an organisation is rejected',
  raises($$insert into advisor_clients (advisor_id, first_name, last_name, no_org, org_unit_id)
           values ('cccccccc-0000-0000-0000-000000000001','Unit','Only', true,
                   'aaaaaaaa-0000-0000-0000-000000000002')$$,
         'without an organisation'));


-- ══════════════════════════════════════════════════════════════
-- 2. Inheritance on insert
-- ══════════════════════════════════════════════════════════════
insert into advisor_clients (id, advisor_id, first_name, email)
  values ('eeee0000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-000000000001',
          'Linked','member.sed@example.com');

select t('2a  linked client inherits org from the member profile',
  (select org_id = '22222222-2222-2222-2222-222222222222'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000002'));
select t('2b  linked client inherits the company/site too',
  (select org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000002'));
select t('2c  inheriting an org clears no_org',
  (select not no_org from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000002'));
select t('2d  a correctly inherited client is not flagged as mismatched',
  (select not org_mismatch from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000002'));


-- ══════════════════════════════════════════════════════════════
-- 3. Mismatch is flagged, never overwritten
-- ══════════════════════════════════════════════════════════════
insert into advisor_clients (id, advisor_id, first_name, email, org_id)
  values ('eeee0000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-000000000001',
          'Wrong','member.bopeu@example.com','22222222-2222-2222-2222-222222222222');

select t('3a  disagreeing org sets the mismatch flag',
  (select org_mismatch from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000003'));
select t('3b  the advisor-entered org is preserved, not overwritten',
  (select org_id = '22222222-2222-2222-2222-222222222222'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000003'));


-- ══════════════════════════════════════════════════════════════
-- 4. The member gains an org later (invite code entered)
-- ══════════════════════════════════════════════════════════════
insert into advisor_clients (id, advisor_id, first_name, email, no_org)
  values ('eeee0000-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-000000000001',
          'Later','member.new@example.com', true);

select t('4a  client of an org-less member starts unattributed',
  (select org_id is null and no_org
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000004'));

update profiles
   set org_id = '22222222-2222-2222-2222-222222222222',
       org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000002'
 where id = 'dddddddd-0000-0000-0000-000000000002';

select t('4b  the client picks up the org when the member joins one',
  (select org_id = '22222222-2222-2222-2222-222222222222'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000004'));
select t('4c  and the site with it',
  (select org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000004'));
select t('4d  and no_org is cleared',
  (select not no_org from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000004'));

-- An admin moving a member between organisations must not be blocked,
-- and must raise the flag on the advisor record rather than rewrite it.
update profiles set org_id = '11111111-1111-1111-1111-111111111111', org_unit_id = null
 where id = 'dddddddd-0000-0000-0000-000000000002';
select t('4e  moving the member flags the disagreement without overwriting',
  (select org_mismatch and org_id = '22222222-2222-2222-2222-222222222222'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000004'));


-- ══════════════════════════════════════════════════════════════
-- 5. The company → site rule
-- ══════════════════════════════════════════════════════════════
select t('5a  a site of another organisation is rejected',
  raises($$insert into advisor_clients (advisor_id, first_name, org_id, org_unit_id)
           values ('cccccccc-0000-0000-0000-000000000001','X',
                   '11111111-1111-1111-1111-111111111111',
                   'aaaaaaaa-0000-0000-0000-000000000002')$$,
         'does not belong to organisation'));

select t('5b  a company that has sites is rejected — pick the site',
  raises($$insert into advisor_clients (advisor_id, first_name, org_id, org_unit_id)
           values ('cccccccc-0000-0000-0000-000000000001','X',
                   '22222222-2222-2222-2222-222222222222',
                   'aaaaaaaa-0000-0000-0000-000000000001')$$,
         'company with sites'));

select t('5c  a closed unit is rejected',
  raises($$insert into advisor_clients (advisor_id, first_name, org_id, org_unit_id)
           values ('cccccccc-0000-0000-0000-000000000001','X',
                   '22222222-2222-2222-2222-222222222222',
                   'aaaaaaaa-0000-0000-0000-000000000003')$$,
         'is closed'));

select t('5d  a unit that does not exist is rejected',
  raises($$insert into advisor_clients (advisor_id, first_name, org_id, org_unit_id)
           values ('cccccccc-0000-0000-0000-000000000001','X',
                   '22222222-2222-2222-2222-222222222222',
                   'ffffffff-0000-0000-0000-00000000ffff')$$,
         'does not exist'));

insert into advisor_clients (id, advisor_id, first_name, org_id, org_unit_id)
  values ('eeee0000-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-000000000001',
          'Standalone','22222222-2222-2222-2222-222222222222',
          'aaaaaaaa-0000-0000-0000-000000000004');
select t('5e  a standalone company with no sites is a valid leaf',
  (select org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000004'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000005'));

-- The trap this guards: the company later gains a site, so the unit that
-- was a leaf when it was chosen is now a parent. Editing anything else on
-- that row must still work.
insert into org_units (id, org_id, parent_unit_id, name)
  values ('aaaaaaaa-0000-0000-0000-000000000005','22222222-2222-2222-2222-222222222222',
          'aaaaaaaa-0000-0000-0000-000000000004','New Site');

update advisor_clients set phone = '+267 71 000 000'
 where id = 'eeee0000-0000-0000-0000-000000000005';
select t('5f  an unrelated edit is not blocked when the unit later gains sites',
  (select phone = '+267 71 000 000'
     from advisor_clients where id = 'eeee0000-0000-0000-0000-000000000005'));

select t('5g  but re-selecting that now-parent unit is rejected',
  raises($$update advisor_clients
              set org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000004'
            where id = 'eeee0000-0000-0000-0000-000000000002'$$,
         'company with sites'));


-- ══════════════════════════════════════════════════════════════
-- 6. One definition of over-indebted
-- ══════════════════════════════════════════════════════════════
select t('6a  DTI 12% bands healthy',       kw_dti_band(12.0)  = 'healthy');
select t('6b  DTI 28% bands manageable',    kw_dti_band(28.0)  = 'manageable');
select t('6c  DTI 41% bands strained',      kw_dti_band(41.0)  = 'strained');
select t('6d  DTI 46% bands over-indebted', kw_dti_band(46.0)  = 'over_indebted');
select t('6e  DTI 81.3% bands over-indebted (live record)', kw_dti_band(81.3) = 'over_indebted');
-- The boundary is inclusive at the top: exactly 45.0 flags, matching what
-- org_financial_indicators() has always done and every figure published
-- from it. 44.9 must not flag.
select t('6f  exactly 45.0 flags (matches org_financial_indicators)',
  kw_dti_band(45.0) = 'over_indebted');
select t('6f2 44.9 does not flag', kw_dti_band(44.9) = 'strained');
select t('6f3 the band labels state the boundary they actually use',
  (kw_threshold('indicator.dti') -> 'bands' -> 3 ->> 'label') like '%45%+%');
select t('6g  null DTI bands to null',      kw_dti_band(null) is null);

select t('6h  50% is over-indebted — the reading that changes on the advisor screen',
  kw_is_over_indebted(50.0));
select t('6i  33.4% is not flagged (live record)', not kw_is_over_indebted(33.4));

select t('6j  the four live consultation DTIs give 2 of 4 flagged',
  (select count(*) from (values (81.3),(64.7),(33.4),(25.2)) v(d)
    where kw_is_over_indebted(d)) = 2);

select t('6k  thresholds are readable as data',
  (kw_threshold('indicator.dimension_flag_below'))::int = 40
  and (kw_threshold('indicator.high_cost_credit_rate'))::int = 20
  and (kw_threshold('indicator.low_base'))::int = 5);

select t('6l  the six headline indicators are recorded in fixed order',
  jsonb_array_length(kw_threshold('panel3.headline') -> 'row_1') = 3
  and jsonb_array_length(kw_threshold('panel3.headline') -> 'row_2') = 3
  and (kw_threshold('panel3.headline') -> 'row_1' ->> 0) = 'over_indebted');

-- The bands must stay changeable in one place.
update threshold_config
   set value = jsonb_set(value, '{bands,3,max}', 'null')
 where key = 'indicator.dti';
select t('6m  banding follows the config, not hard-coded numbers',
  kw_dti_band(99.0) = 'over_indebted');


-- ══════════════════════════════════════════════════════════════
-- 7. The attribution queue
-- ══════════════════════════════════════════════════════════════
set session "test.email" = 'admin@keywellness.co.bw';
select t('7a  admin sees the private clients',
  (admin_attribution_queue() ->> 'no_org_count')::int >= 1);
select t('7b  admin sees the mismatches',
  (admin_attribution_queue() ->> 'mismatch_count')::int >= 2);
select t('7c  each mismatch names both organisations',
  (admin_attribution_queue() -> 'mismatched' -> 0 ->> 'advisor_org') is not null);

set session "test.email" = 'adv@keywealth.co.bw';
select t('7d  a non-admin advisor is refused',
  raises($$select admin_attribution_queue()$$, 'not authorised'));


-- ══════════════════════════════════════════════════════════════
-- 8. The advisor portal sees the new fields
-- ══════════════════════════════════════════════════════════════
select t('8a  advisor_clients_list carries the attribution fields',
  (select (advisor_clients_list() -> 0) ? 'org_unit_id'
      and (advisor_clients_list() -> 0) ? 'unit_label'
      and (advisor_clients_list() -> 0) ? 'no_org'
      and (advisor_clients_list() -> 0) ? 'org_mismatch'));

select t('8b  the unit label reads company — site',
  kw_unit_label('aaaaaaaa-0000-0000-0000-000000000002') = 'Head Office Co — Gaborone');
select t('8c  a standalone company labels as itself',
  kw_unit_label('bbbbbbbb-0000-0000-0000-000000000001') = 'BOPEU Main');
select t('8d  no unit labels as null', kw_unit_label(null) is null);

select t('8e  an advisor still sees their own caseload',
  jsonb_array_length(advisor_clients_list()) >= 4);

\echo ''
\echo '  All Phase 0 tests passed.'
\echo ''
