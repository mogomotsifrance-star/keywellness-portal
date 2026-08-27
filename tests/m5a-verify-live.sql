-- ============================================================
-- Key Wellness — M5a live verification (READ-ONLY)
--
-- Run in the Supabase SQL Editor BEFORE applying
-- supabase_m5a_ops_timeline.sql and again AFTER. Every block returns a single
-- text column called `line`.
--
-- READ-ONLY. No insert, update, delete or DDL. V4 and V5 use
-- set_config(..., true) to set a JWT claim for the CURRENT TRANSACTION ONLY —
-- that is how auth.jwt() reads identity on Supabase:
--
--   auth.jwt() = coalesce(nullif(current_setting('request.jwt.claim',  true),''),
--                         nullif(current_setting('request.jwt.claims', true),''))::jsonb
--
-- Without it every call raises 'not authorised', because the SQL editor runs
-- as postgres with no JWT and is_staff() is therefore false. The setting is
-- discarded when the transaction ends and writes nothing.
--
-- Run each block as its own statement; the set_config must be in the same
-- transaction as the call that follows it.
-- ============================================================


-- ── V1 · Is it applied? ─────────────────────────────────────
select 'ops_timeline(date,date) : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='ops_timeline')
            then 'PRESENT' else 'absent' end as line
union all
select '_ops_as_date(text)      : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='_ops_as_date')
            then 'PRESENT' else 'absent' end
union all
select 'is_staff() (from M5)    : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='is_staff')
            then 'PRESENT' else 'absent — apply M5 first' end
union all
select 'organizations.is_test   : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='organizations'
                            and column_name='is_test')
            then 'PRESENT' else 'absent — apply M5 first' end;


-- ── V2 · The grants ─────────────────────────────────────────
-- AFTER: the helper must be revoked, the RPC must be callable.
select '_ops_as_date reachable by authenticated : ' ||
       coalesce(has_function_privilege('authenticated','_ops_as_date(text)','EXECUTE')::text,
                'n/a') || '   (must be false)' as line
union all
select '_ops_as_date reachable by anon          : ' ||
       coalesce(has_function_privilege('anon','_ops_as_date(text)','EXECUTE')::text, 'n/a')
       || '   (must be false)'
union all
select 'ops_timeline reachable by authenticated : ' ||
       coalesce(has_function_privilege('authenticated','ops_timeline(date, date)','EXECUTE')::text,
                'n/a') || '   (must be true)';


-- ── V3 · The text-date column, on real rows ─────────────────
-- This is why _ops_as_date exists. Live holds '2099-12-31'; anything that is
-- not a real date must come back null rather than a plausible invention.
select coalesce(b.requested_date, '(null)')
       || '  ->  ' || coalesce(_ops_as_date(b.requested_date)::text, 'null (falls back to created_at)')
       || '   x' || count(*)::text as line
  from bookings b
 group by b.requested_date
 order by 1;


-- ── V4 · What the review would show, as an admin ────────────
-- The week behind. Run the set_config and the call together.
select set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);

select o ->> 'name' || '  |  ' || (i ->> 'on_date')
       || '  |  ' || (i ->> 'kind')
       || '  |  ' || (i ->> 'service_line')
       || '  |  ' || (i ->> 'title')
       || coalesce('  |  ' || nullif(i ->> 'practitioner',''), '')
       || '  |  ' || (i ->> 'state') as line
  from jsonb_array_elements(
         (select ops_timeline(current_date - 7, current_date + 14) -> 'organisations')) o,
       jsonb_array_elements(o -> 'items') i
 order by (i ->> 'on_date'), (o ->> 'name');


-- ── V5 · The exclusions actually hold ───────────────────────
select set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);

select 'organisations returned : ' ||
       coalesce((select string_agg(o ->> 'name', ', ' order by o ->> 'name')
                   from jsonb_array_elements(
                          (select ops_timeline(current_date - 30, current_date + 30)
                                    -> 'organisations')) o), '(none)') as line
union all
select 'Test Co present?       : ' ||
       case when exists (
              select 1 from jsonb_array_elements(
                     (select ops_timeline(current_date - 30, current_date + 30)
                               -> 'organisations')) o
               where o ->> 'name' = 'Test Co')
            then 'YES — FAIL, is_test is not set. Run the M5 deploy note update.'
            else 'no (correct)' end
union all
select 'unassigned items       : ' ||
       jsonb_array_length((select ops_timeline(current_date - 30, current_date + 30)
                                    -> 'unassigned'))::text;


-- ── V6 · The M3 obligation, stated where it will be read ────
-- ops_timeline is SECURITY DEFINER and therefore bypasses the bookings
-- policies. Today every row is financial, so this returns nothing sensitive.
-- The moment M3 lands, France must not see psychosocial rows THROUGH THIS
-- FUNCTION, and the policy split alone will not achieve that.
select set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);

select 'psychosocial rows visible through ops_timeline : ' || count(*)::text
    || case when count(*) = 0
            then '  (none yet — M3 must gate this before the first one exists)'
            else '  <-- M3 MUST gate these inside the function' end as line
  from jsonb_array_elements(
         (select ops_timeline(current_date - 365, current_date + 365)
                   -> 'organisations')) o,
       jsonb_array_elements(o -> 'items') i
 where i ->> 'service_line' = 'psychosocial';
