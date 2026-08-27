-- ============================================================
-- Key Wellness — M4 live verification (READ-ONLY)
--
-- Run in the Supabase SQL Editor BEFORE applying
-- supabase_m4_contracts_workplans_billing.sql and again AFTER.
--
-- READ-ONLY. No insert, update, delete or DDL.
-- Run each block as its own statement.
--
-- ══ V0 IS THE ONE THAT MATTERS MOST ════════════════════════
-- M4 replaces tuesday_review_pack(), which is ALREADY LIVE. V0 captures what
-- it returns today so the after-run can be diffed against it. Everything else
-- in M4 only adds, and adds cannot break what is there.
-- ============================================================


-- ── V0 · The Tuesday review, BEFORE and AFTER ───────────────
-- Run this BEFORE the apply and SAVE THE OUTPUT.
--
-- EXPECTED DIFF: every organisation gains a `billing` key. `needs_decision`
-- may turn true for an organisation with a late retainer period, and that is
-- the whole point. Everything else — as_of, meeting_id, previous_meeting_id,
-- completion_rate, last_week, open_now, open_count, unassigned — must be
-- IDENTICAL. Anything else moving is a fault: roll back and stop.

-- A DO BLOCK, not two statements. set_config(..., true) is TRANSACTION-LOCAL,
-- and psql and the Supabase SQL editor each commit between statements, so a
-- claim set in one statement is already gone by the next and the call comes
-- back 'not authorised'. Setting it and reading it in the same block is the
-- only shape that works.

do $$
declare v jsonb; o jsonb; n int := 0;
begin
  perform set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);
  v := tuesday_review_pack();

  raise notice 'as_of              : %', v ->> 'as_of';
  raise notice 'meeting_id         : %', coalesce(v ->> 'meeting_id', '(none)');
  raise notice 'completion_rate    : %', coalesce(v ->> 'completion_rate', 'null');
  raise notice 'unassigned open    : %',
    jsonb_array_length(v -> 'unassigned' -> 'open_now');

  for o in select e from jsonb_array_elements(v -> 'organisations') e loop
    n := n + 1;
    raise notice '% | open=% | needs_decision=% | last_week=% | open_now=% | billing=%',
      rpad(o ->> 'name', 24),
      o ->> 'open_count',
      o ->> 'needs_decision',
      jsonb_array_length(o -> 'last_week'),
      jsonb_array_length(o -> 'open_now'),
      -- Absent BEFORE the apply, an array AFTER it. That is the whole diff.
      coalesce((o -> 'billing')::text, 'MISSING (not applied yet)');
  end loop;

  raise notice '% organisation(s).', n;
end $$;


-- ── V1 · Is it applied? ─────────────────────────────────────

select 'table  ' || rpad(t.name, 24) || ' : ' ||
       case when to_regclass('public.' || t.name) is not null
            then 'PRESENT' else 'absent' end as line
  from (values ('org_contracts'), ('contract_rates'), ('org_contacts'),
               ('work_plans'), ('billing_handovers')) as t(name)
union all
select 'fn     ' || rpad(f.name, 24) || ' : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = f.name)
            then 'PRESENT' else 'absent' end
  from (values ('_handover_period'), ('_handover_owner'), ('_pack_contents'),
               ('_handover_for_activity'), ('_billing_flags'),
               ('handovers_run_monthly'), ('handover_pack'),
               ('handover_mark_handed_over'), ('handover_confirm_invoiced'),
               ('handover_cancel'), ('contract_position'), ('org_work_plan'),
               ('work_plan_upsert'), ('activity_upsert')) as f(name)
union all
select 'GONE   ' || rpad(g.name, 24) || ' : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = g.name)
            then 'STILL PRESENT — FAULT' else 'correctly absent' end
  from (values ('invoice_mark_paid'), ('handover_mark_paid'),
               ('invoice_pack'), ('invoices_run_monthly')) as g(name)
 order by 1;


-- ── V2 · Nothing claims to know what Sage holds ─────────────
-- The rule: invoices are produced in Sage, this system never sees one, and no
-- column or state may imply otherwise.

select 'states allowed        : ' ||
       coalesce((select pg_get_constraintdef(oid) from pg_constraint
                  where conname = 'billing_handovers_state_check'), 'not applied yet') as line
union all
select 'no paid state         : ' ||
       case when coalesce((select pg_get_constraintdef(oid) from pg_constraint
                            where conname='billing_handovers_state_check'), '') ~* '\mpaid\M'
            then 'FAULT — a paid state exists' else 'ok' end
union all
select 'no overdue state      : ' ||
       case when coalesce((select pg_get_constraintdef(oid) from pg_constraint
                            where conname='billing_handovers_state_check'), '') ~* '\moverdue\M'
            then 'FAULT — an overdue state exists' else 'ok' end
