-- ============================================================
-- Key Wellness — deleting an account: assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-delete-user.sh, after m5-fixture + m5a-fixture-extra +
-- supabase_support_audit.sql + delete-user-fixture-extra.sql and the
-- migration itself.
--
-- The order is deliberate and the phases are NOT independent: A proves the
-- refusals while everything still exists, C deletes a member, D deletes a
-- staff account. Re-ordering them will fail.
--
-- Lone (...009) is the acting admin throughout. She is an admin, she is not
-- either target, and she is the default recipient of every reassignment.
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant insert, select on _r to authenticated;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, p_ok, p_detail); end $$;

-- Records whether a call raised, and what it said. Every refusal in this
-- feature is an exception, so most assertions are shaped like this.
create or replace function _raises(p_name text, p_sql text, p_match text)
returns void language plpgsql as $$
declare v_msg text;
begin
  execute p_sql;
  insert into _r values (p_name, false, 'did NOT raise');
exception when others then
  v_msg := sqlerrm;
  insert into _r values (p_name, v_msg ~* p_match, v_msg);
end $$;

set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

-- Shorthands for the three accounts these assertions name repeatedly.
\set member  '''00000000-0000-0000-0000-00000000000e'''
\set naledi  '''00000000-0000-0000-0000-000000000011'''
\set zex     '''00000000-0000-0000-0000-000000000013'''
\set lone    '''00000000-0000-0000-0000-000000000009'''


-- ══ 1–9 · The preview, before anything is destroyed ═════════

select _chk('1  preview finds the member and returns their address',
  (admin_user_delete_preview(:member::uuid) ->> 'email') = 'member@example.test');

select _chk('2  a booking is member data, so it is deleted outright',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:member::uuid) -> 'refs') r
           where r->>'table' = 'bookings' and r->>'column' = 'user_id'
             and r->>'mode' = 'member' and (r->>'n')::int = 1));

select _chk('3  assessments are reported as the database''s own cascade, not the plan''s work',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:member::uuid) -> 'refs') r
           where r->>'table' = 'assessments' and r->>'mode' = 'auto-delete'));

select _chk('4  a counselling caseload is unlinked, never deleted',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:member::uuid) -> 'refs') r
           where r->>'table' = 'counsellor_clients' and r->>'mode' = 'unlink'));

select _chk('5  tool_data has no foreign key at all and is still found',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:member::uuid) -> 'refs') r
           where r->>'table' = 'tool_data' and r->>'rule' = 'x' and r->>'mode' = 'member'));

select _chk('6  what a staff account authored is reassigned',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:naledi::uuid) -> 'refs') r
           where r->>'table' = 'org_reports' and r->>'column' = 'created_by'
             and r->>'mode' = 'reassign'));

select _chk('7  every role Naledi holds is listed, by user_id and by email alike',
  (select count(*) from jsonb_array_elements_text(
      admin_user_delete_preview(:naledi::uuid) -> 'roles') x
    where x in ('admin','hr','advisor','counsellor','psychosocial_admin','member')) = 6);

select _chk('8  your own account is refused, in the preview as well as the RPC',
  (select count(*) from jsonb_array_elements_text(
      admin_user_delete_preview(:lone::uuid) -> 'blockers') b
    where b ~* 'your own account') = 1);

-- The account that never finished onboarding: no profiles row, so it never
-- appears in the users table. Finding it by address is the whole reason the
-- preview takes an email.
select _chk('9  an account with no profile is found by address',
  (admin_user_delete_preview(null, 'orphan@example.test') ->> 'user_id')
    = '00000000-0000-0000-0000-000000000012'
  and (admin_user_delete_preview(null, 'orphan@example.test') -> 'roles') = '[]'::jsonb);

select _chk('10 an address nobody holds returns not-found, not an error',
  (admin_user_delete_preview(null, 'nobody@example.test') ->> 'ok') = 'false');


-- ══ 11–16 · The refusals ═══════════════════════════════════

