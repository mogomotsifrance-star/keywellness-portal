-- ============================================================
-- Rollback — M6: physical is its own service line
--
-- Idempotent. Leaves ZERO objects behind.
--
-- ══ THIS RESTORES TWO DEFECTS ON PURPOSE ═══════════════════
--
-- A rollback puts back what was there, not an improved version. Running this
-- returns HR's report to counting PLANNED activities as delivered and to
-- including PSYCHOSOCIAL activities. If you are rolling back for an unrelated
-- reason, fix those two separately rather than living with them.
--
-- ══ IT REFUSES WHILE PHYSICAL ROWS EXIST ═══════════════════
--
-- Narrowing service_line back to two values would orphan every physical row.
-- It stops rather than deleting or silently re-classifying real work.
-- ============================================================

do $$
declare n int;
begin
  if to_regclass('public.service_lines') is null then
    raise notice 'M6 rollback: service_lines is absent. Nothing to do.';
    return;
  end if;

  select count(*) into n from (
    select 1 from bookings where service_line = 'physical'
    union all select 1 from program_activities where service_line = 'physical'
    union all select 1 from org_reports where service_line = 'physical'
    union all select 1 from content_items where service_line = 'physical'
    union all select 1 from contract_rates where service_line = 'physical') t;
  if n > 0 then
    raise exception 'M6 rollback: % row(s) are on the PHYSICAL line. Narrowing '
                    'service_line would orphan them. Re-classify them '
                    'deliberately first.', n;
  end if;
end $$;


-- ── 1. Predicates back to naming lines literally ────────────

create or replace function kw_can_see_booking(b bookings)
returns boolean language sql stable security definer set search_path = public, auth
as $f$
  select
    b.user_id = auth.uid()
    or (b.service_line = 'financial'
        and (is_admin()
          or b.advisor_id = current_advisor_id()
          or is_team_lead()
          or exists (select 1 from advisor_clients ac
                      where ac.advisor_id = current_advisor_id()
                        and (ac.member_user_id = b.user_id
                          or ac.id = b.advisor_client_id))))
    or (b.service_line = 'psychosocial'
        and (b.counsellor_id = current_counsellor_id()
          or is_psychosocial_admin()));
$f$;
revoke all on function kw_can_see_booking(bookings) from public, anon, authenticated;

create or replace function kw_can_see_activity(a program_activities)
returns boolean language sql stable security definer set search_path = public, auth
as $f$
  select a.service_line = 'financial' or is_psychosocial_admin() or is_counsellor();
$f$;
revoke all on function kw_can_see_activity(program_activities) from public, anon, authenticated;


-- ── 2. The bookings policies ────────────────────────────────

begin;

drop policy if exists bookings_financial_read on bookings;
create policy bookings_financial_read on bookings
  for select using (
    service_line = 'financial'
    and (is_admin() or advisor_id = current_advisor_id() or is_team_lead()
      or exists (select 1 from advisor_clients ac
                  where ac.advisor_id = current_advisor_id()
                    and (ac.member_user_id = bookings.user_id
                      or ac.id = bookings.advisor_client_id))));

drop policy if exists bookings_financial_admin_write on bookings;
create policy bookings_financial_admin_write on bookings
  for all using (is_admin() and service_line = 'financial')
          with check (is_admin() and service_line = 'financial');

drop policy if exists bookings_advisor_insert on bookings;
create policy bookings_advisor_insert on bookings
  for insert with check (advisor_id = current_advisor_id()
                         and booked_by = 'advisor' and service_line = 'financial');

drop policy if exists bookings_advisor_update on bookings;
create policy bookings_advisor_update on bookings
  for update using (advisor_id = current_advisor_id() and service_line = 'financial')
            with check (advisor_id = current_advisor_id() and service_line = 'financial');

drop policy if exists bookings_lead_update on bookings;
create policy bookings_lead_update on bookings
  for update using (is_team_lead() and service_line = 'financial')
            with check (is_team_lead() and service_line = 'financial');

drop policy if exists bookings_psychosocial_read on bookings;
create policy bookings_psychosocial_read on bookings
  for select using (service_line = 'psychosocial'
    and (counsellor_id = current_counsellor_id() or is_psychosocial_admin()));

drop policy if exists bookings_psychosocial_admin_write on bookings;
create policy bookings_psychosocial_admin_write on bookings
  for all using (is_psychosocial_admin() and service_line = 'psychosocial')
          with check (is_psychosocial_admin() and service_line = 'psychosocial');

drop policy if exists bookings_counsellor_insert on bookings;
create policy bookings_counsellor_insert on bookings
  for insert with check (counsellor_id = current_counsellor_id()
                         and service_line = 'psychosocial');

drop policy if exists bookings_counsellor_update on bookings;
create policy bookings_counsellor_update on bookings
  for update using (counsellor_id = current_counsellor_id()
                    and service_line = 'psychosocial')
            with check (counsellor_id = current_counsellor_id()
                        and service_line = 'psychosocial');

commit;


-- ── 3. Reporting, back to the pre-M6 filters ────────────────
-- Restores DEFECT 1 and DEFECT 2. See the header.

do $$
declare r record; v_def text; v_new text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = '_org_report_period_data'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def,
      '(select * from program_activities where not kw_line_is_confidential(service_line) and state in (''delivered'',''reported''))',
      'program_activities');
    v_new := replace(v_new,
      '(select * from bookings where not kw_line_is_confidential(service_line))',
      '(select * from bookings where service_line = ''financial'')');
    if v_new <> v_def then execute v_new; end if;
  end loop;
end $$;

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics';
  if v_def is null then return; end if;
  v_new := replace(v_def, 'not kw_line_is_confidential(service_line)',
                          'service_line = ''financial''');
  if v_new <> v_def then execute v_new; end if;
end $$;


-- ── 4. The checks, then the table ───────────────────────────

do $$
declare t text;
begin
  foreach t in array array['bookings','program_activities','org_reports','content_items'] loop
    execute format('alter table %I drop constraint if exists %I', t, t || '_service_line_check');
    execute format('alter table %I add constraint %I check (service_line in (%L,%L))',
                   t, t || '_service_line_check', 'financial', 'psychosocial');
  end loop;
  alter table contract_rates drop constraint if exists contract_rates_line_check;
  alter table contract_rates add constraint contract_rates_line_check
    check (service_line in ('financial','psychosocial'));
end $$;

drop function if exists kw_line_is_confidential(text);
drop table if exists service_lines;


-- ── 5. Clean-slate verification ─────────────────────────────

do $$
begin
  if to_regclass('public.service_lines') is not null then
    raise exception 'M6 rollback incomplete: service_lines survives';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'kw_line_is_confidential') then
    raise exception 'M6 rollback incomplete: kw_line_is_confidential survives';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosrc ~ 'kw_line_is_confidential') then
    raise exception 'M6 rollback: a function still calls the dropped helper';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public'
              and (coalesce(qual,'') ~ 'kw_line_is_confidential'
                or coalesce(with_check,'') ~ 'kw_line_is_confidential')) then
    raise exception 'M6 rollback: a policy still calls the dropped helper';
  end if;

  raise notice 'M6 rollback clean. NOTE: HR''s report once again counts planned '
               'activities as delivered and includes psychosocial ones.';
end $$;
