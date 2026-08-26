-- ============================================================
-- Key Wellness — M4 live verification (READ-ONLY)
--
-- Run in the Supabase SQL Editor BEFORE applying
-- supabase_m4_contracts_workplans_invoices.sql and again AFTER. Every block
-- returns a single text column called `line`.
--
-- READ-ONLY. No insert, update, delete or DDL.
--
-- Run each block as its own statement.
-- ============================================================


-- ── V1 · Is it applied? ─────────────────────────────────────

select 'table  ' || rpad(t.name, 26) || ' : ' ||
       case when to_regclass('public.' || t.name) is not null
            then 'PRESENT' else 'absent' end as line
  from (values ('org_contracts'), ('contract_rates'), ('org_contacts'),
               ('work_plans'), ('invoices')) as t(name)
union all
select 'fn     ' || rpad(f.name, 26) || ' : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = f.name)
            then 'PRESENT' else 'absent' end
  from (values ('_invoice_period'), ('_invoice_owner'), ('_pack_contents'),
               ('_invoice_for_activity'), ('invoices_run_monthly'),
               ('invoice_pack'), ('invoice_hand_over'), ('invoice_mark_invoiced'),
               ('invoice_mark_paid'), ('contract_position'), ('org_work_plan'),
               ('work_plan_upsert'), ('activity_upsert')) as f(name)
union all
select 'dep    ' || rpad(d.name, 26) || ' : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = d.name)
            then 'PRESENT' else 'ABSENT — apply ' || d.from_phase || ' first' end
  from (values ('is_staff', 'M5'), ('is_ops_admin', 'the support work'))
         as d(name, from_phase)
 order by 1;


-- ── V2 · The columns M4 adds, and the one it must not touch ──
-- activity_type is a REPORTING INPUT, constrained to five values. If its check
-- constraint has changed, org_report_data() has changed with it and something
-- is wrong. The eight M4 values live in the NEW `format` column.

select 'program_activities.' || rpad(c.name, 18) || ' : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'program_activities'
                            and column_name = c.name)
            then 'PRESENT' else 'absent' end as line
  from (values ('work_plan_id'), ('format'), ('state'), ('delivered_at'),
               ('scheduled_at'), ('planned_month'), ('org_unit_id')) as c(name)
union all
select 'bookings.activity_id              : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'bookings'
                            and column_name = 'activity_id')
            then 'PRESENT' else 'absent' end
union all
select 'activity_type constraint          : ' ||
       coalesce((select pg_get_constraintdef(oid) from pg_constraint
                  where conname = 'program_activities_activity_type_check'),
                'none found')
union all
select 'invoices.state constraint         : ' ||
       coalesce((select pg_get_constraintdef(oid) from pg_constraint
                  where conname = 'invoices_state_check'), 'not applied yet')
 order by 1;


-- ── V3 · Nothing reporting counts has moved ─────────────────
-- Run BEFORE and AFTER. These numbers must be identical. M4 adds columns to
-- program_activities; it must add no rows and remove none.

select 'program_activities rows : ' || count(*)::text as line
  from program_activities
union all
select 'bookings rows           : ' || count(*)::text from bookings
union all
select 'organizations rows      : ' || count(*)::text from organizations;


-- ── V4 · The pack owner resolves to a real person ───────────
-- THERE IS NO ACCOUNTANT USER. The pack is owned by an ops admin. If the last
-- line says UNRESOLVED, the monthly job raises the invoice and attaches no
-- action, and nobody is told the pack is waiting.