select _raises('11 the confirmation address must match',
  format('select admin_user_delete(%L::uuid, %L)', :member, 'wrong@example.test'),
  'confirmation email does not match');

select _raises('12 you cannot delete your own account',
  format('select admin_user_delete(%L::uuid, %L)', :lone, 'lone@keywellness.co.bw'),
  'own account');

select _raises('13 records cannot be reassigned to the account being deleted',
  format('select admin_user_delete(%L::uuid, %L, %L::uuid)',
         :member, 'member@example.test', :member),
  'to itself');

select _raises('14 an id that is not an account is refused',
  'select admin_user_delete(''00000000-0000-0000-0000-0000000000ff''::uuid, ''x@y.test'')',
  'no account with that id');

select _raises('15 reassigning to an account that does not exist is refused',
  format('select admin_user_delete(%L::uuid, %L, ''00000000-0000-0000-0000-0000000000ff''::uuid)',
         :member, 'member@example.test'),
  'does not exist');

-- The gate. A member holds no admin row, so is_admin() is false and both
-- entry points must refuse — the preview leaks the account's whole shape, so
-- it is gated exactly as hard as the delete.
do $$
begin
  perform set_config('test.email', 'member@example.test', false);
  perform set_config('test.uid',   '00000000-0000-0000-0000-00000000000e', false);
end $$;

select _raises('16 a member cannot call the delete',
  format('select admin_user_delete(%L::uuid, %L)', :naledi, 'naledi@keywellness.test'),
  'not authorised');

select _raises('17 a member cannot call the preview either',
  format('select admin_user_delete_preview(%L::uuid)', :naledi),
  'not authorised');

do $$
begin
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  perform set_config('test.uid',   '00000000-0000-0000-0000-000000000009', false);
end $$;


-- ══ 18–20 · An unclassified reference stops everything ═════
-- The safe default, and the assertion that matters most for the future: a
-- table added next year with a key to auth.users must BLOCK the delete rather
-- than be silently skipped.

create table _future_thing (
  id      bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id)
);
insert into _future_thing (user_id) values (:zex::uuid);

select _chk('18 an unknown reference is reported as UNCLASSIFIED, not guessed at',
  exists (select 1 from jsonb_array_elements(admin_user_delete_preview(:zex::uuid) -> 'refs') r
           where r->>'table' = '_future_thing' and r->>'mode' = 'UNCLASSIFIED'));

select _chk('19 and it appears as a blocker naming the column',
  (select count(*) from jsonb_array_elements_text(
      admin_user_delete_preview(:zex::uuid) -> 'blockers') b
    where b ~* '_future_thing.user_id') = 1);

select _raises('20 the delete refuses rather than hitting a key violation',
  format('select admin_user_delete(%L::uuid, %L)', :zex, 'zex@example.test'),
  'unclassified reference');

select _chk('21 and nothing was written before it refused',
  (select count(*) from auth.users where id = :zex::uuid) = 1
  and (select count(*) from bookings where user_id = :zex::uuid) = 1);

drop table _future_thing;


-- ══ 22–34 · Deleting a member ══════════════════════════════

select _chk('22 the delete reports success',
  (admin_user_delete(:member::uuid, 'MEMBER@Example.Test') ->> 'ok') = 'true');
-- (the address is typed back in the wrong case on purpose — matching is
--  case-insensitive, because nobody types their own address in lower case)

select _chk('23 the account is gone',
  (select count(*) from auth.users where id = :member::uuid) = 0);

select _chk('24 the profile went with it, through its own cascade',
  (select count(*) from profiles where id = :member::uuid) = 0);

select _chk('25 assessments, badges, check-ins and tool events all cascaded',
  (select count(*) from assessments       where user_id = :member::uuid) = 0
  and (select count(*) from badges        where user_id = :member::uuid) = 0
  and (select count(*) from checkins      where user_id = :member::uuid) = 0
  and (select count(*) from tool_usage_events where user_id = :member::uuid) = 0);

