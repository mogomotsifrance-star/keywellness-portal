-- ============================================================
-- Key Wellness — Advance Recommendation database tests
-- Run by tests/run-advance-db.sh after the fixture and the migration.
-- Every access assertion runs as `authenticated` so RLS is enforced.
-- ============================================================
\set ON_ERROR_STOP on
\set QUIET on

create or replace function t_as(p_uid text, p_email text) returns void language sql as $$
  select set_config('test.uid', p_uid, false), set_config('test.email', p_email, false) $$;
create or replace function t_check(p_name text, p_ok boolean) returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS  %', p_name; else raise exception 'FAIL  %', p_name; end if;
end $$;
grant execute on function t_as(text,text), t_check(text,boolean) to authenticated;

set role authenticated;

-- 1. France (owner) generates v1
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select t_check('quota: an active advisor may generate', advance_recommendation_can_generate());
select advance_recommendation_create(
  'c0000000-0000-4000-8000-000000000001',
  '{"prep":{"term_months":24}}'::jsonb,
  '{"tier":"AMBER","term_months":24,"advance":{"amount":36850}}'::jsonb,
  '{"source":"model"}'::jsonb,
  '{"meta":{"employee_name":"Tumelo Kgamayane"},"sections":{"reasoning":{"intro":"x"}}}'::jsonb,
  '[{"key":"proof_of_payment","on":true,"group":"condition"}]'::jsonb,
  'claude-sonnet-4-5', 1200, 400, 'model') as v1 \gset
select set_config('test.v1', :'v1'::jsonb->>'id', false);
select t_check('create: returns the row with version 1 and status draft',
  (:'v1'::jsonb->>'version')::int = 1 and :'v1'::jsonb->>'status' = 'draft');
select t_check('create: owner can read it back under RLS',
  (select count(*) from advance_recommendations where client_id = 'c0000000-0000-4000-8000-000000000001') = 1);
select t_check('create: a system note landed on the timeline',
  (select count(*) from advisor_notes where client_id = 'c0000000-0000-4000-8000-000000000001'
     and origin = 'system' and body like 'Advance Recommendation v1 generated — AMBER, P 36850 over 24 months.') = 1);

-- 2. Kealeboga (another advisor) can neither generate for nor read France's client
select t_as('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test');
do $$ begin
  begin
    perform advance_recommendation_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model');
    raise exception 'FAIL  another advisor could generate for a client that is not theirs';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  create: another advisor is refused (%)', sqlerrm;
  end;
end $$;
select t_check('read: another advisor sees no rows', (select count(*) from advance_recommendations) = 0);
do $$ begin
  begin
    perform advance_recommendation_update(current_setting('test.v1')::uuid, '{"x":1}'::jsonb, null);
    raise exception 'FAIL  another advisor could edit';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  update: another advisor is refused';
  end;
end $$;

-- 3. The member (subject of the report) cannot see it, even though they can see the caseload row
select t_as('a0000000-0000-4000-8000-000000000004', 'member@example.test');
select t_check('member: can see that an advisor holds a record on them',
  (select count(*) from advisor_clients where id = 'c0000000-0000-4000-8000-000000000001') = 1);
select t_check('member: cannot see the advance recommendation', (select count(*) from advance_recommendations) = 0);
select t_check('quota: a non-advisor may not generate', not advance_recommendation_can_generate());

-- 4. Team lead reads it and may edit the draft
select t_as('a0000000-0000-4000-8000-000000000003', 'lead@example.test');
select t_check('team lead: reads the report', (select count(*) from advance_recommendations) = 1);
select advance_recommendation_update((:'v1'::jsonb->>'id')::uuid, '{"meta":{"employee_name":"Tumelo Kgamayane"},"sections":{"reasoning":{"intro":"edited by lead"}}}'::jsonb, null);
select t_check('team lead: draft edit saved and conditions untouched',
  (select content->'sections'->'reasoning'->>'intro' = 'edited by lead' and conditions->0->>'key' = 'proof_of_payment'
     from advance_recommendations where id = (:'v1'::jsonb->>'id')::uuid));

