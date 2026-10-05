-- ============================================================
-- Key Wellness — consent form before finalise: database tests
-- Run by tests/run-advance-consent-db.sh after the fixture, the Advance
-- Recommendation migration and supabase_advance_consent.sql.
-- Access assertions run as `authenticated` so RLS is enforced.
-- ============================================================
\set ON_ERROR_STOP on
\set QUIET on

create or replace function t_as(p_uid text, p_email text) returns void language sql as $$
  select set_config('test.uid', p_uid, false), set_config('test.email', p_email, false) $$;
create or replace function t_check(p_name text, p_ok boolean) returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS  %', p_name; else raise exception 'FAIL  %', p_name; end if;
end $$;
-- Expect a statement to raise, and the message to contain p_like.
create or replace function t_refused(p_name text, p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_like || '%' then raise notice 'PASS  % (%)', p_name, sqlerrm; return; end if;
    raise exception 'FAIL  % — refused, but with: %', p_name, sqlerrm;
  end;
  raise exception 'FAIL  % — was allowed', p_name;
end $$;
grant execute on function t_as(text,text), t_check(text,boolean), t_refused(text,text,text) to authenticated;

insert into admins (email) values ('admin@example.test');
insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000009', 'admin@example.test');

set role authenticated;

-- ── 1. A draft cannot be finalised without a form ─────────────
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select advance_recommendation_create('c0000000-0000-4000-8000-000000000001',
  '{}'::jsonb, '{"tier":"AMBER","term_months":24,"advance":{"amount":1000}}'::jsonb, '{}'::jsonb,
  '{"meta":{},"sections":{}}'::jsonb, '[]'::jsonb, null, null, null, 'model') as v1 \gset
select set_config('test.v1', :'v1'::jsonb->>'id', false);
select t_refused('finalise: refused with no consent form recorded',
  format('select advance_recommendation_finalise(%L)', current_setting('test.v1')), 'signed consent form must be recorded');
select t_check('finalise: the draft is still a draft',
  (select status from advance_recommendations where id = current_setting('test.v1')::uuid) = 'draft');

-- ── 2. Who may record ─────────────────────────────────────────
select t_as('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test');
select t_refused('record: another advisor is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'only the client''s advisor or an admin');
select t_as('a0000000-0000-4000-8000-000000000003', 'lead@example.test');
select t_refused('record: a team lead who is not the assigned advisor is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'only the client''s advisor or an admin');
select t_as('a0000000-0000-4000-8000-000000000004', 'member@example.test');
select t_refused('record: the member is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'only the client''s advisor or an admin');
select t_as('', '');
select t_refused('record: nobody signed in is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'only the client''s advisor or an admin');

-- ── 3. Date rules ─────────────────────────────────────────────
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select t_refused('record: a signing date in the future is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date + 2)$q$, 'cannot be in the future');
select t_refused('record: a missing signing date is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', null)$q$, 'enter the date');

-- ── 4. The assigned advisor records it ────────────────────────
select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 3) as k1 \gset
select set_config('test.k1', :'k1', false);
select t_check('record: the assigned advisor can record a form',
  (select count(*) from advance_consents where id = current_setting('test.k1')::uuid) = 1);
select t_check('record: who recorded it is kept by name',
  (select recorded_by_name from advance_consents where id = current_setting('test.k1')::uuid) = 'France Mogomotsi'
  and (select recorded_by from advance_consents where id = current_setting('test.k1')::uuid) = 'a0000000-0000-4000-8000-000000000001');
select t_check('record: the signing date is kept as entered',
  (select form_signed_on from advance_consents where id = current_setting('test.k1')::uuid) = current_date - 3);
select t_check('record: a system note landed on the timeline',
  (select count(*) from advisor_notes where client_id = 'c0000000-0000-4000-8000-000000000001'
     and origin = 'system' and body like 'Signed consent form on file (signed %) recorded for the Advance Recommendation.') = 1);
select t_refused('record: a second form while one is unused is refused',
  $q$select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'already recorded for this application');

-- ── 5. Reading and writing the table ─────────────────────────
select t_as('a0000000-0000-4000-8000-000000000002', 'kealeboga@example.test');
select t_check('read: another advisor sees no consent rows', (select count(*) from advance_consents) = 0);
select t_as('a0000000-0000-4000-8000-000000000004', 'member@example.test');
select t_check('read: the member sees no consent rows', (select count(*) from advance_consents) = 0);
select t_as('a0000000-0000-4000-8000-000000000003', 'lead@example.test');
select t_check('read: a team lead can read it (can_manage_advisor)', (select count(*) from advance_consents) = 1);
select t_as('a0000000-0000-4000-8000-000000000001', 'france@example.test');
select t_refused('write: a direct insert is refused',
  $q$insert into advance_consents (client_id, form_signed_on, recorded_by, recorded_by_name)
     values ('c0000000-0000-4000-8000-000000000001', current_date, 'a0000000-0000-4000-8000-000000000001', 'x')$q$, 'permission denied');
select t_refused('write: a direct update is refused',
  $q$update advance_consents set form_signed_on = current_date$q$, 'permission denied');

-- ── 6. Finalise with the form ─────────────────────────────────
select advance_recommendation_finalise(current_setting('test.v1')::uuid);
select t_check('finalise: allowed once a form is recorded',
  (select status from advance_recommendations where id = current_setting('test.v1')::uuid) = 'final');
select t_check('finalise: the form it relied on is stamped on the report',
  (select consent_id from advance_recommendations where id = current_setting('test.v1')::uuid) = current_setting('test.k1')::uuid);
select advance_recommendation_finalise(current_setting('test.v1')::uuid);
select t_check('finalise: running it again changes nothing',
  (select consent_id from advance_recommendations where id = current_setting('test.v1')::uuid) = current_setting('test.k1')::uuid);

-- ── 7. One form, one application ──────────────────────────────
select advance_recommendation_create('c0000000-0000-4000-8000-000000000001',
  '{}'::jsonb, '{"tier":"AMBER","term_months":24,"advance":{"amount":2000}}'::jsonb, '{}'::jsonb,
  '{"meta":{},"sections":{}}'::jsonb, '[]'::jsonb, null, null, null, 'model') as v2 \gset
select set_config('test.v2', :'v2'::jsonb->>'id', false);
select t_refused('finalise: a used form does not finalise a second application',
  format('select advance_recommendation_finalise(%L)', current_setting('test.v2')), 'signed consent form must be recorded');
select advance_consent_record('c0000000-0000-4000-8000-000000000001', current_date) as k2 \gset
select set_config('test.k2', :'k2', false);
select t_check('record: a new form is accepted once the last one was used', current_setting('test.k2') <> current_setting('test.k1'));
select advance_recommendation_finalise(current_setting('test.v2')::uuid);
select t_check('finalise: the second application relies on the second form',
  (select consent_id from advance_recommendations where id = current_setting('test.v2')::uuid) = current_setting('test.k2')::uuid);

-- ── 8. An admin may record; their name is their email ────────
select t_as('a0000000-0000-4000-8000-000000000009', 'admin@example.test');
select advance_consent_record('c0000000-0000-4000-8000-000000000002', current_date - 1) as k3 \gset
select t_check('record: an admin (no advisor row) can record',
  (select recorded_by_name from advance_consents where id = :'k3'::uuid) = 'admin@example.test');

-- ── 9. Any other write path (service role, superuser) ────────
reset role;
insert into advance_recommendations (client_id, version, status, input, computed, content)
values ('c0000000-0000-4000-8000-000000000002', 1, 'draft', '{}', '{}', '{}');
select t_refused('trigger: a direct update to final with no consent is refused',
  $q$update advance_recommendations set status = 'final'
      where client_id = 'c0000000-0000-4000-8000-000000000002'$q$, 'signed consent form must be recorded');
select t_refused('trigger: a direct update to final with another client''s form is refused',
  format($q$update advance_recommendations set status = 'final', consent_id = %L
              where client_id = 'c0000000-0000-4000-8000-000000000002'$q$, current_setting('test.k2')),
  'signed consent form must be recorded');
select t_refused('trigger: an insert straight to final with no consent is refused',
  $q$insert into advance_recommendations (client_id, version, status, input, computed, content)
     values ('c0000000-0000-4000-8000-000000000002', 9, 'final', '{}', '{}', '{}')$q$, 'signed consent form must be recorded');
select t_refused('trigger: a final report''s form cannot be swapped',
  format($q$update advance_recommendations set consent_id = %L where id = %L$q$,
         current_setting('test.k2'), current_setting('test.v1')), 'cannot be changed');
insert into advance_recommendations (client_id, version, status, input, computed, content)
values ('c0000000-0000-4000-8000-000000000001', 7, 'draft', '{}', '{}', '{}');
select t_refused('index: a used form cannot back a second final report, even written directly',
  format($q$update advance_recommendations set status = 'final', consent_id = %L
              where client_id = 'c0000000-0000-4000-8000-000000000001' and version = 7$q$, current_setting('test.k2')),
  'duplicate key');
select t_check('the client-2 draft is still a draft', (select status from advance_recommendations
  where client_id = 'c0000000-0000-4000-8000-000000000002' and version = 1) = 'draft');
