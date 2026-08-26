-- ============================================================
-- Key Wellness — M5 live verification (READ-ONLY)
--
-- Run in the Supabase SQL Editor BEFORE applying
-- supabase_m5_meetings_actions.sql and again AFTER. Save both outputs and
-- diff them. Every block returns a single text column called `line`.
--
-- READ-ONLY. V1–V5 are SELECTs; V6 is a DO block that only reads and emits
-- notices. Nothing here writes, not even transiently.
--
-- Constraint rejection and every policy assertion are proven locally instead,
-- in tests/m5-tests.sql — which, unlike the phase0 suite, runs its access
-- checks under `set role authenticated` so RLS is genuinely applied.
-- ============================================================


-- ── V1 · Which state is this database in? ───────────────────
select 'organizations.is_test      : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='organizations'
                            and column_name='is_test') then 'PRESENT' else 'absent' end as line
union all
select 'meetings                   : ' ||
       case when to_regclass('public.meetings') is not null then 'PRESENT' else 'absent' end
union all
select 'actions                    : ' ||
       case when to_regclass('public.actions') is not null then 'PRESENT' else 'absent' end
union all
select 'action_reminders           : ' ||
       case when to_regclass('public.action_reminders') is not null then 'PRESENT' else 'absent' end
union all
select 'is_staff()                 : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='is_staff')
            then 'PRESENT' else 'absent' end
union all
select 'pg_cron                    : ' ||
       case when exists (select 1 from pg_extension where extname='pg_cron')
            then 'INSTALLED' else 'NOT INSTALLED — reminders will not fire' end;


-- ── V2 · The deploy precondition: who can own an action? ────
-- actions.owner references auth.users, because notifications.user_id does.
-- Anyone listed as "no account" cannot own an action or receive a reminder.
-- Lone, Michelle and Laone must all appear with an account before M5 is
-- useful; Laone especially, since M4 gives her the invoice actions.
select 'admin  ' || a.email || '  ' ||
       case when u.id is null then '<-- NO ACCOUNT' else 'ok' end as line
  from admins a left join auth.users u on lower(u.email) = lower(a.email)
union all
select 'advisor ' || ad.email || '  ' ||
       case when u.id is null then '<-- NO ACCOUNT — cannot own an action' else 'ok' end
  from advisors ad
  left join auth.users u on u.id = ad.user_id or lower(u.email) = lower(ad.email)
 where ad.is_active
 order by 1;


-- ── V3 · Organisations, and which are hidden from ops ───────
-- AFTER applying, Test Co must read is_test = true. That is a manual update
-- in the deploy note; this migration names no organisation.
select o.name
       || '  active=' || o.is_active
       || case when exists (select 1 from information_schema.columns
                             where table_schema='public' and table_name='organizations'
                               and column_name='is_test')
               then '  is_test=' || (select x.is_test::text
                                       from organizations x where x.id = o.id)
               else '  (is_test column not present yet)' end
       as line
  from organizations o order by o.name;


-- ── V4 · Nothing else moved ─────────────────────────────────
-- M5 adds tables that no existing function reads. These totals must be
-- identical before and after.
select 'organizations rows         : ' || count(*)::text from organizations
union all
select 'bookings rows              : ' || count(*)::text from bookings
union all
select 'notifications rows         : ' || count(*)::text from notifications
union all
select 'notifications by type      : ' ||
       coalesce((select string_agg(t || '=' || c::text, ' / ' order by t)
                   from (select type t, count(*) c from notifications group by type) s), '(none)')
union all
select 'points_events rows         : ' || count(*)::text from points_events;


-- ── V5 · The policy surface M5 adds ─────────────────────────
-- AFTER: exactly 8 policies across meetings and actions, and ZERO on
-- action_reminders — it is reachable only from SECURITY DEFINER code.
select tablename || ' | ' || policyname || ' | ' || cmd
       || ' | USING ' || coalesce(qual,'-')
       || ' | CHECK ' || coalesce(with_check,'-') as line
  from pg_policies
 where schemaname = 'public'
   and tablename in ('meetings','actions','action_reminders')
 order by tablename, policyname;


-- ── V6 · Post-apply assertions (AFTER only) ─────────────────
do $$
declare
  n int;
begin
  if to_regclass('public.actions') is null then
    raise notice 'M5 not applied yet — the checks below are skipped.';
    return;
  end if;

  select count(*) into n from pg_policies
   where schemaname='public' and tablename in ('meetings','actions');
  raise notice 'eight policies on meetings+actions : %',
    case when n = 8 then 'OK' else 'FAIL (' || n || ')' end;

  select count(*) into n from pg_policies
   where schemaname='public' and tablename = 'action_reminders';
  raise notice 'action_reminders has no policy     : %',
    case when n = 0 then 'OK' else 'FAIL (' || n || ')' end;

  select count(*) into n from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname='public'
     and c.relname in ('meetings','actions','action_reminders') and c.relrowsecurity;
  raise notice 'RLS on all three tables            : %',
    case when n = 3 then 'OK' else 'FAIL (' || n || ')' end;

  raise notice 'reminder writer is not public      : %',
    case when not has_function_privilege('authenticated','action_reminders_run(date)','EXECUTE')
          and not has_function_privilege('anon','action_reminders_run(date)','EXECUTE')
         then 'OK' else 'FAIL' end;

  raise notice 'label helper is not public         : %',
    case when not has_function_privilege('authenticated','_action_label(uuid, text)','EXECUTE')
         then 'OK' else 'FAIL' end;

  raise notice 'the three RPCs are callable        : %',
    case when has_function_privilege('authenticated','tuesday_review_pack(date)','EXECUTE')
          and has_function_privilege('authenticated','tuesday_review_open(date)','EXECUTE')
          and has_function_privilege('authenticated',
                'action_upsert(text, uuid, date, uuid, text, uuid, uuid, uuid, uuid)','EXECUTE')
         then 'OK' else 'FAIL' end;

  raise notice 'Test Co is flagged is_test         : %',
    case when exists (select 1 from organizations where name = 'Test Co' and is_test)
         then 'OK'
         else 'NOT YET — run the deploy note update, or the Tuesday roll-call '
              'will show a test organisation' end;

  raise notice 'reminder schedule                  : %',
    case when exists (select 1 from pg_extension where extname='pg_cron')
         then 'pg_cron installed'
         else 'pg_cron NOT installed — enable it, then RE-RUN the migration' end;
end $$;