-- value #>> '{}' on a JSON null returns SQL NULL, which is NOT the same as the
-- key being absent. 'null' here is the correct shipped state: it means "the
-- first ops admin", and the last line of this block resolves it.
select 'invoice.prepared_by_user_id : ' ||
       coalesce((select coalesce(value #>> '{}', 'null (= the first ops admin)')
                   from threshold_config
                  where key = 'invoice.prepared_by_user_id'), 'KEY MISSING') as line
union all
select 'invoice.prepare_day         : ' ||
       coalesce((select value #>> '{}' from threshold_config
                  where key = 'invoice.prepare_day'), 'KEY MISSING')
union all
select 'invoice.due_days            : ' ||
       coalesce((select value #>> '{}' from threshold_config
                  where key = 'invoice.due_days'), 'KEY MISSING')
union all
select 'resolves to                 : ' ||
       coalesce((select u.email from auth.users u
                  where u.id = (select nullif(value #>> '{}', '')::uuid
                                  from threshold_config
                                 where key = 'invoice.prepared_by_user_id')),
                (select 'first ops admin by email — ' || u.email
                   from admins a join auth.users u on lower(u.email) = lower(a.email)
                  order by u.email limit 1),
                'UNRESOLVED — no admin has an account');


-- ── V5 · The policies, and their shape ──────────────────────
-- Ten policies. invoices_read is is_ops_admin() ALONE: an earlier draft carried
-- an action-owner arm for an accountant who does not exist.

select tablename || ' · ' || rpad(policyname, 28) || ' : ' ||
       coalesce(qual, '(no using clause)') as line
  from pg_policies
 where schemaname = 'public'
   and tablename in ('org_contracts', 'contract_rates', 'org_contacts',
                     'work_plans', 'invoices')
 order by tablename, policyname;


-- ── V6 · No M4 helper is reachable ungated ──────────────────
-- CLAUDE.md's standing rule. Every ACL line should read
-- `postgres=X/postgres | service_role=X/postgres` and nothing more. Any
-- UNGATED line is a public read of the whole table through SECURITY DEFINER.

select 'UNGATED: ' || p.proname || '(' ||
       pg_get_function_identity_arguments(p.oid) || ')' as line
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
   and pg_get_function_result(p.oid) <> 'trigger'
   and (has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
   and p.proname in ('_invoice_period', '_invoice_owner', '_pack_contents',
                     '_invoice_for_activity')
union all
select 'ACL ' || rpad(p.proname, 22) || ' : ' ||
       coalesce(array_to_string(p.proacl, ' | '), '(default — GRANTED TO PUBLIC)')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_invoice_period', '_invoice_owner', '_pack_contents',
                     '_invoice_for_activity');


-- ── V7 · The trigger is transition-guarded ──────────────────
-- It must fire on a TRANSITION into attended, never on any update. A column
-- backfill fires every AFTER UPDATE trigger on bookings — M1's fired
-- trg_award_session_attended 22 times, and was safe only because that trigger
-- is transition-guarded. If this one is not, the next migration that touches
-- bookings invoices the entire back catalogue.

select 'trigger : ' || coalesce(
         (select tgname from pg_trigger
           where tgname = 'trg_booking_drives_activity' and not tgisinternal),
         'ABSENT') as line
union all
select 'def     : ' || coalesce(
         (select pg_get_triggerdef(oid) from pg_trigger
           where tgname = 'trg_booking_drives_activity'), '—')
union all
select 'guard   : ' ||
       case when exists (select 1 from pg_proc
                          where proname = 'kw_booking_drives_activity'
                            and prosrc like '%old.%')
            then 'reads OLD — transition-guarded'
            else 'DOES NOT READ OLD — fires on every update, STOP' end;


-- ── V8 · The cron job ───────────────────────────────────────
-- DAILY, and the function decides whether today is the prepare day. That keeps
-- invoice.prepare_day configurable without rescheduling cron. If pg_cron is not
-- enabled, the schedule block in the migration is a guarded no-op and NO PACK
-- IS EVER PREPARED — enable the extension, then re-run the migration.

-- A DO block with dynamic SQL, not a plain select: PostgreSQL PARSES the whole
-- statement before the CASE runs, so a direct `from cron.job` fails outright on
-- a database where pg_cron is not installed — which is exactly the database
-- this line most needs to report on. Reads the messages pane, writes nothing.

do $$
declare v text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'cron : pg_cron NOT ENABLED — no pack will ever be prepared';
    return;
  end if;
  execute $q$ select 'kw-monthly-invoices : ' || schedule || '  ->  ' || command
                from cron.job where jobname = 'kw-monthly-invoices' $q$ into v;
  raise notice 'cron : %', coalesce(v,
    'pg_cron enabled but the job is MISSING — re-run the migration');
end $$;


-- ── V9 · What is actually there ─────────────────────────────
-- Immediately after the apply both lines read (none), and that is correct:
-- M4 creates no contracts. Run it again after the first month.

select 'contracts : ' || coalesce(string_agg(
         o.name || ' (' || c.contract_kind || ', ' || c.status || ')', ', '), '(none)') as line
  from org_contracts c join organizations o on o.id = c.org_id
union all
select 'invoices  : ' || coalesce(string_agg(
         to_char(i.period_start, 'Mon YYYY') || ' ' || i.kind || ' ' || i.state, ', '),
         '(none)')
  from invoices i;


-- ── V10 · The scan bucket is private ────────────────────────
-- The scan is optional evidence Lone attaches at the invoiced step. A public
-- bucket would put client invoices on the open internet.

-- A DO block for the same reason as V8: storage.buckets is PARSED whether or
-- not the CASE reaches it, and it does not exist on a plain PostgreSQL database
-- (the local test harness has no storage schema). The rollback guards the same
-- table the same way.

do $$
declare v_public boolean; n int;
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'bucket : no storage schema on this database';
    return;
  end if;
  execute $q$ select public from storage.buckets where id = 'invoice-scans' $q$
    into v_public;
  if v_public is null then
    raise notice 'bucket : invoice-scans ABSENT';
  elsif v_public then
    raise notice 'bucket : invoice-scans is PUBLIC — STOP';
  else
    execute $q$ select count(*) from storage.objects
                 where bucket_id = 'invoice-scans' $q$ into n;
    raise notice 'bucket : invoice-scans private, % file(s)', n;
  end if;
end $$;
