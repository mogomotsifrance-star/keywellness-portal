-- ============================================================
-- Key Wellness — M6: physical is its own service line
--
-- Run AFTER M3b and M4b. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m6-physical-service-line.sql
-- Tests:    tests/m6-tests.sql
--
-- ══ WHAT THIS DOES, IN PLAIN LANGUAGE ══════════════════════
--
-- BOPEU's programme has three pillars: financial, psychosocial and PHYSICAL —
-- a health screening and two wellness challenges. The database had two service
-- lines, so those three rows had nowhere true to go.
--
-- This adds the third line, fixes the two reporting defects the first real
-- data exposed, and changes HOW the confidentiality boundary is expressed so
-- that adding a fourth line later cannot repeat the mistake below.
--
-- ══ WHY NOT JUST ADD 'physical' TO THE CHECK CONSTRAINTS ═══
--
-- Because that would make physical rows INVISIBLE, silently.
--
-- Twenty-two places hard-code the two-line split. Every read predicate names a
-- literal: `service_line = 'financial'` opens the door, `service_line =
-- 'psychosocial'` opens the counsellor's door. A 'physical' row matches
-- NEITHER — so it would exist, be billed, appear in nobody's list, and no
-- error would ever be raised.
--
-- And hand-editing twenty-two predicates is exactly the failure that produced
-- the defect being fixed here: M3 enumerated the split in two places and only
-- one was updated, which is why counselling sessions have been reaching HR's
-- report.
--
-- ══ THE FIX: ONE SOURCE OF TRUTH, FAIL-CLOSED ══════════════
--
-- `service_lines` says which lines exist and which are CONFIDENTIAL.
-- `kw_line_is_confidential(text)` reads it, and returns TRUE for a line it
-- does not recognise.
--
-- That default is the whole point. A line somebody adds without classifying it
-- is treated as confidential, so the failure mode of forgetting is that rows
-- are hidden from people who should see them — visible, annoying, complained
-- about within a day. The opposite default would hide nothing and leak
-- everything, silently, which is the failure nobody notices.
--
-- Predicates stop naming lines. They ask the question they actually mean:
--   "is this line confidential?" instead of "is this line psychosocial?"
--
-- ══ THE TWO REPORTING DEFECTS ══════════════════════════════
--
-- (1) PLANNED WORK WAS REPORTED AS IF IT HAPPENED. The program_activities
--     block counted every activity in the window regardless of state. BOPEU
--     Q3 reported 8 activities where only 4 were delivered — including two the
--     source document itself still marks Planned. Now counts delivered and
--     reported only.
--
-- (2) PSYCHOSOCIAL ACTIVITIES APPEARED IN HR'S REPORT. M3's split filtered the
--     BOOKINGS read and not the PROGRAM_ACTIVITIES read, so counselling group
--     sessions reached the organisation report with their titles. Now filtered
--     by the same confidentiality question as everything else.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES
--     A service_lines table appears with three rows. Five check constraints
--     admit 'physical'. Every read predicate stops naming a literal line.
--     HR's report loses psychosocial activities and planned activities.
--
--   DOES NOT CHANGE
--     No row's service_line is altered. Every existing row is 'financial' or
--     'psychosocial' and keeps exactly the visibility it has today —
--     'financial' is non-confidential, 'psychosocial' is confidential, which
--     is what the old literals said.
--     No booking, member, contract or activity is added or removed.
--
--   IF IT IS WRONG
--     The realistic failure is a line classified wrongly in service_lines, and
--     it is one UPDATE to correct. The dangerous direction — a confidential
--     line marked non-confidential — is guarded: the migration refuses to
--     finish if 'psychosocial' is not confidential.
-- ============================================================


-- ══ ORDERING: DO NOT RE-APPLY M3 PART 2 AFTER THIS ═════════
--
-- M3 Part 2 and this file both rewrite _org_report_period_data. M3 sets the
-- bookings filter to service_line = 'financial'; this replaces it with the
-- confidentiality question. Re-running M3 Part 2 afterwards would silently
-- put the older filter back and re-open both defects fixed in section 6.
--
-- M3 is applied and settled. It should not be re-run. If it ever must be,
-- apply this file again immediately afterwards.
-- ============================================================