-- The two tables with no foreign key. Nothing in the database would have
-- removed these; if the plan forgets them they orphan in silence.
select _chk('26 tool_data was deleted although no key required it',
  (select count(*) from tool_data where user_id = :member::uuid) = 0);

select _chk('27 ai_chat_usage likewise',
  (select count(*) from ai_chat_usage where user_id = :member::uuid) = 0);

select _chk('28 their bookings were deleted',
  (select count(*) from bookings where user_id = :member::uuid) = 0);

select _chk('29 their reward fulfilments were deleted',
  (select count(*) from reward_fulfilments where user_id = :member::uuid) = 0);

-- The caseloads. Both rows must still exist: an account deletion is not a
-- clinical record deletion.
select _chk('30 the advisory caseload row survives, unlinked by its own key',
  (select count(*) from advisor_clients
    where email = 'member@example.test' and member_user_id is null) = 1);

select _chk('31 the counselling caseload row survives, unlinked by the plan',
  (select count(*) from counsellor_clients
    where email = 'member@example.test' and member_user_id is null) = 1);

select _chk('32 the support entry about them survives, holding the address',
  (select count(*) from support_actions
    where action = 'send_password_reset'
      and target_user is null
      and target_email = 'member@example.test') = 1);

select _chk('33 the deletion itself is recorded, by address, against the admin who did it',
  (select count(*) from support_actions
    where action = 'delete_user' and outcome = 'ok'
      and target_email = 'member@example.test'
      and target_user is null
      and actor = :lone::uuid) = 1);

select _chk('34 the other member was not touched',
  (select count(*) from auth.users where id = :zex::uuid) = 1
  and (select count(*) from tool_data where user_id = :zex::uuid) = 1
  and (select count(*) from bookings where user_id = :zex::uuid) = 1);


-- ══ 35–48 · Deleting a staff account ═══════════════════════

select _chk('35 the staff delete reports success and names the recipient',
  (admin_user_delete(:naledi::uuid, 'naledi@keywellness.test') ->> 'reassigned_to')
    = 'lone@keywellness.co.bw');

select _chk('36 the account is gone',
  (select count(*) from auth.users where id = :naledi::uuid) = 0);

-- Every role, cleared. admins / employers / hr_unit_scope / psychosocial_admins
-- are keyed by email as well as by user_id, and an FK sweep cannot see that.
select _chk('37 the admin grant is gone, and the other two admins are not',
  (select count(*) from admins where lower(email) = 'naledi@keywellness.test') = 0
  and (select count(*) from admins) = 2);

select _chk('38 the HR grant and its unit scope are gone',
  (select count(*) from employers    where lower(email)    = 'naledi@keywellness.test') = 0
  and (select count(*) from hr_unit_scope where lower(hr_email) = 'naledi@keywellness.test') = 0);

select _chk('39 the psychosocial admin grant is gone',
  (select count(*) from psychosocial_admins
    where lower(email) = 'naledi@keywellness.test') = 0);

-- Rosters are closed, not deleted: the row anchors a caseload and its notes.
-- is_active false AND user_id null together are what stop a future account on
-- the same address from inheriting the role.
select _chk('40 the advisor roster row is kept, closed, and unlinked',
  (select count(*) from advisors
    where lower(email) = 'naledi@keywellness.test'
      and is_active = false and user_id is null) = 1);

select _chk('41 the counsellor roster row likewise',
  (select count(*) from counsellors
    where lower(email) = 'naledi@keywellness.test'
      and is_active = false and user_id is null) = 1);

select _chk('42 their counselling caseload survives the counsellor being deleted',
  (select count(*) from counsellor_clients) = 1);

-- Everything they authored now names the admin who did the deleting. NOT NULL
-- columns (actions.owner, actions.created_by, meetings.created_by,
-- org_reports.created_by, org_headcount_reports.reported_by) have no other
-- possible answer — nulling them is not available.
select _chk('43 actions they owned and raised both move',
  (select count(*) from actions
    where owner = :lone::uuid and created_by = :lone::uuid) = 1);

select _chk('44 meetings they convened move',
  (select count(*) from meetings where created_by = :lone::uuid) = 1);

