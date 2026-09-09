-- ============================================================
-- Key Wellness — member-invites assertions (psql only; tests/run-member-invites.sh)
-- Uses \set / \echo — DO NOT paste into the Supabase editor.
-- ============================================================
\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

create or replace function t_assert(p_ok boolean, p_name text) returns void language plpgsql as $$
begin
  if coalesce(p_ok, false) then raise notice 'PASS  %', p_name;
  else raise exception 'FAIL  %', p_name; end if;
end $$;

\set admin_uid   '''00000000-0000-0000-0000-00000000a001'''
\set sedimosa    '''00000000-0000-0000-0000-0000000000f1'''
\set bopeu       '''00000000-0000-0000-0000-0000000000f2'''
\set debswana    '''00000000-0000-0000-0000-0000000000e1'''
\set jwaneng     '''00000000-0000-0000-0000-0000000000e2'''
\set mcm         '''00000000-0000-0000-0000-0000000000e3'''
\set mining      '''00000000-0000-0000-0000-0000000000d1'''

-- ── 1. Gate ─────────────────────────────────────────────────
set test.uid = '';
set test.email = '';
do $$ begin
  begin
    perform invite_stage('00000000-0000-0000-0000-0000000000f1', null, '[{"email":"a@b.co"}]');
    perform t_assert(false, '1a unauthenticated caller refused');
  exception when others then
    perform t_assert(sqlerrm = 'not authorised', '1a unauthenticated caller refused (' || sqlerrm || ')');
  end;
end $$;

set test.uid = '00000000-0000-0000-0000-00000000b001';
set test.email = 'existing@mcm.test';
do $$ begin
  begin
    perform invite_stage('00000000-0000-0000-0000-0000000000f1', null, '[{"email":"a@b.co"}]');
    perform t_assert(false, '1b non-admin member refused');
  exception when others then
    perform t_assert(sqlerrm = 'not authorised', '1b non-admin member refused');
  end;
  perform t_assert((support_can('send_invite') ->> 'allowed') = 'false', '1c support_can(send_invite) says no to a member');
end $$;

-- ── 2. Staging ──────────────────────────────────────────────
set test.uid = '00000000-0000-0000-0000-00000000a001';
set test.email = 'lone@keywellness.test';

do $$
declare r jsonb;
begin
  r := invite_stage('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e3', $j$[
    {"first_name":"Pitso","last_name":"Isake","email":"Isake77@Gmail.com ","department":"Mining"},
    {"first_name":"Ronnie","last_name":"Tsele","email":"ronnietsele@gmail.com","department":"engineering"},
    {"first_name":"Thuso","last_name":"Thobogang","email":"","department":"Mining"},
    {"first_name":"Dup","last_name":"Licate","email":"isake77@gmail.com","department":"Mining"},
    {"first_name":"Al","last_name":"Ready","email":"existing@mcm.test","department":"Mining"},
    {"first_name":"Odd","last_name":"Dept","email":"odd@mcm.test","department":"Catering"}
  ]$j$);

  perform t_assert(jsonb_array_length(r) = 6, '2a one result per input row, in order');
  perform t_assert(r->0->>'status' = 'staged' and r->0->>'email' = 'isake77@gmail.com',
                   '2b address lower-cased and trimmed, row staged');
  perform t_assert((r->0->>'department_id')::uuid = '00000000-0000-0000-0000-0000000000d1',
                   '2c department matched by name');
  perform t_assert((r->1->>'department_id') is not null and r->1->>'warning' is null,
                   '2d department match is case-insensitive');
  perform t_assert(r->2->>'status' = 'invalid_email',   '2e empty address is invalid_email, nothing written');
  perform t_assert(r->3->>'status' = 'duplicate',       '2f same address twice in one list is duplicate');
  perform t_assert(r->4->>'status' = 'exists',          '2g an address with an account is exists');
  perform t_assert(r->5->>'status' = 'staged' and r->5->>'department_id' is null
                   and r->5->>'warning' like '%not one of this site%',
                   '2h unknown department: staged, blank department, warning');
  perform t_assert((select count(*) from member_invites) = 3, '2i exactly three rows written');
  perform t_assert((select count(*) from member_invites where created_by = auth.uid()) = 3,
                   '2j created_by is the caller');
end $$;

