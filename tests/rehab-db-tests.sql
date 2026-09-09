-- ============================================================
-- Key Wellness — Debt Rehab Plan database tests
-- Run by tests/run-rehab-db.sh after the fixture and the migration.
-- Every access assertion runs as `authenticated` so RLS is enforced.
--
-- The assertions that matter most are 3, 4 and 5: the member, the HR user and
-- another advisor each read ZERO rows. This document is internal by
-- structure, and a structure is only as good as the test that proves it.
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

-- 1. France (the owning advisor) generates v1 for Olorato
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select t_check('quota: an active advisor may generate', debt_rehab_plan_can_generate());
select debt_rehab_plan_create(
  'c0000000-0000-4000-8000-000000000004',
  '{"prep":{"generated_date":"2026-09-03"}}'::jsonb,
  '{"headline":"REHABILITATE","counts":{"retain":0,"consolidate":2,"renegotiate":1},"budget":{"shortfall":3550},"dsr":{"dsr":44.72}}'::jsonb,
  '{"source":"model"}'::jsonb,
  '{"meta":{"client_name":"Olorato Maliko","banner":"CONFIDENTIAL — INTERNAL DEBT REHAB PLAN (Key Wellness use only — not for distribution to employer or employee)"},"sections":{"root_causes":{"bullets":["x"]}}}'::jsonb,
  '[{"key":"phase_1_0","group":"phase_1","label":"Size a consolidation","on":true}]'::jsonb,
  'claude-sonnet-4-5', 1400, 700, 'model') as v1 \gset
select set_config('test.v1', :'v1'::jsonb->>'id', false);
select t_check('create: returns the row with version 1 and status draft',
  (:'v1'::jsonb->>'version')::int = 1 and :'v1'::jsonb->>'status' = 'draft');
select t_check('create: the owner can read it back under RLS',
  (select count(*) from debt_rehab_plans where client_id = 'c0000000-0000-4000-8000-000000000004') = 1);
select t_check('create: a system note landed on the timeline naming the actions and the shortfall',
  (select count(*) from advisor_notes where client_id = 'c0000000-0000-4000-8000-000000000004'
     and origin = 'system'
     and body = 'Debt Rehab Plan v1 generated — REHABILITATE; retain 0, consolidate 2, renegotiate 1; shortfall P 3550.') = 1);
select t_check('create: the confidentiality banner is stored with the content',
  (select content->'meta'->>'banner' like 'CONFIDENTIAL — INTERNAL DEBT REHAB PLAN%'
     from debt_rehab_plans where id = (:'v1'::jsonb->>'id')::uuid));

-- 2. No offers_advances gate: a client whose employer runs no advance
-- programme, and a private client with no organisation at all, both get a plan.
-- This is the deliberate difference from the Advance Recommendation.
select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000002',
  '{}'::jsonb, '{"headline":"REFER","counts":{"retain":1,"consolidate":0,"renegotiate":0}}'::jsonb,
  null, '{"meta":{}}'::jsonb, '[]'::jsonb, null, null, null, 'fallback') as vnoprog \gset
select t_check('gate: an organisation with NO advance programme still gets a plan',
  (:'vnoprog'::jsonb->>'version')::int = 1);
select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000003',
  '{}'::jsonb, '{"headline":"REHABILITATE","counts":{"retain":1,"consolidate":0,"renegotiate":0}}'::jsonb,
  null, '{"meta":{}}'::jsonb, '[]'::jsonb, null, null, null, 'fallback') as vprivate \gset
select t_check('gate: a private client on no company programme still gets a plan',
  (:'vprivate'::jsonb->>'version')::int = 1);

-- 3. THE MEMBER — the person the plan is about — cannot see it.
select t_as('a0000000-0000-4000-8000-000000000007', 'olorato@example.test');
select t_check('member: can see that an advisor holds a record on them',
  (select count(*) from advisor_clients where id = 'c0000000-0000-4000-8000-000000000004') = 1);
select t_check('member: CANNOT see the debt rehab plan written about them',
  (select count(*) from debt_rehab_plans) = 0);
select t_check('member: may not generate one', not debt_rehab_plan_can_generate());
-- The gate must return FALSE for a non-advisor, never NULL. `not NULL` is NULL,
-- which no IF acts on, so a NULL here would walk straight past every
-- authorisation check in the migration.
select t_check('member: can_manage_advisor returns false, not null, for a non-advisor',
  can_manage_advisor('b0000000-0000-4000-8000-000000000001') is false);
do $$ begin
  begin
    perform debt_rehab_plan_create('c0000000-0000-4000-8000-000000000004', '{}'::jsonb, '{}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model');
    raise exception 'FAIL  the member could generate a plan on themselves';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  member: create is refused';
  end;
end $$;

-- 4. THE HR / EMPLOYER USER — a real grant over the client's own
-- organisation — cannot see it. This is the denial the whole table shape
-- exists for: no policy consults employers, so there is nothing to widen.
select t_as('a0000000-0000-4000-8000-000000000006', 'hr@example.test');
select t_check('hr: the grant is real — employer_org() resolves to the client''s organisation',
  employer_org() = 'd0000000-0000-4000-8000-000000000001');
select t_check('hr: CANNOT see any debt rehab plan',
  (select count(*) from debt_rehab_plans) = 0);
select t_check('hr: may not generate one', not debt_rehab_plan_can_generate());
do $$ begin
  begin
    perform debt_rehab_plan_update((select id from debt_rehab_plans limit 1), '{"x":1}'::jsonb, null);
    raise exception 'FAIL  an HR user could edit a plan';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  hr: update is refused (it cannot even see the row)';
  end;