-- ── 1. The lines, and which of them are confidential ────────

create table if not exists service_lines (
  key             text primary key,
  label           text not null,
  is_confidential boolean not null,
  sort_order      int not null default 0,
  is_active       boolean not null default true
);

comment on table service_lines is
  'The service lines and, crucially, WHICH ARE CONFIDENTIAL. Every read '
  'predicate asks this table rather than naming a line, so adding a line is '
  'one INSERT instead of an edit in twenty-two places. A line missing from '
  'here is treated as CONFIDENTIAL — see kw_line_is_confidential().';

insert into service_lines (key, label, is_confidential, sort_order) values
  ('financial',    'Financial wellness',    false, 10),
  ('psychosocial', 'Psychosocial support',  true,  20),
  ('physical',     'Physical wellness',     false, 30)
on conflict (key) do nothing;

alter table service_lines enable row level security;

drop policy if exists service_lines_read on service_lines;
create policy service_lines_read on service_lines for select using (true);

drop policy if exists service_lines_admin_write on service_lines;
create policy service_lines_admin_write on service_lines
  for all using (is_admin()) with check (is_admin());


-- ── 2. The question every predicate actually means ──────────
-- FAIL-CLOSED. An unrecognised line is confidential, so forgetting to
-- classify one hides rows from people who should see them — which somebody
-- complains about the same day. The opposite default leaks silently.

create or replace function kw_line_is_confidential(p_line text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select sl.is_confidential from service_lines sl where sl.key = p_line),
    true);
$$;

grant execute on function kw_line_is_confidential(text) to authenticated;


-- ── 3. The five check constraints ───────────────────────────
-- A CHECK cannot read a table, so these still enumerate. Section 8 asserts
-- they agree with service_lines, so adding a line to the table without
-- widening the checks fails loudly instead of at the first insert.

do $$
declare t text;
begin
  foreach t in array array['bookings','program_activities','org_reports','content_items'] loop
    execute format('alter table %I drop constraint if exists %I', t, t || '_service_line_check');
    execute format(
      'alter table %I add constraint %I check (service_line in (%L,%L,%L))',
      t, t || '_service_line_check', 'financial', 'psychosocial', 'physical');
  end loop;

  alter table contract_rates drop constraint if exists contract_rates_line_check;
  alter table contract_rates add constraint contract_rates_line_check
    check (service_line in ('financial','psychosocial','physical'));
end $$;


-- ── 4. The visibility predicates stop naming lines ──────────

create or replace function kw_can_see_booking(b bookings)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    -- The member's own row, whatever the line.
    b.user_id = auth.uid()

    -- A NON-CONFIDENTIAL line: admin, the booking's advisor, the team lead, or
    -- an advisor with that client. Physical joins financial here, which is the
    -- point — a health screening is not a secret.
    or (not kw_line_is_confidential(b.service_line)
        and (is_admin()
          or b.advisor_id = current_advisor_id()
          or is_team_lead()
          or exists (select 1 from advisor_clients ac
                      where ac.advisor_id = current_advisor_id()
                        and (ac.member_user_id = b.user_id
                          or ac.id = b.advisor_client_id))))

    -- A CONFIDENTIAL line: the booking's own counsellor, or a psychosocial
    -- admin. No clinical lead, no plain admin.
    or (kw_line_is_confidential(b.service_line)
        and (b.counsellor_id = current_counsellor_id()
          or is_psychosocial_admin()));
$$;

revoke all on function kw_can_see_booking(bookings) from public, anon, authenticated;

create or replace function kw_can_see_activity(a program_activities)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select not kw_line_is_confidential(a.service_line)
      or is_psychosocial_admin()
      or is_counsellor();
$$;

revoke all on function kw_can_see_activity(program_activities) from public, anon, authenticated;


-- ── 5. The bookings policies ────────────────────────────────
-- Same rewrite: the financial branch becomes the non-confidential branch, the
-- psychosocial branch becomes the confidential branch. Existing rows are
-- unaffected — 'financial' is non-confidential and 'psychosocial' is
-- confidential, which is exactly what the literals said.

begin;