-- 5. Owner finalises; then nothing changes again
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select advance_recommendation_finalise((:'v1'::jsonb->>'id')::uuid);
select t_check('finalise: status final with stamp and author',
  (select status = 'final' and finalised_at is not null and finalised_by = 'a0000000-0000-4000-8000-000000000001'
     from advance_recommendations where id = (:'v1'::jsonb->>'id')::uuid));
select t_check('finalise: a second system note',
  (select count(*) from advisor_notes where origin = 'system' and body = 'Advance Recommendation v1 marked final.') = 1);
select advance_recommendation_finalise((:'v1'::jsonb->>'id')::uuid);   -- idempotent, must not raise
do $$ begin
  begin
    perform advance_recommendation_update((select id from advance_recommendations limit 1), '{"x":1}'::jsonb, null);
    raise exception 'FAIL  a final report could be edited';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  update: a final report cannot be edited';
  end;
  begin
    perform advance_recommendation_discard((select id from advance_recommendations limit 1));
    raise exception 'FAIL  a final report could be discarded';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  discard: a final report cannot be discarded';
  end;
end $$;

-- 6. Regenerate → v2 draft; discard removes only the draft
select advance_recommendation_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{"tier":"RED"}'::jsonb, null,
  '{"meta":{}}'::jsonb, '[]'::jsonb, null, null, null, 'fallback') as v2 \gset
select t_check('regenerate: version 2, fallback recorded',
  (:'v2'::jsonb->>'version')::int = 2 and :'v2'::jsonb->>'narrative_source' = 'fallback');
select t_check('regenerate: the no-advance note reads "no advance"',
  (select count(*) from advisor_notes where body = 'Advance Recommendation v2 generated — RED, no advance.') = 1);
select advance_recommendation_discard((:'v2'::jsonb->>'id')::uuid);
select t_check('discard: v2 gone, v1 final remains',
  (select count(*) = 1 and bool_and(status = 'final') from advance_recommendations));

-- 7. The gate list: no anon execute anywhere
reset role;
select t_check('grants: anon cannot execute any advance_recommendation_* function',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname like 'advance_recommendation_%'
                and has_function_privilege('anon', p.oid, 'EXECUTE')));

-- 8. The advance gate: only an organisation that runs a programme
-- The UI hides the view for these two cases; this is the check that binds,
-- so a hand-made REST call cannot produce an employer's advance document for
-- a client who is not on that employer's programme.
set role authenticated;
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');

do $$
declare v_msg text; v_ok boolean;
begin
  begin
    perform advance_recommendation_create(
      'c0000000-0000-4000-8000-000000000002',
      '{"prep":{}}'::jsonb, '{"tier":"AMBER","term_months":24}'::jsonb,
      null, '{"meta":{}}'::jsonb, '[]'::jsonb, 'test', 1, 1, 'model');
    v_ok := false; v_msg := 'it was allowed';
  exception when others then
    v_msg := SQLERRM;
    v_ok  := v_msg like '%does not run an employee advance programme%';
  end;
  raise notice '  (refusal said: %)', v_msg;
  perform t_check('gate: an organisation with no advance programme is refused', v_ok);
end $$;

do $$
declare v_msg text; v_ok boolean;
begin
  begin
    perform advance_recommendation_create(
      'c0000000-0000-4000-8000-000000000003',
      '{"prep":{}}'::jsonb, '{"tier":"AMBER","term_months":24}'::jsonb,
      null, '{"meta":{}}'::jsonb, '[]'::jsonb, 'test', 1, 1, 'model');
    v_ok := false; v_msg := 'it was allowed';
  exception when others then
    v_msg := SQLERRM;
    v_ok  := v_msg like '%not on a company programme%';
  end;
  raise notice '  (refusal said: %)', v_msg;
  perform t_check('gate: a private client with no organisation is refused', v_ok);
end $$;
