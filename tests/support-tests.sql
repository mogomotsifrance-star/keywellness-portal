-- ============================================================
-- Key Wellness — member support: assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-support.sh after m5-fixture + m5a-fixture-extra and
-- supabase_support_audit.sql.
--
-- Access assertions run under `set role authenticated`, so RLS is actually
-- enforced — the pattern m5-tests.sql established.
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant insert, select on _r to authenticated;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, p_ok, p_detail); end $$;

create or replace function _visible(p_table text)
returns int language plpgsql as $$
declare n int;
begin
  execute format('select count(*) from %I', p_table) into n;
  return n;
exception when insufficient_privilege then return -1;
end $$;

-- is_ops_admin() reads auth.jwt(); even the postgres-context assertions need
-- an identity or every gate refuses.
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';


-- ══ 1–2 · The gate ══════════════════════════════════════════

select _chk('1  is_ops_admin is true for an admin today',
  is_ops_admin() is true);

do $$
declare v boolean;
begin
  perform set_config('test.email', 'kefilwe@keywealth.co.bw', false);
  v := is_ops_admin();
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  insert into _r values ('2  and false for an advisor who is not an admin', v is false, v::text);
end $$;


-- ══ 3–9 · The audit table ═══════════════════════════════════

-- Seeded as postgres, backdated so the burst window below is not disturbed.
insert into support_actions (actor, action, target_user, outcome, detail, created_at)
values
  ('00000000-0000-0000-0000-000000000009', 'lookup', null, 'ok', 'q=kefilwe',
   now() - interval '10 minutes'),
  ('00000000-0000-0000-0000-000000000009', 'send_password_reset',
   '00000000-0000-0000-0000-00000000000e', 'ok', 'member@example.test',
   now() - interval '9 minutes'),
  ('00000000-0000-0000-0000-000000000009', 'send_password_reset',
   '00000000-0000-0000-0000-00000000000e', 'denied', 'daily limit reached (30)',
   now() - interval '8 minutes');

select _chk('3  a denied attempt is recorded, not only successes',
  (select count(*) from support_actions where outcome = 'denied') = 1);

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
select _chk('4  an ops admin reads the audit trail', _visible('support_actions') = 3);
reset role;

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
select _chk('5  an advisor reads nothing of it', _visible('support_actions') <= 0);
reset role;

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'member@example.test';
select _chk('6  a member reads nothing of it', _visible('support_actions') <= 0);
reset role;

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000f';
set session "test.email" = 'hr@bopeu.test';
select _chk('7  an HR user reads nothing of it', _visible('support_actions') <= 0);
reset role;

-- The rows are a record. Nobody amends or removes one — including the admin
-- whose action produced it, which is the whole point of an audit trail.
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
do $$
declare n int; ok_del boolean := false; ok_upd boolean := false; ok_ins boolean := false;
begin
  begin
    delete from support_actions;
    get diagnostics n = row_count; ok_del := (n = 0);
  exception when insufficient_privilege then ok_del := true; end;

  begin
    update support_actions set outcome = 'ok';
    get diagnostics n = row_count; ok_upd := (n = 0);
  exception when insufficient_privilege then ok_upd := true; end;

  begin
    insert into support_actions (actor, action, outcome)
    values ('00000000-0000-0000-0000-000000000009', 'lookup', 'ok');
    ok_ins := false;
  exception when insufficient_privilege then ok_ins := true;
            when others then ok_ins := true; end;

  insert into _r values ('8  not even an admin can delete an audit row', ok_del, null);
  insert into _r values ('9  or amend one', ok_upd, null);
  insert into _r values ('10 or write one directly, bypassing support_log', ok_ins, null);
end $$;
reset role;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';


-- ══ 11–13 · support_log ═════════════════════════════════════

-- Capture the id FIRST. An earlier version put support_log() in a WHERE
-- clause -- and PostgreSQL evaluates a volatile function ONCE PER ROW
-- SCANNED, so the assertion wrote one audit row per existing row, tripped
-- the burst limit, and made four later rate-limit assertions fail for a
-- reason that had nothing to do with them.
do $$
declare v_id uuid; v_actor uuid;
begin
  v_id := support_log('lookup', 'ok', null, null, 'from the test');
  select actor into v_actor from support_actions where id = v_id;
  insert into _r values ('11 support_log records the actor from auth.uid(), not from an argument',
    v_actor = '00000000-0000-0000-0000-000000000009'::uuid, v_actor::text);
end $$;

do $$
declare ok boolean := false;
begin
  perform set_config('test.email', 'member@example.test', false);
  begin
    perform support_log('lookup', 'ok');
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  insert into _r values ('12 a member cannot write an audit row', ok, null);
end $$;

do $$
declare v_id uuid; v_len int;
begin
  v_id := support_log('lookup','ok',null,null, repeat('x', 900));
  select length(detail) into v_len from support_actions where id = v_id;
  insert into _r values ('13 the detail is capped rather than allowed to grow without bound',
    v_len = 500, v_len::text);
end $$;


-- ══ 14–19 · support_lookup ══════════════════════════════════

