-- ============================================================
-- Rollback — M4: contracts, work plans, activities, billing handovers
-- Reverses supabase_m4_contracts_workplans_billing.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- ══ READ THIS BEFORE RUNNING IT ════════════════════════════
--
-- THIS DELETES CONTRACTS, WORK PLANS AND BILLING HANDOVERS. There is no
-- backup table, because unlike M1's session_mode these are whole rows rather
-- than an overwritten column — there is nothing to restore them from. Export
-- anything real first:
--
--   select * from org_contracts;
--   select * from contract_rates;
--   select * from work_plans;
--   select * from billing_handovers;
--
-- WHAT IT DOES NOT DELETE: the program_activities rows themselves. M4 only
-- ADDED columns to that table, so this drops the columns and leaves every row
-- — including the ones org_report_data() has always counted.
--
-- IT ALSO PUTS BACK A FUNCTION THAT WAS ALREADY LIVE. M4 replaced
-- tuesday_review_pack() to add the billing flag. Section 6 below restores M5's
-- body exactly, so the Tuesday review keeps working after a rollback instead
-- of calling a _billing_flags() that no longer exists.
--
-- ORDER: cron, then the trigger, then tuesday_review_pack (before the helper
-- it calls), then the functions, then the columns that reference the tables,
-- then the tables, then the rest of the columns. The M5 rollback learned this
-- the hard way — a policy that calls a function pins that function, a table
-- drop takes its policies with it, and a referencing column pins its parent
-- table.
-- ============================================================


-- ── 1. Unschedule ───────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      execute $c$ select cron.unschedule('kw-monthly-handovers') $c$;
      raise notice 'M4 rollback: cron job kw-monthly-handovers unscheduled.';
    exception when others then
      raise notice 'M4 rollback: no cron job to unschedule (%).', sqlerrm;
    end;
    -- The pre-rename name, in case an older M4 was applied first.
    begin
      execute $c$ select cron.unschedule('kw-monthly-invoices') $c$;
      raise notice 'M4 rollback: legacy cron job kw-monthly-invoices unscheduled.';
    exception when others then null;
    end;
  end if;
end $$;


-- ── 2. The trigger, before the function it calls ────────────
drop trigger if exists trg_booking_drives_activity on bookings;
drop function if exists kw_booking_drives_activity();


-- ── 3. Put tuesday_review_pack() back to its M5 body ────────
-- Restored EXACTLY as supabase_m5_meetings_actions.sql section 10 defines it:
-- no 'billing' key, and needs_decision back to "an open action past its due
-- date". This must happen BEFORE _billing_flags is dropped, or the Tuesday
-- review calls a function that is not there.

create or replace function tuesday_review_pack(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Africa/Gaborone')::date);
  v_prev uuid;
  v_this uuid;
begin
  if not is_staff() then
    raise exception 'not authorised';
  end if;

  select id into v_this
    from meetings
   where kind = 'tuesday_review' and held_on = v_date and org_id is null;

  select id into v_prev
    from meetings
   where kind = 'tuesday_review' and org_id is null and held_on < v_date
   order by held_on desc
   limit 1;

  return jsonb_build_object(
    'as_of',               v_date,
    'meeting_id',          v_this,
    'previous_meeting_id', v_prev,

    'completion_rate', (
      select case when count(*) filter (where denom) = 0 then null
                  else round(100.0 * count(*) filter (where a.state = 'done')
                             / count(*) filter (where denom), 1)
             end
        from (
          select a.*,
                 (a.state in ('done','open')
                  or (a.state = 'dropped'
                      and exists (select 1 from actions s where s.carried_from = a.id))) as denom
            from actions a
           where v_prev is not null and a.meeting_id = v_prev
        ) a
    ),

    'organisations', coalesce((
      select jsonb_agg(x order by x ->> 'name')
        from (
          select jsonb_build_object(
            'org_id',   o.id,
            'name',     o.name,
            'last_week', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', a.id, 'title', a.title, 'owner', a.owner,
                       'due_date', a.due_date, 'state', a.state,
                       'label', _action_label(a.id, a.state)
                     ) order by a.due_date)
                from actions a
               where v_prev is not null and a.meeting_id = v_prev and a.org_id = o.id
            ), '[]'::jsonb),
            'open_now', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', a.id, 'title', a.title, 'owner', a.owner,
                       'due_date', a.due_date,
                       'overdue', a.due_date < v_date
                     ) order by a.due_date)
                from actions a
               where a.state = 'open' and a.org_id = o.id
            ), '[]'::jsonb),
            'open_count', (
              select count(*) from actions a
               where a.state = 'open' and a.org_id = o.id),
            'needs_decision', exists (
              select 1 from actions a
               where a.state = 'open' and a.org_id = o.id and a.due_date < v_date)
          ) as x
          from organizations o
         where o.is_active and not o.is_test
        ) s
    ), '[]'::jsonb),

    'unassigned', jsonb_build_object(
      'last_week', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'title', a.title, 'owner', a.owner,
                 'due_date', a.due_date, 'state', a.state,
                 'label', _action_label(a.id, a.state)
               ) order by a.due_date)
          from actions a
         where v_prev is not null and a.meeting_id = v_prev and a.org_id is null
      ), '[]'::jsonb),
      'open_now', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'title', a.title, 'owner', a.owner,
                 'due_date', a.due_date, 'overdue', a.due_date < v_date
               ) order by a.due_date)
          from actions a
         where a.state = 'open' and a.org_id is null
      ), '[]'::jsonb)
    )
  );
