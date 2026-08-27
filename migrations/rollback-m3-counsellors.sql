-- ============================================================
-- Rollback — M3, both parts
-- Reverses supabase_m3_part1_confidentiality_boundary.sql and
--          supabase_m3_part2_definer_sweep.sql
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- ══ WHAT A ROLLBACK HERE DOES AND DOES NOT DO ══════════════
--
-- It restores the schema. IT DOES NOT UNDO A DISCLOSURE. If a counselling
-- booking was read by someone who should not have seen it, dropping the
-- policies afterwards does not unread it. That asymmetry is the entire reason
-- M3 goes to a branch first, and it is why this file exists mainly to make the
-- BRANCH disposable rather than to be run on live.
--
-- ══ THIS DELETES CASE DATA ═════════════════════════════════
--
-- counselling_notes, counselling_referrals, counsellor_clients, session_themes
-- and the counsellors themselves. There is no backup table: these are whole
-- rows, and a note is the most sensitive row in the system. On a branch that
-- is the point. ON LIVE, EXPORT FIRST OR DO NOT RUN IT.
--
-- ══ WHAT IT DOES NOT TOUCH ═════════════════════════════════
--
-- psychosocial_admins and is_psychosocial_admin(). Those are M4a's, not M3's.
-- Their rollback is migrations/rollback-m4a-ownership-and-roles.sql.
--
-- ORDER: restore the definer functions BEFORE dropping the predicates they
-- call, and restore the bookings policies BEFORE dropping the counsellor
-- objects those policies name. A policy pins the function it calls, and a
-- function pins the type it takes.
-- ============================================================


-- ── 1. Un-filter the definer functions ──────────────────────
-- The reverse of Part 2's substitution: strip the filtered subquery back to
-- the bare table. Done from each function's own definition, so only the read
-- shape changes.

-- THE OIDS ARE SNAPSHOTTED FIRST, ON PURPOSE. Iterating a cursor over pg_proc
-- while CREATE OR REPLACE-ing the rows it is walking makes the loop lose its
-- place: it visits some functions and silently skips others. This un-filtered
-- 3 of 12 before the array was introduced, and reported nothing wrong.
do $$
declare
  v_oids oid[];
  v_oid  oid;
  v_def  text;
  v_new  text;
  n      int := 0;
begin
  select coalesce(array_agg(p.oid), '{}')
    into v_oids
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and (p.prosrc like '%kw_can_see_booking%' or p.prosrc like '%kw_can_see_activity%')
     and p.proname not in ('kw_can_see_booking','kw_can_see_activity');

  foreach v_oid in array v_oids loop
    v_def := pg_get_functiondef(v_oid);
    v_new := replace(v_def,
      '(select * from bookings where kw_can_see_booking(bookings))', 'bookings');
    v_new := replace(v_new,
      '(select * from program_activities where kw_can_see_activity(program_activities))',
      'program_activities');
    if v_new <> v_def then
      execute v_new;
      n := n + 1;
    end if;
  end loop;

  -- Prove it, rather than trusting the loop.
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public'
                and p.prosrc like '%kw_can_see_booking%'
                and p.proname not in ('kw_can_see_booking')) then
    raise exception 'M3 rollback: functions still call kw_can_see_booking after '
                    'un-filtering % of them', n;
  end if;

  raise notice 'M3 rollback: % function(s) un-filtered.', n;
end $$;


-- ── 2. Put the reporting function back ──────────────────────
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='_org_report_period_data';

  if v_def is not null then
    v_new := replace(v_def,
      '(select * from bookings where service_line = ''financial'')', 'bookings');
    if v_new <> v_def then
      execute v_new;
      raise notice 'M3 rollback: _org_report_period_data counts both lines again.';
    end if;
  end if;
end $$;


-- ── 3. Restore the bookings policies, as M3 found them ──────
-- Including the two defects, because a rollback restores what was there rather
-- than an improved version: bookings_admin's un-lowered email comparison and
-- bookings_self's duplication of bookings_own. If you are rolling back and
-- intend to stay rolled back, fix those separately and deliberately.

begin;

drop policy if exists bookings_own                       on bookings;
drop policy if exists bookings_member_respond            on bookings;
drop policy if exists bookings_financial_read            on bookings;
drop policy if exists bookings_financial_admin_write     on bookings;
drop policy if exists bookings_advisor_insert            on bookings;
drop policy if exists bookings_advisor_update            on bookings;
drop policy if exists bookings_lead_update               on bookings;
drop policy if exists bookings_psychosocial_read         on bookings;
drop policy if exists bookings_psychosocial_admin_write  on bookings;
drop policy if exists bookings_counsellor_insert         on bookings;
drop policy if exists bookings_counsellor_update         on bookings;

-- And the legacy names this block is about to create, so a second rollback
-- replaces rather than collides.
drop policy if exists bookings_admin           on bookings;
drop policy if exists bookings_admin_all       on bookings;
drop policy if exists bookings_self            on bookings;
drop policy if exists bookings_advisor_select  on bookings;

create policy bookings_admin on bookings
  for all using ((auth.jwt() ->> 'email') in (select admins.email from admins))
          with check ((auth.jwt() ->> 'email') in (select admins.email from admins));

create policy bookings_admin_all on bookings
  for all using (is_admin()) with check (is_admin());

create policy bookings_own on bookings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy bookings_self on bookings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy bookings_advisor_select on bookings
  for select using (
    advisor_id = current_advisor_id()
    or is_team_lead()
    or exists (select 1 from advisor_clients ac
                where ac.advisor_id = current_advisor_id()
                  and (ac.member_user_id = bookings.user_id
                    or ac.id = bookings.advisor_client_id))
  );