union all
select 'no scan/paid/due cols : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='billing_handovers'
                            and column_name in ('scan_path','paid_at','due_date'))
            then 'FAULT — a column describes a document in Sage' else 'ok' end
union all
select 'confirmation columns  : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='billing_handovers'
                            and column_name = 'invoice_confirmed_at')
            then 'present (invoice_confirmed_by / _at)' else 'absent' end;


-- ── V3 · The columns M4 adds, and the one it must not touch ──
-- activity_type is a REPORTING INPUT constrained to five values. If its check
-- constraint has changed, org_report_data() has changed with it.

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
                  where conname = 'program_activities_activity_type_check'), 'none found')
 order by 1;


-- ── V4 · Nothing reporting counts has moved ─────────────────
-- Run BEFORE and AFTER. Identical, or stop.

select 'program_activities rows : ' || count(*)::text as line from program_activities
union all
select 'bookings rows           : ' || count(*)::text from bookings
union all
select 'organizations rows      : ' || count(*)::text from organizations
union all
select 'actions rows            : ' || count(*)::text from actions;


-- ── V5 · The pack owner resolves to a real person ───────────
-- There is NO accountant user. The pack is owned by an ops admin — Lone.

select 'invoice.prepared_by_user_id : ' ||
       coalesce((select coalesce(value #>> '{}', 'null (= the first ops admin)')
                   from threshold_config where key = 'invoice.prepared_by_user_id'),
                'KEY MISSING') as line
union all
select 'invoice.prepare_day         : ' ||
       coalesce((select value #>> '{}' from threshold_config
                  where key = 'invoice.prepare_day'), 'KEY MISSING')
union all
select 'invoice.due_days            : ' ||
       coalesce((select value #>> '{}' from threshold_config
                  where key = 'invoice.due_days'),
                'correctly absent — the handover carries no date')
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


-- ── V6 · The policies ───────────────────────────────────────
-- Ten, across the five new tables. billing_handovers is ops-admin only.

select tablename || ' · ' || rpad(policyname, 30) || ' : ' ||
       coalesce(qual, '(no using clause)') as line
  from pg_policies
 where schemaname = 'public'
   and tablename in ('org_contracts','contract_rates','org_contacts',
                     'work_plans','billing_handovers')
 order by tablename, policyname;


-- ── V7 · No M4 helper is reachable ungated ──────────────────
-- CLAUDE.md's standing rule. Every ACL should read
-- `postgres=X/postgres | service_role=X/postgres` and nothing more.

select 'UNGATED: ' || p.proname || '(' ||
       pg_get_function_identity_arguments(p.oid) || ')' as line
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
   and pg_get_function_result(p.oid) <> 'trigger'
   and (has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
   and p.proname in ('_handover_period','_handover_owner','_pack_contents',
                     '_handover_for_activity','_billing_flags')
union all
select 'ACL ' || rpad(p.proname, 24) || ' : ' ||
       coalesce(array_to_string(p.proacl, ' | '), '(default — GRANTED TO PUBLIC)')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_handover_period','_handover_owner','_pack_contents',
                     '_handover_for_activity','_billing_flags');


-- ── V8 · The trigger is transition-guarded ──────────────────
-- It must fire on a TRANSITION into attended, never on any update. A column
-- backfill fires every AFTER UPDATE trigger on bookings — M1's fired
-- trg_award_session_attended 22 times, and was safe only because that trigger
-- is transition-guarded. If this one is not, the next migration that touches
-- bookings raises a handover for the entire back catalogue.

select 'trigger : ' || coalesce(
         (select tgname from pg_trigger
           where tgname = 'trg_booking_drives_activity' and not tgisinternal), 'ABSENT') as line
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


-- ── V9 · The cron job ───────────────────────────────────────
-- A DO block, not a plain select: PostgreSQL parses the whole statement before
-- a CASE can guard it, and cron.job does not exist without pg_cron.

do $$
declare v text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'cron : pg_cron NOT ENABLED — no handover will ever be prepared';
    return;
  end if;
  execute $q$ select 'kw-monthly-handovers : ' || schedule || '  ->  ' || command
                from cron.job where jobname = 'kw-monthly-handovers' $q$ into v;
  raise notice 'cron : %', coalesce(v,
    'pg_cron enabled but the job is MISSING — re-run the migration');
end $$;


-- ── V10 · What is actually there ────────────────────────────
-- Immediately after the apply both lines read (none), and that is correct:
-- M4 creates no contracts.

select 'contracts : ' || coalesce(string_agg(
         o.name || ' (' || c.contract_kind || ', ' || c.status || ')', ', '), '(none)') as line
  from org_contracts c join organizations o on o.id = c.org_id
union all
select 'handovers : ' || coalesce(string_agg(
         coalesce(to_char(h.period_start, 'Mon YYYY'), 'engagement')
         || ' ' || h.kind || ' ' || h.state, ', '), '(none)')
  from billing_handovers h;
