-- ============================================================
-- Rollback — M4: contracts, work plans, activities, invoices
-- Reverses supabase_m4_contracts_workplans_invoices.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- THIS DELETES CONTRACTS, WORK PLANS AND INVOICES. Export anything real
-- first — there is no backup table, because unlike M1's session_mode these
-- are whole rows rather than an overwritten column:
--
--   select * from org_contracts;  select * from invoices;  select * from work_plans;
--
-- What it does NOT delete: the program_activities rows themselves. M4 only
-- ADDED columns to that table, so the rollback drops the columns and leaves
-- every row — including the ones org_report_data() has always counted.
--
-- ORDER: cron, then the trigger, then the functions, then the tables, then
-- the columns. The M5 rollback learned this the hard way — a policy that
-- calls a function pins that function, and a table drop takes its policies
-- with it.
-- ============================================================


-- ── 1. Unschedule ───────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      execute $c$ select cron.unschedule('kw-monthly-invoices') $c$;
      raise notice 'M4 rollback: cron job kw-monthly-invoices unscheduled.';
    exception when others then
      raise notice 'M4 rollback: no cron job to unschedule (%).', sqlerrm;
    end;
  end if;
end $$;


-- ── 2. The trigger, before the function it calls ────────────
drop trigger if exists trg_booking_drives_activity on bookings;
drop function if exists kw_booking_drives_activity();


-- ── 3. The RPCs and the internals ───────────────────────────
drop function if exists activity_upsert(uuid, text, uuid, uuid, text, text, text, text,
                                        date, date, int, text);
drop function if exists work_plan_upsert(uuid, text, date, date, uuid, uuid, text, text);
drop function if exists org_work_plan(uuid);
drop function if exists contract_position(uuid, date);
drop function if exists invoice_mark_paid(uuid);
drop function if exists invoice_mark_invoiced(uuid, text);
drop function if exists invoice_hand_over(uuid);
drop function if exists invoice_pack(uuid);
drop function if exists invoices_run_monthly(date, boolean);
drop function if exists _invoice_for_activity(uuid);
drop function if exists _pack_contents(uuid, timestamptz, timestamptz);
drop function if exists _invoice_owner();
drop function if exists _invoice_period(date);


-- ── 4. The tables ───────────────────────────────────────────
-- invoices first: it references org_contracts, program_activities and actions.
drop table if exists invoices;
drop table if exists contract_rates;

-- work_plans cannot go while program_activities.work_plan_id still references
-- it. A referencing COLUMN pins its parent table exactly as a policy pins the
-- function it calls (the M5 rollback lesson), and DROP ... CASCADE is the wrong
-- answer here: it would silently take the column with it and leave the rest of
-- section 5 looking like it had done the work.
alter table program_activities drop column if exists work_plan_id;

drop table if exists work_plans;
drop table if exists org_contracts;
drop table if exists org_contacts;


-- ── 5. The remaining columns M4 added ───────────────────────
-- The ROWS stay. Only the columns go. (work_plan_id went above, with its
-- parent table.)

alter table bookings drop column if exists activity_id;
alter table program_activities drop column if exists format;
alter table program_activities drop column if exists planned_month;
alter table program_activities drop column if exists planned_date;
alter table program_activities drop column if exists scheduled_at;
alter table program_activities drop column if exists delivered_at;
alter table program_activities drop column if exists state;
alter table program_activities drop column if exists practitioner_kind;
alter table program_activities drop column if exists practitioner_id;
alter table program_activities drop column if exists org_unit_id;
alter table program_activities drop column if exists webinar_id;
alter table program_activities drop column if exists notes;


-- ── 6. Configuration ────────────────────────────────────────
delete from threshold_config
 where key in ('invoice.prepared_by_user_id', 'invoice.prepare_day', 'invoice.due_days');


-- ── 7. The bucket ───────────────────────────────────────────
-- The bucket itself is left in place if it holds anything: dropping a storage
-- bucket destroys uploaded scans, and a rollback of the schema should not
-- destroy documents someone filed.

do $$
declare n int;
begin
  if to_regclass('storage.buckets') is null then return; end if;

  execute $p$ drop policy if exists invoice_scans_admin_all on storage.objects $p$;

  execute $q$ select count(*) from storage.objects where bucket_id = 'invoice-scans' $q$ into n;
  if n = 0 then
    delete from storage.buckets where id = 'invoice-scans';
    raise notice 'M4 rollback: empty invoice-scans bucket removed.';
  else
    raise notice 'M4 rollback: invoice-scans bucket KEPT — it holds % file(s). '
                 'Its policy is dropped, so only the service role can reach them.', n;
  end if;
end $$;


-- ── 8. Clean-slate verification ─────────────────────────────

do $$
declare n int;
begin
  select
      (select count(*) from pg_tables where schemaname='public'
        and tablename in ('org_contracts','contract_rates','org_contacts',
                          'work_plans','invoices'))
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
        where ns.nspname='public'
          and p.proname in ('_invoice_period','_invoice_owner','_pack_contents',
                            '_invoice_for_activity','kw_booking_drives_activity',
                            'invoices_run_monthly','invoice_pack','invoice_hand_over',
                            'invoice_mark_invoiced','invoice_mark_paid',
                            'contract_position','org_work_plan','work_plan_upsert',
                            'activity_upsert'))
    + (select count(*) from pg_trigger where tgname='trg_booking_drives_activity')
    + (select count(*) from information_schema.columns
        where table_schema='public' and table_name='program_activities'
          and column_name in ('work_plan_id','format','state','delivered_at','scheduled_at',
                              'planned_month','planned_date','practitioner_kind',
                              'practitioner_id','org_unit_id','webinar_id','notes'))
    + (select count(*) from information_schema.columns
        where table_schema='public' and table_name='bookings' and column_name='activity_id')
    + (select count(*) from threshold_config
        where key in ('invoice.prepared_by_user_id','invoice.prepare_day','invoice.due_days'))
    into n;

  if n <> 0 then
    raise exception 'M4 rollback incomplete: % object(s) left behind', n;
  end if;

  raise notice 'M4 rollback clean: zero leftover objects.';
end $$;
