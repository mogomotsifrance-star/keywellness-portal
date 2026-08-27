-- ============================================================
-- Rollback — M5: meetings, actions and reminders
-- Reverses supabase_m5_meetings_actions.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- ORDER MATTERS. The reminder notifications are deleted BEFORE the ledger
-- that identifies them is dropped — after that they are unidentifiable.
-- ============================================================


-- ── 1. Unschedule the cron job ──────────────────────────────
-- Guarded twice: pg_cron may never have been installed, and the job may never
-- have been scheduled. EXECUTE because a bare cron.unschedule fails to parse
-- when the schema is absent.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      execute $c$ select cron.unschedule('kw-action-reminders') $c$;
      raise notice 'M5 rollback: cron job kw-action-reminders unscheduled.';
    exception when others then
      raise notice 'M5 rollback: no cron job to unschedule (%).', sqlerrm;
    end;
  end if;
end $$;


-- ── 2. Remove the notifications M5 wrote ────────────────────
-- Only the ones this migration created: the ledger names them by id. A
-- reminder about an action that no longer exists is noise in a member's
-- notification list, and once step 3 drops the ledger there is no way to
-- tell which notifications those were.
--
-- Notifications of any other type are untouched.

do $$
declare
  n int := 0;
begin
  if to_regclass('public.action_reminders') is not null then
    delete from notifications
     where id in (select notification_id from action_reminders
                   where notification_id is not null);
    get diagnostics n = row_count;
    raise notice 'M5 rollback: % reminder notification(s) removed.', n;
  end if;
end $$;


-- ── 3. Drop the tables ──────────────────────────────────────
-- BEFORE the functions, not after. The policies on meetings and actions call
-- is_staff(), and PostgreSQL refuses to drop a function a live policy depends
-- on. Dropping the tables takes their policies, indexes and the
-- trg_actions_touch trigger with them, which frees is_staff() to go in step 4.
--
-- Dependency order within this step: action_reminders references actions,
-- actions references meetings.

drop table if exists action_reminders;
drop table if exists actions;
drop table if exists meetings;


-- ── 4. Drop the functions ───────────────────────────────────
-- Now that nothing refers to them. kw_touch_actions outlives its trigger, so
-- it needs its own drop.

drop function if exists action_upsert(text, uuid, date, uuid, text, uuid, uuid, uuid, uuid);
drop function if exists tuesday_review_pack(date);
drop function if exists tuesday_review_open(date);
drop function if exists action_reminders_run(date);
drop function if exists _action_label(uuid, text);
drop function if exists kw_touch_actions();
drop function if exists is_staff();


-- ── 5. Drop the column ──────────────────────────────────────
-- Any value set by hand (Test Co) goes with it. Re-applying M5 defaults every
-- organisation back to is_test = false, so the deploy note's update has to be
-- re-run too.

alter table organizations drop column if exists is_test;


-- ── 6. Clean-slate verification ─────────────────────────────

do $$
declare
  n int;
begin
  select
      (select count(*) from pg_tables
        where schemaname = 'public'
          and tablename in ('meetings','actions','action_reminders'))
    + (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'organizations'
          and column_name = 'is_test')
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public'
          and p.proname in ('is_staff','_action_label','action_reminders_run',
                            'tuesday_review_open','tuesday_review_pack',
                            'action_upsert','kw_touch_actions'))
    + (select count(*) from pg_policies
        where schemaname = 'public'
          and tablename in ('meetings','actions','action_reminders'))
    into n;

  if n <> 0 then
    raise exception 'M5 rollback incomplete: % object(s) left behind', n;
  end if;

  raise notice 'M5 rollback clean: zero leftover objects.';
end $$;
