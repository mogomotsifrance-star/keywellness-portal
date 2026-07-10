-- ============================================================
-- Key Wellness — fix: _suppress_count(bigint) does not exist
-- Discovered live in production — see BUILD-NOTES.md ("CRITICAL:
-- org_report_data() has never worked against real data").
--
-- _suppress_count(v int) (from supabase_org_report_data.sql) is called
-- throughout org_report_data()/​_org_report_period_data() with raw
-- count(*)/count(distinct ...) results, which Postgres always returns as
-- bigint. Postgres has no implicit bigint->int cast for direct function
-- argument resolution, so every one of those calls has always raised
-- "function _suppress_count(bigint) does not exist" — meaning
-- org_report_data() (and therefore publish_org_report(), which calls it
-- internally) has never successfully returned real data for any org.
--
-- Fix: add a bigint overload. Postgres resolves to whichever overload
-- matches the argument's actual type, so this requires no changes to any
-- of the ~20 call sites in supabase_org_report_data_v2.sql. The existing
-- _suppress_count(int) overload is untouched.
--
-- Safe to re-run (CREATE OR REPLACE). Rollback:
--   drop function if exists _suppress_count(bigint);
-- ============================================================

create or replace function _suppress_count(v bigint)
returns jsonb
language sql
immutable
as $$
  select case
    when v is null then jsonb_build_object('value', 0, 'suppressed', false)
    when v < 3     then jsonb_build_object('value', null, 'suppressed', true)
    else                jsonb_build_object('value', v, 'suppressed', false)
  end;
$$;


-- ── VERIFICATION QUERIES ─────────────────────────────────────

-- 1. Confirm both overloads now exist:
--    select pg_get_function_identity_arguments(oid) from pg_proc where proname = '_suppress_count';
--    -- expect two rows: "v integer" and "v bigint"

-- 2. Real call against a real org (swap UUID + dates for Test Co / any
--    org with >=5 members):
--    select org_report_data('<org-uuid>', '2026-07-01', '2026-09-30');
--    -- expect a full JSON object, not an error

-- 3. In the admin builder, reopen any existing draft report and confirm
--    the auto-data preview now renders charts/numbers instead of the
--    "fewer than 5 enrolled members" message.

-- 4. Re-test publish_org_report() end-to-end on a real draft — it was
--    equally broken by this bug since it calls org_report_data()
--    internally.
-- ─────────────────────────────────────────────────────────────
