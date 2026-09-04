-- ============================================================
-- Key Wellness — Debt Rehab Plan database tests
-- Run by tests/run-rehab-db.sh after the fixtures and the migration.
-- Every access assertion runs as `authenticated` so RLS is enforced.
-- The point of this file: the table has NO read path except the gated
-- RPC. Owner, team lead and admin can read through it; another advisor,
-- the member and an HR/employer user cannot; nobody can read it directly.
-- ============================================================
\set ON_ERROR_STOP on
\set QUIET on

create or replace function t_as(p_uid text, p_email text) returns void language sql as $$
  select set_config('test.uid', p_uid, false), set_config('test.email', p_email, false) $$;
create or replace function t_check(p_name text, p_ok boolean) returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS  %', p_name; else raise exception 'FAIL  %', p_name; end if;
end $$;
-- Expect an exception from p_sql; pass when it raises.
create or replace function t_refused(p_name text, p_sql text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS  % (%)', p_name, sqlerrm; return;
  end;
  raise exception 'FAIL  % — it was allowed', p_name;
end $$;
grant execute on function t_as(text,text), t_check(text,boolean), t_refused(text,text) to authenticated;

-- 0. Structure: RLS on, and NO policy of any kind
select t_check('structure: RLS is enabled on debt_rehab_plans',
  (select relrowsecurity from pg_class where relname = 'debt_rehab_plans'));
select t_check('structure: the table has zero policies — no SELECT path exists',
  (select count(*) from pg_policies where tablename = 'debt_rehab_plans') = 0);

set role authenticated;

-- 1. France (owner) generates v1 for Tumelo
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select t_check('quota: an active advisor may generate', debt_rehab_plan_can_generate());
select debt_rehab_plan_create(
  'c0000000-0000-4000-8000-000000000001',
  '{"prep":{"extension_months":24}}'::jsonb,
  '{"headline":"1 renegotiate · 2 consolidate · 0 retain; shortfall P 3,550.00","tier":"AMBER"}'::jsonb,
  '{"source":"model"}'::jsonb,
  '{"meta":{"employee_name":"Tumelo Kgamayane"},"sections":{"root_causes":{"bullets":["x"]}}}'::jsonb,
  '[{"key":"phase1:consolidate","on":true,"group":"phase1"}]'::jsonb,
  'claude-sonnet-4-5', 1500, 600, 'model') as v1 \gset
select set_config('test.v1', :'v1'::jsonb->>'id', false);
select t_check('create: returns the row with version 1 and status draft',
  (:'v1'::jsonb->>'version')::int = 1 and :'v1'::jsonb->>'status' = 'draft');
select t_check('read: owner reads it back through debt_rehab_plan_list()',
  jsonb_array_length(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) = 1);
select t_check('read: even the OWNER gets zero rows from a direct select — there is no policy',
  (select count(*) from debt_rehab_plans) = 0);
select t_check('create: a system note landed on the timeline',
  (select count(*) from advisor_notes where client_id = 'c0000000-0000-4000-8000-000000000001'
     and origin = 'system' and body = 'Debt Rehab Plan v1 generated — 1 renegotiate · 2 consolidate · 0 retain; shortfall P 3,550.00.') = 1);

-- 2. Kealeboga (another advisor): no create, no list, no edit, no rows
select t_as('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test');
select t_refused('another advisor: create is refused',
  $q$ select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model') $q$);
select t_refused('another advisor: list is refused',
  $q$ select debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001') $q$);
select t_refused('another advisor: update is refused',
  $q$ select debt_rehab_plan_update(current_setting('test.v1')::uuid, '{"x":1}'::jsonb, null) $q$);
select t_check('another advisor: direct select returns zero rows', (select count(*) from debt_rehab_plans) = 0);

-- 3. The MEMBER (subject of the plan): can see the caseload row, nothing of the plan
select t_as('a0000000-0000-4000-8000-000000000004', 'member@example.test');
select t_check('member: can see that an advisor holds a record on them',
  (select count(*) from advisor_clients where id = 'c0000000-0000-4000-8000-000000000001') = 1);
select t_refused('member: list is refused', $q$ select debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001') $q$);
select t_check('member: direct select returns zero rows', (select count(*) from debt_rehab_plans) = 0);
select t_check('member: may not generate', not debt_rehab_plan_can_generate());

-- 4. HR / EMPLOYER of the client's own organisation: nothing
select t_as('a0000000-0000-4000-8000-000000000005', 'hr@example.test');
select t_check('hr: the fixture really makes them Hollard''s employer', employer_org() = 'd0000000-0000-4000-8000-000000000001');
select t_refused('hr/employer: list is refused', $q$ select debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001') $q$);
select t_refused('hr/employer: create is refused',
  $q$ select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model') $q$);
select t_check('hr/employer: direct select returns zero rows', (select count(*) from debt_rehab_plans) = 0);
select t_check('hr/employer: may not generate', not debt_rehab_plan_can_generate());

-- 5. Team lead reads it and may edit the draft
select t_as('a0000000-0000-4000-8000-000000000003', 'lead@example.test');
select t_check('team lead: reads the plan through the RPC', jsonb_array_length(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) = 1);
select debt_rehab_plan_update((:'v1'::jsonb->>'id')::uuid, '{"meta":{"employee_name":"Tumelo Kgamayane"},"sections":{"root_causes":{"bullets":["edited by lead"]}}}'::jsonb, null);
select t_check('team lead: draft edit saved and actions untouched',
  (select r->'content'->'sections'->'root_causes'->'bullets'->>0 = 'edited by lead' and r->'actions'->0->>'key' = 'phase1:consolidate'
     from jsonb_array_elements(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) r));

-- 6. Admin reads it (no advisors row of their own)
select t_as('a0000000-0000-4000-8000-000000000006', 'admin@example.test');
select t_check('admin: reads the plan through the RPC', jsonb_array_length(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) = 1);
select t_check('admin: direct select still returns zero rows', (select count(*) from debt_rehab_plans) = 0);

-- 7. Owner finalises; then nothing changes again
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select debt_rehab_plan_finalise((:'v1'::jsonb->>'id')::uuid);
select t_check('finalise: status final with stamp and author',
  (select r->>'status' = 'final' and r->>'finalised_at' is not null
     from jsonb_array_elements(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) r));
select t_check('finalise: a second system note',
  (select count(*) from advisor_notes where origin = 'system' and body = 'Debt Rehab Plan v1 marked final.') = 1);
select debt_rehab_plan_finalise((:'v1'::jsonb->>'id')::uuid);   -- idempotent, must not raise
select t_refused('update: a final plan cannot be edited',
  $q$ select debt_rehab_plan_update(current_setting('test.v1')::uuid, '{"x":1}'::jsonb, null) $q$);
select t_refused('discard: a final plan cannot be discarded',
  $q$ select debt_rehab_plan_discard(current_setting('test.v1')::uuid) $q$);

-- 8. Regenerate → v2 draft; discard removes only the draft
select debt_rehab_plan_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{"headline":"REFER to formal debt counselling"}'::jsonb, null,
  '{"meta":{}}'::jsonb, '[]'::jsonb, null, null, null, 'fallback') as v2 \gset
select t_check('regenerate: version 2, fallback recorded',
  (:'v2'::jsonb->>'version')::int = 2 and :'v2'::jsonb->>'narrative_source' = 'fallback');
select t_check('regenerate: the REFER headline is what the timeline says',
  (select count(*) from advisor_notes where body = 'Debt Rehab Plan v2 generated — REFER to formal debt counselling.') = 1);
select t_check('list: newest first', (select r->>'version' from jsonb_array_elements(debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001')) r limit 1) = '2');
select debt_rehab_plan_discard((:'v2'::jsonb->>'id')::uuid);
select t_check('discard: v2 gone, v1 final remains',
  (select jsonb_array_length(l) = 1 and l->0->>'status' = 'final' from debt_rehab_plan_list('c0000000-0000-4000-8000-000000000001') l));

-- 9. Grants: no anon execute anywhere, authenticated everywhere
reset role;
select t_check('grants: anon cannot execute any debt_rehab_plan_* function',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname like 'debt_rehab_plan_%'
                and has_function_privilege('anon', p.oid, 'EXECUTE')));
select t_check('grants: six functions, all executable by authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'debt_rehab_plan_%'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 6);