drop policy if exists bookings_financial_read on bookings;
create policy bookings_financial_read on bookings
  for select using (
    not kw_line_is_confidential(service_line)
    and (is_admin()
      or advisor_id = current_advisor_id()
      or is_team_lead()
      or exists (select 1 from advisor_clients ac
                  where ac.advisor_id = current_advisor_id()
                    and (ac.member_user_id = bookings.user_id
                      or ac.id = bookings.advisor_client_id)))
  );

drop policy if exists bookings_financial_admin_write on bookings;
create policy bookings_financial_admin_write on bookings
  for all using (is_admin() and not kw_line_is_confidential(service_line))
          with check (is_admin() and not kw_line_is_confidential(service_line));

drop policy if exists bookings_advisor_insert on bookings;
create policy bookings_advisor_insert on bookings
  for insert with check (advisor_id = current_advisor_id()
                         and booked_by = 'advisor'
                         and not kw_line_is_confidential(service_line));

drop policy if exists bookings_advisor_update on bookings;
create policy bookings_advisor_update on bookings
  for update using (advisor_id = current_advisor_id()
                    and not kw_line_is_confidential(service_line))
            with check (advisor_id = current_advisor_id()
                        and not kw_line_is_confidential(service_line));

drop policy if exists bookings_lead_update on bookings;
create policy bookings_lead_update on bookings
  for update using (is_team_lead() and not kw_line_is_confidential(service_line))
            with check (is_team_lead() and not kw_line_is_confidential(service_line));

drop policy if exists bookings_psychosocial_read on bookings;
create policy bookings_psychosocial_read on bookings
  for select using (
    kw_line_is_confidential(service_line)
    and (counsellor_id = current_counsellor_id() or is_psychosocial_admin())
  );

drop policy if exists bookings_psychosocial_admin_write on bookings;
create policy bookings_psychosocial_admin_write on bookings
  for all using (is_psychosocial_admin() and kw_line_is_confidential(service_line))
          with check (is_psychosocial_admin() and kw_line_is_confidential(service_line));

drop policy if exists bookings_counsellor_insert on bookings;
create policy bookings_counsellor_insert on bookings
  for insert with check (counsellor_id = current_counsellor_id()
                         and kw_line_is_confidential(service_line));

drop policy if exists bookings_counsellor_update on bookings;
create policy bookings_counsellor_update on bookings
  for update using (counsellor_id = current_counsellor_id()
                    and kw_line_is_confidential(service_line))
            with check (counsellor_id = current_counsellor_id()
                        and kw_line_is_confidential(service_line));

commit;


-- ── 6. The two reporting defects ────────────────────────────
-- Rewritten from each overload's own definition, so only the two filters
-- change. OVERLOADS: _org_report_period_data exists twice and only the
-- four-argument one reads these tables — `select ... into` would patch one
-- arbitrarily and leave the other leaking, which is a mistake already made
-- once on this project.

do $$
declare
  r        record;
  v_def    text;
  v_new    text;
  n_seen   int := 0;
  n_fixed  int := 0;
begin
  for r in
    select p.oid, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = '_org_report_period_data'
  loop
    n_seen := n_seen + 1;
    v_def  := pg_get_functiondef(r.oid);

    -- Normalise first: a second apply must not wrap the subquery in itself.
    v_def := replace(v_def,
      '(select * from bookings where service_line = ''financial'')', 'bookings');
    v_def := replace(v_def,
      '(select * from program_activities where not kw_line_is_confidential(service_line) '
      || 'and state in (''delivered'',''reported''))', 'program_activities');
    -- AND M6's own bookings wrapper. Stripping only M3's shape means a second
    -- apply nests the subquery inside itself — the exact bug M3 Part 2 had,
    -- fixed there and not carried here until it bit on the idempotency re-run.
    v_def := replace(v_def,
      '(select * from bookings where not kw_line_is_confidential(service_line))',
      'bookings');

    v_new := v_def;

    -- Bookings: the line question, asked properly.
    v_new := regexp_replace(v_new, '(\mfrom\s+)bookings(\s+)(\w+)',
      '\1(select * from bookings where not kw_line_is_confidential(service_line))\2\3', 'gi');
    v_new := regexp_replace(v_new, '(\mjoin\s+)bookings(\s+)(\w+)',
      '\1(select * from bookings where not kw_line_is_confidential(service_line))\2\3', 'gi');

    -- Activities: DEFECT 2 (line) and DEFECT 1 (state) in one filter.
    v_new := regexp_replace(v_new, '(\mfrom\s+)program_activities(\s+)(\w+)',
      '\1(select * from program_activities where not kw_line_is_confidential(service_line) '
      || 'and state in (''delivered'',''reported''))\2\3', 'gi');
    v_new := regexp_replace(v_new, '(\mjoin\s+)program_activities(\s+)(\w+)',
      '\1(select * from program_activities where not kw_line_is_confidential(service_line) '
      || 'and state in (''delivered'',''reported''))\2\3', 'gi');

    if v_new <> v_def then
      execute v_new;
      n_fixed := n_fixed + 1;
      raise notice 'M6: _org_report_period_data(%) now reports non-confidential, '
                   'DELIVERED activity only', r.args;
    end if;
  end loop;

  if n_seen = 0 then raise exception 'M6: _org_report_period_data is missing'; end if;
  if n_fixed = 0 then
    raise exception 'M6: none of the % reporting overload(s) could be filtered — '
                    'do it BY HAND rather than leaving HR a number that includes '
                    'counselling and unfinished work.', n_seen;
  end if;