select _chk('14 a lookup finds a member by email and returns the FULL address',
  (select jsonb_array_length(support_lookup('member@'))) >= 1
  and (support_lookup('member@') -> 0 ->> 'email') = 'member@example.test');

select _chk('15 a lookup finds a member by name',
  (select jsonb_array_length(support_lookup('kefilwe'))) >= 1);

select _chk('16 the roles a person holds come back with them',
  (select support_lookup('lone@') -> 0 -> 'roles') @> '["admin"]'::jsonb);

do $$
declare ok boolean := false;
begin
  begin
    perform support_lookup('ab');
  exception when others then ok := sqlerrm = 'search needs at least 3 characters';
  end;
  insert into _r values ('17 a two-character search is refused, so nobody lists the membership', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    perform support_lookup('');
  exception when others then ok := true;
  end;
  insert into _r values ('18 and an empty one is too', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  perform set_config('test.email', 'kefilwe@keywealth.co.bw', false);
  begin
    perform support_lookup('member@');
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  insert into _r values ('19 an advisor cannot look anyone up', ok, null);
end $$;


-- ══ 20–24 · support_can, the three rate-limit axes ══════════

select _chk('20 an ops admin is allowed by default',
  (support_can('lookup') ->> 'allowed')::boolean is true);

do $$
declare v jsonb;
begin
  perform set_config('test.email', 'member@example.test', false);
  v := support_can('send_password_reset', '00000000-0000-0000-0000-00000000000e');
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  insert into _r values ('21 a member is refused, with a reason rather than a raise',
    (v ->> 'allowed')::boolean is false and v ->> 'reason' = 'not authorised', v::text);
end $$;

-- THE AXIS THAT MATTERS. Repeated resets against ONE person is what an
-- attacker does, and the actor's own daily cap would never notice it.
insert into support_actions (actor, action, target_user, outcome, created_at)
values
  ('00000000-0000-0000-0000-00000000000a','send_password_reset',
   '00000000-0000-0000-0000-00000000000b','ok', now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-00000000000a','send_password_reset',
   '00000000-0000-0000-0000-00000000000b','ok', now() - interval '19 minutes');

select _chk('22 two resets for one person today is still allowed',
  (support_can('send_password_reset','00000000-0000-0000-0000-00000000000b') ->> 'allowed')::boolean is true);

insert into support_actions (actor, action, target_user, outcome, created_at)
values ('00000000-0000-0000-0000-00000000000a','send_password_reset',
        '00000000-0000-0000-0000-00000000000b','ok', now() - interval '18 minutes');

select _chk('23 the third is the limit — a fourth is refused for that person',
  (support_can('send_password_reset','00000000-0000-0000-0000-00000000000b') ->> 'allowed')::boolean is false
  and (support_can('send_password_reset','00000000-0000-0000-0000-00000000000b') ->> 'reason')
      = 'this member has already had 3 reset links today');

select _chk('24 and it is per person, not global — someone else is unaffected',
  (support_can('send_password_reset','00000000-0000-0000-0000-00000000000e') ->> 'allowed')::boolean is true);

-- The actor's own daily cap. Backdated within the Gaborone day but outside
-- the one-minute burst window.
insert into support_actions (actor, action, outcome, created_at)
select '00000000-0000-0000-0000-000000000009', 'lookup', 'ok', now() - interval '5 minutes'
  from generate_series(1, 30);

select _chk('25 the actor daily cap refuses once it is reached',
  (support_can('lookup') ->> 'allowed')::boolean is false
  and (support_can('lookup') ->> 'reason') = 'daily limit reached (30)');


-- ══ 26–27 · support_recent ══════════════════════════════════

select _chk('26 support_recent returns the trail newest first, with both addresses resolved',
  (select support_recent(5) -> 0 ->> 'actor') is not null
  and jsonb_array_length(support_recent(5)) = 5);

do $$
declare ok boolean := false;
begin
  perform set_config('test.email', 'hr@bopeu.test', false);
  begin
    perform support_recent(5);
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  perform set_config('test.email', 'lone@keywellness.co.bw', false);
  insert into _r values ('27 an HR user cannot read the trail through the RPC either', ok, null);
end $$;


-- ══ 28 · The sweep ══════════════════════════════════════════
-- is_ops_admin is now a gate name. CLAUDE.md's regex gains it in the same
-- change that creates it — a function gated by a name the sweep does not
-- know is reported as ungated, and the next person either revokes a grant the
-- page needs or learns to ignore the sweep.

select _chk('28 no support function is reachable ungated by anon or authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
      and pg_get_function_result(p.oid) <> 'trigger'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      and p.proname in ('is_ops_admin','support_lookup','support_can',
                        'support_log','support_recent')
      and not (p.prosrc ~* '\mis_admin\M|\mis_ops_admin\M'
            or p.prosrc ~* 'auth\.uid\(\)|auth\.jwt\(\)')) = 0);


-- ══ Report ══════════════════════════════════════════════════

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if (select count(*) from _r where not ok) > 0 then
    raise exception 'support assertions failed';
  end if;
end $$;
