-- Key Wellness — Phase 0a assertions (picker options + member-add paths).
--
-- psql ONLY. Uses psql meta-commands and seeds throwaway data. It will NOT
-- run in the Supabase SQL editor and must never touch the live database.
--
-- Run it with: tests/run-phase0.sh  (it runs after the Phase 0 assertions)
\set ON_ERROR_STOP on
\pset pager off

-- ── Extra seed on top of the Phase 0 fixture ─────────────────
-- A closed company with an active site under it: the site must be
-- invisible, exactly as it is in the member picker.
insert into org_units (id, org_id, parent_unit_id, name, is_active) values
  ('aaaaaaaa-0000-0000-0000-0000000000f1','22222222-2222-2222-2222-222222222222', null, 'Closed Co', false),
  ('aaaaaaaa-0000-0000-0000-0000000000f2','22222222-2222-2222-2222-222222222222',
   'aaaaaaaa-0000-0000-0000-0000000000f1','Orphan Site', true);

-- A closed organisation must not be offered at all.
insert into organizations (id, name, invite_code, is_active)
  values ('33333333-3333-3333-3333-333333333333','Lapsed Client','LAPS-0001', false);

-- A member who signed up but never entered an invite code.
insert into auth.users (id, email)
  values ('dddddddd-0000-0000-0000-00000000000a','orgless@example.com');
insert into profiles (id, first_name) values ('dddddddd-0000-0000-0000-00000000000a','Orgless');

set session "test.email" = 'adv@keywealth.co.bw';


-- ══════════════════════════════════════════════════════════════
-- 9. The picker has something to show
-- ══════════════════════════════════════════════════════════════
select t('9a  an advisor can read the options at all',
  jsonb_typeof(advisor_org_options()) = 'array');

select t('9b  only active organisations are offered',
  not exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o
     where o->>'name' = 'Lapsed Client'));

select t('9c  active organisations are all present',
  (select count(*) from jsonb_array_elements(advisor_org_options())) = 2);

select t('9d  a company that has sites is not itself selectable',
  not exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o,
                  jsonb_array_elements(o->'units') u
     where u->>'id' = 'aaaaaaaa-0000-0000-0000-000000000001'));

select t('9e  its sites are selectable',
  exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o,
                  jsonb_array_elements(o->'units') u
     where u->>'id' = 'aaaaaaaa-0000-0000-0000-000000000002'));

select t('9f  a closed site is not offered',
  not exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o,
                  jsonb_array_elements(o->'units') u
     where u->>'id' = 'aaaaaaaa-0000-0000-0000-000000000003'));

select t('9g  an active site under a CLOSED company is not offered',
  not exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o,
                  jsonb_array_elements(o->'units') u
     where u->>'id' = 'aaaaaaaa-0000-0000-0000-0000000000f2'));

select t('9h  units carry the company — site label',
  exists (
    select 1 from jsonb_array_elements(advisor_org_options()) o,
                  jsonb_array_elements(o->'units') u
     where u->>'label' = 'Head Office Co — Gaborone'));

select t('9i  an organisation with no units offers an empty list, not null',
  (select jsonb_typeof(o->'units')
     from jsonb_array_elements(advisor_org_options()) o
    where o->>'name' = 'BOPEU') = 'array');

-- Every option the picker offers must actually be insertable. This is the
-- assertion that catches a picker drifting away from the constraint.
do $$
declare r record; v_id uuid;
begin
  for r in
    select (o->>'org_id')::uuid as org_id, (u->>'id')::uuid as unit_id
      from jsonb_array_elements(advisor_org_options()) o,
           jsonb_array_elements(o->'units') u
  loop
    insert into advisor_clients (advisor_id, first_name, org_id, org_unit_id)
    values ('cccccccc-0000-0000-0000-000000000001','Probe', r.org_id, r.unit_id)
    returning id into v_id;
    delete from advisor_clients where id = v_id;
  end loop;
end $$;
select t('9j  every offered organisation/site combination is insertable', true);

set session "test.email" = 'nobody@example.com';
select t('9k  a signed-in non-advisor is refused',
  raises($$select advisor_org_options()$$, 'not authorised'));
set session "test.email" = 'adv@keywealth.co.bw';


-- ══════════════════════════════════════════════════════════════
-- 10. Adding an existing portal member who has no organisation
-- ══════════════════════════════════════════════════════════════
select t('10a adding an org-less member no longer raises',
  advisor_add_member_client('dddddddd-0000-0000-0000-00000000000a') is not null);

select t('10b  it is recorded as a private client, not silently unattributed',
  (select no_org and org_id is null
     from advisor_clients
    where member_user_id = 'dddddddd-0000-0000-0000-00000000000a'));

select t('10c  the call is still idempotent',
  (select count(*) from advisor_clients
    where member_user_id = 'dddddddd-0000-0000-0000-00000000000a') = 1
  and advisor_add_member_client('dddddddd-0000-0000-0000-00000000000a') is not null
  and (select count(*) from advisor_clients
        where member_user_id = 'dddddddd-0000-0000-0000-00000000000a') = 1);

-- The self-correction that means nobody has to clean this up by hand.
update profiles
   set org_id = '11111111-1111-1111-1111-111111111111'
 where id = 'dddddddd-0000-0000-0000-00000000000a';

select t('10d  entering an invite code later attributes them automatically',
  (select org_id = '11111111-1111-1111-1111-111111111111' and not no_org
     from advisor_clients
    where member_user_id = 'dddddddd-0000-0000-0000-00000000000a'));

-- Same fix on the admin path.
insert into auth.users (id, email) values ('dddddddd-0000-0000-0000-00000000000b','orgless2@example.com');
insert into profiles (id, first_name) values ('dddddddd-0000-0000-0000-00000000000b','Orgless2');
set session "test.email" = 'admin@keywellness.co.bw';

select t('10e  admin assigning an org-less member no longer raises',
  admin_assign_client('cccccccc-0000-0000-0000-000000000002',
                      'dddddddd-0000-0000-0000-00000000000b') is not null);
select t('10f  and is recorded as a private client',
  (select no_org from advisor_clients
    where member_user_id = 'dddddddd-0000-0000-0000-00000000000b'));

-- A member who DOES have an organisation must still inherit it and its
-- site — the fix must not have turned everyone into a private client.
-- Assign first, assert second: an OR across two subqueries would leave
-- the evaluation order to the planner, which is how this test failed the
-- first time it was written.
select admin_assign_client('cccccccc-0000-0000-0000-000000000002',
                           'dddddddd-0000-0000-0000-000000000001') as assigned;

select t('10g  a member with an organisation still inherits org and site',
  (select ac.org_id      = '22222222-2222-2222-2222-222222222222'
      and ac.org_unit_id = 'aaaaaaaa-0000-0000-0000-000000000002'
      and not ac.no_org
     from advisor_clients ac
    where ac.member_user_id = 'dddddddd-0000-0000-0000-000000000001'
      and ac.advisor_id     = 'cccccccc-0000-0000-0000-000000000002'));

\echo ''
\echo '  All Phase 0a tests passed.'
\echo ''