end $$;


-- ── 7. _dept_metrics, the same question ─────────────────────

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics';

  if v_def is null then
    raise notice 'M6: _dept_metrics is absent here.';
    return;
  end if;

  v_new := replace(v_def, 'service_line = ''financial''',
                          'not kw_line_is_confidential(service_line)');
  if v_new <> v_def then
    execute v_new;
    raise notice 'M6: _dept_metrics asks the confidentiality question.';
  end if;
end $$;


-- ── 8. Post-conditions ──────────────────────────────────────

do $$
declare bad text; n int;
begin
  -- The dangerous direction, guarded explicitly.
  if not (select is_confidential from service_lines where key = 'psychosocial') then
    raise exception 'M6: psychosocial is not marked confidential. Everything in '
                    'M3 rests on that being true.';
  end if;
  if (select is_confidential from service_lines where key = 'financial') then
    raise exception 'M6: financial is marked confidential — that would hide '
                    'every existing booking from everyone';
  end if;

  -- The checks and the table must agree, or a line exists that no row may hold.
  select string_agg(sl.key, ', ') into bad
    from service_lines sl
   where sl.is_active
     and (select pg_get_constraintdef(oid) from pg_constraint
           where conname = 'bookings_service_line_check') not like '%' || sl.key || '%';
  if bad is not null then
    raise exception 'M6: service_lines has % but the bookings check refuses it', bad;
  end if;

  -- No predicate may still name a line literally: that is how the two-line
  -- split got out of step with itself in the first place.
  select string_agg(policyname, ', ') into bad
    from pg_policies
   where schemaname = 'public' and tablename = 'bookings'
     and (coalesce(qual,'') ~ '''(financial|psychosocial|physical)'''
       or coalesce(with_check,'') ~ '''(financial|psychosocial|physical)''');
  if bad is not null then
    raise exception 'M6: these bookings policies still name a line literally: %', bad;
  end if;

  if (select prosrc from pg_proc where proname = 'kw_can_see_booking')
     ~ '''(financial|psychosocial|physical)''' then
    raise exception 'M6: kw_can_see_booking still names a line literally';
  end if;

  -- Defect 1 and defect 2, asserted at the source.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_org_report_period_data'
     and p.prosrc ~ 'program_activities'
     and p.prosrc !~ 'kw_line_is_confidential';
  if n > 0 then
    raise exception 'M6: % reporting overload(s) still report activities without '
                    'the confidentiality filter', n;
  end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_org_report_period_data'
     and p.prosrc ~ 'program_activities'
     and p.prosrc !~ 'delivered';
  if n > 0 then
    raise exception 'M6: % reporting overload(s) still count planned activities '
                    'as if they had happened', n;
  end if;

  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prosrc like '%from (select * from (select * from%';
  if bad is not null then
    raise exception 'M6: the filter is nested inside itself in: %', bad;
  end if;

  raise notice 'M6 applied. Three lines; physical is non-confidential. Predicates '
               'ask kw_line_is_confidential() rather than naming a line, and an '
               'unclassified line is treated as CONFIDENTIAL.';
end $$;