do $$
declare r jsonb;
begin
  r := invite_stage('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e3',
                    '[{"email":"isake77@gmail.com"}]');
  perform t_assert(r->0->>'status' = 'already_invited' and (r->0->>'invite_id') is not null,
                   '2k re-staging a live invite returns already_invited with its id');
  perform t_assert((select count(*) from member_invites) = 3, '2l …and writes nothing');
end $$;

-- site must belong to the org, and must be a leaf
do $$ begin
  begin
    perform invite_stage('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e3', '[{"email":"x@y.co"}]');
    perform t_assert(false, '2m site of another organisation refused');
  exception when others then
    perform t_assert(sqlerrm like 'site does not belong%', '2m site of another organisation refused');
  end;
  begin
    perform invite_stage('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', '[{"email":"x@y.co"}]');
    perform t_assert(false, '2n a company that has sites refused');
  exception when others then
    perform t_assert(sqlerrm like 'choose a site%', '2n a company that has sites refused');
  end;
end $$;

-- no site at all is allowed (a single-site organisation)
do $$
declare r jsonb;
begin
  r := invite_stage('00000000-0000-0000-0000-0000000000f2', null, '[{"email":"bopeu1@union.test","department":"Finance"}]');
  perform t_assert(r->0->>'status' = 'staged' and r->0->>'warning' like 'no site chosen%',
                   '2o no site: staged, department blank with a warning');
end $$;

-- ── 3. To-send and mark ─────────────────────────────────────
do $$
declare v_id uuid; v jsonb;
begin
  select id into v_id from member_invites where email = 'isake77@gmail.com';
  v := invite_to_send(v_id);
  perform t_assert(v->>'email' = 'isake77@gmail.com' and v->>'org_name' = 'Sedimosa'
                   and v->>'unit_name' like 'Morupule%', '3a invite_to_send resolves the address and names');

  perform invite_mark(v_id, 'sent');
  perform t_assert((select status = 'sent' and sent_count = 1 and sent_at is not null
                      from member_invites where id = v_id), '3b mark sent');
  perform invite_mark(v_id, 'failed', 'smtp down');
  perform t_assert((select status = 'failed' and last_error = 'smtp down' and sent_count = 1
                      from member_invites where id = v_id), '3c mark failed keeps the count, records the error');
  perform invite_mark(v_id, 'sent');
  perform invite_mark(v_id, 'sent');
  perform t_assert((select sent_count = 3 and last_error is null from member_invites where id = v_id),
                   '3d a resend clears the error');
  begin
    perform invite_to_send(v_id);
    perform t_assert(false, '3e fourth send refused');
  exception when others then
    perform t_assert(sqlerrm like '%already been sent 3 times%', '3e fourth send refused');
  end;
end $$;

-- ── 4. The audit and the budget ─────────────────────────────
do $$
declare i int; c jsonb;
begin
  perform t_assert((support_can('send_invite') ->> 'allowed') = 'true', '4a admin may send an invite');
  perform support_log('send_invite', 'ok', null, null, 'isake77@gmail.com');
  perform t_assert((select count(*) from support_actions where action = 'send_invite') = 1,
                   '4b send_invite is an accepted audit action');

  -- 35 invites today must NOT exhaust the 30/day reset budget
  for i in 1..35 loop
    insert into support_actions (actor, action, outcome, detail, created_at)
    values ('00000000-0000-0000-0000-00000000a001', 'send_invite', 'ok', 'x'||i, now() - interval '2 hours');
  end loop;
  c := support_can('send_password_reset', '00000000-0000-0000-0000-00000000b001');
  perform t_assert((c ->> 'allowed') = 'true', '4c invites do not consume the reset budget');

  -- …but the invite budget is its own: 200/day
  for i in 1..170 loop
    insert into support_actions (actor, action, outcome, detail, created_at)
    values ('00000000-0000-0000-0000-00000000a001', 'send_invite', 'ok', 'y'||i, now() - interval '3 hours');
  end loop;
  c := support_can('send_invite');
  perform t_assert((c ->> 'allowed') = 'false' and (c ->> 'reason') like 'daily invite limit%',
                   '4d 200 invites in a day is the ceiling');
end $$;