end $$;
select t_check('hr: no policy on the table mentions employers, org_id or hr scope',
  (select count(*) = 0 from pg_policies
    where tablename = 'debt_rehab_plans'
      and (coalesce(qual,'') || coalesce(with_check,'')) ~* 'employer|org_id|hr_unit'));

-- 5. ANOTHER ADVISOR can neither read nor write.
select t_as('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test');
select t_check('other advisor: sees no rows', (select count(*) from debt_rehab_plans) = 0);
do $$ begin
  begin
    perform debt_rehab_plan_create('c0000000-0000-4000-8000-000000000004', '{}'::jsonb, '{}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model');
    raise exception 'FAIL  another advisor could generate for a client that is not theirs';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  other advisor: create is refused (%)', sqlerrm;
  end;
  begin
    perform debt_rehab_plan_update(current_setting('test.v1')::uuid, '{"x":1}'::jsonb, null);
    raise exception 'FAIL  another advisor could edit';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  other advisor: update is refused';
  end;
end $$;

-- 6. The team lead reads it and may edit the draft.
select t_as('a0000000-0000-4000-8000-000000000003', 'lead@example.test');
select t_check('team lead: reads every plan on the caseload',
  (select count(*) from debt_rehab_plans) = 3);
select debt_rehab_plan_update((:'v1'::jsonb->>'id')::uuid,
  '{"meta":{"client_name":"Olorato Maliko"},"sections":{"root_causes":{"bullets":["edited by lead"]}}}'::jsonb, null);
select t_check('team lead: the draft edit saved and the actions were untouched',
  (select content->'sections'->'root_causes'->'bullets'->>0 = 'edited by lead'
      and actions->0->>'key' = 'phase_1_0'
     from debt_rehab_plans where id = (:'v1'::jsonb->>'id')::uuid));

-- 7. An ADMIN reads it.
select t_as('a0000000-0000-4000-8000-000000000005', 'admin@example.test');
select t_check('admin: reads the plan', (select count(*) from debt_rehab_plans) = 3);

-- 8. The owner finalises; then nothing changes again.
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select debt_rehab_plan_finalise((:'v1'::jsonb->>'id')::uuid);
select t_check('finalise: status final with stamp and author',
  (select status = 'final' and finalised_at is not null and finalised_by = 'a0000000-0000-4000-8000-000000000001'
     from debt_rehab_plans where id = (:'v1'::jsonb->>'id')::uuid));
select t_check('finalise: a second system note',
  (select count(*) from advisor_notes where origin = 'system' and body = 'Debt Rehab Plan v1 marked final.') = 1);
select debt_rehab_plan_finalise((:'v1'::jsonb->>'id')::uuid);   -- idempotent, must not raise
do $$ begin
  begin
    perform debt_rehab_plan_update(current_setting('test.v1')::uuid, '{"x":1}'::jsonb, null);
    raise exception 'FAIL  a final plan could be edited';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  update: a final plan cannot be edited';
  end;
  begin
    perform debt_rehab_plan_discard(current_setting('test.v1')::uuid);
    raise exception 'FAIL  a final plan could be discarded';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  discard: a final plan cannot be discarded';
  end;
end $$;

-- 9. Regenerate → v2 draft; discard removes only the draft.
select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000004', '{}'::jsonb,
  '{"headline":"REFER","counts":{"retain":0,"consolidate":3,"renegotiate":0},"budget":{"shortfall":null}}'::jsonb,
  null, '{"meta":{}}'::jsonb, '[]'::jsonb, null, null, null, 'fallback') as v2 \gset
select t_check('regenerate: version 2, fallback recorded',
  (:'v2'::jsonb->>'version')::int = 2 and :'v2'::jsonb->>'narrative_source' = 'fallback');
select t_check('regenerate: a plan with no shortfall does not claim one in the note',
  (select count(*) from advisor_notes
    where body = 'Debt Rehab Plan v2 generated — REFER; retain 0, consolidate 3, renegotiate 0.') = 1);
select debt_rehab_plan_discard((:'v2'::jsonb->>'id')::uuid);
select t_check('discard: v2 gone, v1 final remains',
  (select count(*) = 1 and bool_and(status = 'final')
     from debt_rehab_plans where client_id = 'c0000000-0000-4000-8000-000000000004'));

-- 10. Shape of the table's access: exactly one policy, and it is a SELECT.
reset role;
select t_check('policy: exactly one policy exists on debt_rehab_plans',
  (select count(*) from pg_policies where tablename = 'debt_rehab_plans') = 1);
select t_check('policy: it is a SELECT policy named debt_rehab_plans_read',
  (select cmd = 'SELECT' and policyname = 'debt_rehab_plans_read'
     from pg_policies where tablename = 'debt_rehab_plans'));
select t_check('policy: it is gated on can_manage_advisor',
  (select qual ~* 'can_manage_advisor' from pg_policies where tablename = 'debt_rehab_plans'));
select t_check('grants: anon cannot execute any debt_rehab_plan_* function',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname like 'debt_rehab_plan_%'
                and has_function_privilege('anon', p.oid, 'EXECUTE')));
select t_check('grants: no direct table privilege for anon on debt_rehab_plans',
  not has_table_privilege('anon', 'public.debt_rehab_plans', 'SELECT'));
select t_check('sweep: every debt_rehab_plan_* function names a gate the CLAUDE.md regex knows',
  (select bool_and(prosrc ~* '\mcan_manage_advisor\M|\mcurrent_advisor_id\M')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'debt_rehab_plan_%'));