select _chk('45 work plans, contracts and billing handovers move',
  (select count(*) from work_plans where authored_by = :lone::uuid) = 1
  and (select count(*) from org_contracts
        where created_by = :lone::uuid and account_manager = :lone::uuid) = 1
  and (select count(*) from billing_handovers
        where prepared_by = :lone::uuid and invoice_confirmed_by = :lone::uuid) = 1);

select _chk('46 a published report keeps both its author and its publisher',
  (select count(*) from org_reports
    where created_by = :lone::uuid and published_by = :lone::uuid
      and status = 'published') = 1);

select _chk('47 headcount reports move although no key held them',
  (select count(*) from org_headcount_reports where reported_by = :lone::uuid) = 1);

select _chk('48 program activities move',
  (select count(*) from program_activities where created_by = :lone::uuid) = 1);

-- Who confirmed a member turned up is an audit trail on somebody else's
-- record. It is repointed, never nulled — see the France script, which made
-- the same call by hand for the same reason.
select _chk('49 attendance confirmations are repointed, not erased',
  (select count(*) from bookings
    where user_id = :zex::uuid and attendance_confirmed_by = :lone::uuid) = 1);

select _chk('50 who added an advisor is repointed too',
  (select count(*) from advisors
    where lower(email) = 'kefilwe@keywealth.co.bw' and created_by = :lone::uuid) = 1);

select _chk('51 who fulfilled a reward is repointed',
  (select count(*) from reward_fulfilments
    where user_id = :zex::uuid and fulfilled_by = :lone::uuid) = 1);


-- ══ 52–55 · The support trail keeps its identities ═════════

select _chk('52 their audit entries survive with the uuid dropped',
  (select count(*) from support_actions
    where actor is null and actor_email = 'naledi@keywellness.test') = 2);

select _chk('53 nothing amended or removed an audit row — both are still there',
  (select count(*) from support_actions where action in ('lookup','send_password_reset')) = 2);

select _chk('54 support_recent() reads the stored address once the account is gone',
  exists (select 1 from jsonb_array_elements(support_recent(50)) e
           where e->>'actor' = 'naledi@keywellness.test'));

select _chk('55 no reference to either deleted account is left anywhere',
  (select count(*) from _admin_user_refs(:naledi::uuid)) = 0
  and (select count(*) from _admin_user_refs(:member::uuid)) = 0);


-- ══ 56–58 · Reachability ═══════════════════════════════════
-- CLAUDE.md's rule: PUBLIC holds EXECUTE on a new function until it is
-- revoked, and SECURITY DEFINER runs as postgres. An ungated helper that
-- counts rows for any uuid is a public read of the whole schema.

select _chk('56 _admin_user_refs is not reachable with the anon key',
  has_function_privilege('anon', '_admin_user_refs(uuid)', 'EXECUTE') = false
  and has_function_privilege('authenticated', '_admin_user_refs(uuid)', 'EXECUTE') = false);

select _chk('57 _admin_user_delete_plan is not reachable either',
  has_function_privilege('anon', '_admin_user_delete_plan()', 'EXECUTE') = false
  and has_function_privilege('authenticated', '_admin_user_delete_plan()', 'EXECUTE') = false);

select _chk('58 both entry points ARE reachable — they carry their own gate',
  has_function_privilege('authenticated', 'admin_user_delete(uuid, text, uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'admin_user_delete_preview(uuid, text)', 'EXECUTE'));


-- ══ Summary ════════════════════════════════════════════════

select case when ok then 'PASS  ' else 'FAIL  ' end || name
       || coalesce('   [' || detail || ']', '')
  from _r order by name;

do $$
declare n_fail int; n_all int;
begin
  select count(*) filter (where not ok), count(*) into n_fail, n_all from _r;
  if n_fail > 0 then
    raise exception 'delete-user: % of % assertions FAILED', n_fail, n_all;
  end if;
  raise notice 'delete-user: all % assertions passed', n_all;
end $$;