-- ── 5. Acceptance: the trigger fills the profile ────────────
do $$
declare v_id uuid; v_uid uuid; p profiles%rowtype;
begin
  -- by invite_id in metadata (what inviteUserByEmail stamps)
  select id into v_id from member_invites where email = 'ronnietsele@gmail.com';
  insert into auth.users (email, raw_user_meta_data)
  values ('RonnieTsele@gmail.com', jsonb_build_object('invite_id', v_id, 'first_name', 'Ronnie'))
  returning id into v_uid;
  select * into p from profiles where id = v_uid;
  perform t_assert(p.org_id = '00000000-0000-0000-0000-0000000000f1'
                   and p.org_unit_id = '00000000-0000-0000-0000-0000000000e3'
                   and p.department_id = '00000000-0000-0000-0000-0000000000d2'
                   and p.first_name = 'Ronnie' and p.last_name = 'Tsele',
                   '5a profile filled from the invite: org, site, department, name');
  perform t_assert((select status = 'accepted' and auth_user_id = v_uid and accepted_at is not null
                      from member_invites where id = v_id), '5b invite marked accepted');

  -- by address alone (a person who ignores the mail and signs up themselves)
  select id into v_id from member_invites where email = 'odd@mcm.test';
  insert into auth.users (email) values ('odd@mcm.test') returning id into v_uid;
  select * into p from profiles where id = v_uid;
  perform t_assert(p.org_id = '00000000-0000-0000-0000-0000000000f1'
                   and p.org_unit_id = '00000000-0000-0000-0000-0000000000e3'
                   and p.department_id is null,
                   '5c self-signup with an invited address still lands on the site');
  perform t_assert((select status = 'accepted' from member_invites where id = v_id), '5d …and accepts the invite');

  -- garbage invite_id does not break signup
  insert into auth.users (email, raw_user_meta_data) values ('nobody@else.test', '{"invite_id":"not-a-uuid"}')
  returning id into v_uid;
  perform t_assert(exists (select 1 from profiles where id = v_uid and org_id is null),
                   '5e a bad invite_id is ignored, profile still created');

  -- the old path is intact
  insert into auth.users (email, raw_user_meta_data) values ('code@user.test', '{"invite_code":"bope-test"}')
  returning id into v_uid;
  perform t_assert((select org_id from profiles where id = v_uid) = '00000000-0000-0000-0000-0000000000f2',
                   '5f invite_code path unchanged');

  -- an accepted invite is not re-used
  begin
    perform invite_to_send((select id from member_invites where email = 'odd@mcm.test'));
    perform t_assert(false, '5g accepted invite cannot be re-sent');
  exception when others then
    perform t_assert(sqlerrm = 'this invite is accepted', '5g accepted invite cannot be re-sent');
  end;
  -- and its address can be staged again only after it stops being live — it is
  -- accepted now, so staging reports the account exists
  perform t_assert((invite_stage('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e3',
                    '[{"email":"odd@mcm.test"}]')->0->>'status') = 'exists', '5h accepted address now reports exists');
end $$;

-- ── 6. RLS on the ledger ────────────────────────────────────
set role authenticated;
set test.uid = '00000000-0000-0000-0000-00000000b001';
set test.email = 'existing@mcm.test';
do $$ begin
  perform t_assert((select count(*) from member_invites) = 0, '6a a member reads no invites');
  begin
    insert into member_invites (email, org_id, created_by)
    values ('hack@x.test', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000b001');
    perform t_assert(false, '6b a member cannot insert');
  exception when insufficient_privilege then
    perform t_assert(true, '6b a member cannot insert');
  end;
end $$;
set test.uid = '00000000-0000-0000-0000-00000000a001';
set test.email = 'lone@keywellness.test';
do $$ begin
  perform t_assert((select count(*) from member_invites) >= 4, '6c an admin reads the ledger');
  begin
    update member_invites set status = 'accepted';
    perform t_assert(false, '6d even an admin cannot write the ledger directly');
  exception when insufficient_privilege then
    perform t_assert(true, '6d even an admin cannot write the ledger directly');
  end;
  perform t_assert(jsonb_array_length(invite_list(null, 100)) >= 4, '6e invite_list returns rows');
  perform t_assert(jsonb_array_length(invite_list('00000000-0000-0000-0000-0000000000f2', 100)) = 1,
                   '6f invite_list filters by organisation');
end $$;
reset role;

\echo
\echo   member-invites assertions: all passed