end $$;

grant execute on function tuesday_review_pack(date) to authenticated;


-- ── 4. The RPCs and the internals ───────────────────────────
drop function if exists activity_upsert(uuid, text, uuid, uuid, text, text, text, text,
                                        date, date, int, text);
drop function if exists work_plan_upsert(uuid, text, date, date, uuid, uuid, text, text);
drop function if exists org_work_plan(uuid);
drop function if exists contract_position(uuid, date);
drop function if exists _billing_flags(uuid);
drop function if exists handover_cancel(uuid, text);
drop function if exists handover_confirm_invoiced(uuid);
drop function if exists handover_mark_handed_over(uuid);
drop function if exists handover_pack(uuid);
drop function if exists handovers_run_monthly(date, boolean);
drop function if exists _handover_for_activity(uuid);
drop function if exists _pack_contents(uuid, timestamptz, timestamptz);
drop function if exists _handover_owner();
drop function if exists _handover_period(date);


-- ── 5. The tables ───────────────────────────────────────────
-- billing_handovers first: it references org_contracts, program_activities
-- and actions.
drop table if exists billing_handovers;
drop table if exists contract_rates;

-- work_plans cannot go while program_activities.work_plan_id still references
-- it. A referencing COLUMN pins its parent table exactly as a policy pins the
-- function it calls, and DROP ... CASCADE is the wrong answer: it would take
-- the column silently and leave section 6 looking like it had done the work.
alter table program_activities drop column if exists work_plan_id;

drop table if exists work_plans;
drop table if exists org_contracts;
drop table if exists org_contacts;


-- ── 6. The remaining columns M4 added ───────────────────────
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


-- ── 7. Configuration ────────────────────────────────────────
delete from threshold_config
 where key in ('invoice.prepared_by_user_id', 'invoice.prepare_day', 'invoice.due_days');


-- ── 8. Clean-slate verification ─────────────────────────────

do $$
declare n int;
begin
  select
      (select count(*) from pg_tables where schemaname='public'
        and tablename in ('org_contracts','contract_rates','org_contacts',
                          'work_plans','billing_handovers','invoices'))
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
        where ns.nspname='public'
          and p.proname in ('_handover_period','_handover_owner','_pack_contents',
                            '_handover_for_activity','kw_booking_drives_activity',
                            'handovers_run_monthly','handover_pack',
                            'handover_mark_handed_over','handover_confirm_invoiced',
                            'handover_cancel','_billing_flags',
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

  -- The Tuesday review must still work, and must no longer carry the flag.
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                  where ns.nspname='public' and p.proname='tuesday_review_pack') then
    raise exception 'M4 rollback: tuesday_review_pack is missing — M5 is broken';
  end if;
  if exists (select 1 from pg_proc where proname='tuesday_review_pack'
              and prosrc like '%_billing_flags%') then
    raise exception 'M4 rollback: tuesday_review_pack still calls _billing_flags';
  end if;

  raise notice 'M4 rollback clean: zero leftover objects, and the Tuesday '
               'review is back to its M5 shape.';
end $$;