create policy bookings_advisor_insert on bookings
  for insert with check (advisor_id = current_advisor_id() and booked_by = 'advisor');

create policy bookings_advisor_update on bookings
  for update using (advisor_id = current_advisor_id())
            with check (advisor_id = current_advisor_id());

create policy bookings_lead_update on bookings
  for update using (is_team_lead()) with check (is_team_lead());

create policy bookings_member_respond on bookings
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

commit;


-- ── 4. Put is_staff() back ──────────────────────────────────
create or replace function is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select is_admin() or is_advisor();     -- M3: or is_counsellor()
$$;

grant execute on function is_staff() to authenticated;


-- ── 5. Put the M4/M5 staff reads back ───────────────────────
drop policy if exists org_contracts_admin_read on org_contracts;
drop policy if exists org_contracts_staff_read on org_contracts;
create policy org_contracts_staff_read on org_contracts for select using (is_staff());

drop policy if exists contract_rates_admin_read on contract_rates;
drop policy if exists contract_rates_staff_read on contract_rates;
create policy contract_rates_staff_read on contract_rates for select using (is_staff());

drop policy if exists org_contacts_admin_read on org_contacts;
drop policy if exists org_contacts_staff_read on org_contacts;
create policy org_contacts_staff_read on org_contacts for select using (is_staff());


-- ── 6. kw_unit_label ────────────────────────────────────────
-- Restored to anon-callable, which is what M3 found. It was flagged as a
-- finding rather than a fault, so the rollback returns it rather than keeping
-- an improvement M3 is no longer around to justify.
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'kw_unit_label') then
    execute 'grant execute on function kw_unit_label(uuid) to public, anon';
  end if;
end $$;


-- ── 7. Teardown, in dependency order ────────────────────────
--
-- The order below was arrived at by having PostgreSQL refuse three times, and
-- each refusal is worth naming because none of them is obvious from reading
-- the migration:
--
--   * `session_themes_counsellor` is a POLICY ON session_themes that reads
--     bookings.counsellor_id. A policy on one table pins a column of another.
--   * kw_can_see_booking takes `bookings` as its ARGUMENT TYPE and reads
--     b.counsellor_id, so it pins that column too.
--   * bookings.counsellor_id and .counsellor_client_id are FOREIGN KEYS into
--     counsellors and counsellor_clients, so those tables cannot go first.
--
-- Hence: things that READ the columns, then the columns, then the tables the
-- columns pointed at. DROP ... CASCADE would resolve all three and is the
-- wrong answer — it would silently take whatever else happened to depend on
-- them and leave the verification block at the end reporting success.

-- 7a. Everything that reads bookings.counsellor_id.
drop function if exists theme_counts(uuid, date, date);
drop function if exists referral_fact_list();
drop function if exists kw_can_see_booking(bookings);
drop function if exists kw_can_see_activity(program_activities);
drop table if exists session_themes;
drop table if exists theme_taxonomy;
drop table if exists counselling_referrals;
drop table if exists counselling_notes;

-- 7b. Now the columns themselves.
alter table bookings drop constraint if exists bookings_one_practitioner;
alter table bookings drop constraint if exists bookings_counsellor_is_psychosocial;
alter table bookings drop column if exists counsellor_client_id;
alter table bookings drop column if exists counsellor_id;

-- 7c. And finally what they pointed at.
drop table if exists counsellor_clients;
drop function if exists is_counsellor();
drop function if exists current_counsellor_id();
drop table if exists counsellors;


-- ── 10. Clean-slate verification ────────────────────────────

do $$
declare n int;
begin
  select
      (select count(*) from pg_tables where schemaname='public'
        and tablename in ('counsellors','counsellor_clients','counselling_notes',
                          'counselling_referrals','theme_taxonomy','session_themes'))
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
        where ns.nspname='public'
          and p.proname in ('is_counsellor','current_counsellor_id',
                            'kw_can_see_booking','kw_can_see_activity',
                            'theme_counts','referral_fact_list'))
    + (select count(*) from information_schema.columns
        where table_schema='public' and table_name='bookings'
          and column_name in ('counsellor_id','counsellor_client_id'))
    into n;

  if n <> 0 then
    raise exception 'M3 rollback incomplete: % object(s) left behind', n;
  end if;

  -- No function may still be reaching for a predicate that no longer exists.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public'
     and (p.prosrc like '%kw_can_see_booking%' or p.prosrc like '%kw_can_see_activity%');
  if n <> 0 then
    raise exception 'M3 rollback: % function(s) still call a dropped predicate', n;
  end if;

  -- The nine original bookings policies must be back, or the advisor portal
  -- is broken in a way that is not obvious until someone opens it.
  select count(*) into n from pg_policies
   where schemaname='public' and tablename='bookings';
  if n <> 9 then
    raise exception 'M3 rollback: expected 9 bookings policies, found %', n;
  end if;

  -- M4a's objects must be untouched: they are not M3's to remove.
  if to_regclass('public.psychosocial_admins') is null then
    raise exception 'M3 rollback: psychosocial_admins was removed — it belongs '
                    'to M4a, not to M3';
  end if;

  raise notice 'M3 rollback clean: zero leftover objects, the nine original '
               'bookings policies restored, M4a untouched. NOTE: this restored '
               'the schema, not the confidentiality of anything already read.';
end $$;
