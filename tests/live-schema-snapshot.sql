-- ============================================================
-- Key Wellness — LIVE SCHEMA SNAPSHOT (Prompt 0b, Task A)
--
-- READ-ONLY. Nine SELECTs. Nothing here creates, alters, drops,
-- grants or revokes anything. Safe to run against the live
-- project at any time.
--
-- Why: the repo has no migration ledger. 79 root SQL files are
-- applied by hand in the SQL editor and nothing records which
-- ran. docs/build/00-codebase-map.md §4 therefore had to grade
-- "applied?" as inference. This replaces the inference with fact,
-- and unblocks:
--
--   M1  (Prompt 1) — build the bookings fixture from the real
--                    table, not tests/phase0-fixture.sql
--   M3  (Prompt 7) — read the four legacy bookings policies'
--                    live predicates (Q5); they exist in the repo
--                    only as prose in supabase_org_account_phase0.sql
--   M2  (Prompt 8) — target the live org_report_data() signatures;
--                    the repo holds five versions (Q4)
--   M5  (Prompt 2) — decide pg_cron vs Edge Function (Q7)
--
-- HOW TO RUN
--   Supabase dashboard → SQL Editor → new query. Run each block
--   ONE AT A TIME (the editor shows only the last result set).
--   Every block returns a single text column called `line`, so
--   you can select the column and copy it straight out.
--   Paste each result back and it will be formatted into
--   docs/build/00-live-schema-snapshot.md.
--
-- Q1 and Q2 are the long ones (~37 and ~400 rows). The rest are
-- short. If any block errors, send the error rather than skipping
-- it — a missing catalogue permission is itself a finding.
-- ============================================================


-- ── Q1 · Tables: RLS state and exact row counts ─────────────
-- query_to_xml gives an exact count per table without a hand-
-- written UNION. Expect ~37 rows. Confirms organizations = 3
-- (BOPEU, Sedimosa, Test Co), bookings = 22, org_reports = 4,
-- program_activities = 1, unit_departments = 161.
select c.relname
       || '  |  rls=' || case when c.relrowsecurity then 'on' else 'OFF' end
       || case when c.relforcerowsecurity then ' (forced)' else '' end
       || '  |  rows=' || (xpath('/row/c/text()',
            query_to_xml(format('select count(*) as c from public.%I', c.relname),
                         false, true, '')))[1]::text
       as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind = 'r'
 order by c.relname;


-- ── Q2 · Columns: type, nullability, default ────────────────
-- The one M1 depends on. Pay attention to `bookings` — the local
-- fixture in tests/phase0-fixture.sql was hand-written and has
-- never been checked against this.
select c.relname || ' | ' || a.attname
       || ' | ' || format_type(a.atttypid, a.atttypmod)
       || ' | ' || case when a.attnotnull then 'NOT NULL' else 'null' end
       || ' | default ' || coalesce(pg_get_expr(d.adbin, d.adrelid), '-')
       as line
  from pg_attribute a
  join pg_class     c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
 where n.nspname = 'public'
   and c.relkind = 'r'
   and a.attnum > 0
   and not a.attisdropped
 order by c.relname, a.attnum;


-- ── Q3 · Constraints: pk, fk, unique, check ─────────────────
-- M1 adds two CHECK constraints; this shows the naming convention
-- already in use and any existing check on bookings.session_type.
select c.relname || ' | ' || con.conname || ' | ' || pg_get_constraintdef(con.oid) as line
  from pg_constraint con
  join pg_class     c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
 order by c.relname, con.conname;


-- ── Q4 · Functions: full signature, SECURITY DEFINER, grants ─
-- acl=NULL means no explicit grant was ever written, which in
-- Postgres means EXECUTE is held by PUBLIC — the footgun CLAUDE.md
-- documents. A gated top-level RPC showing `authenticated=X` is
-- correct; a `_`-prefixed helper showing anything beyond
-- postgres/service_role is not.
--
-- This is also the authoritative list of org_report_data()
-- overloads that M2 must extend.
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
       || '  ->  ' || pg_get_function_result(p.oid)
       || '  |  ' || case when p.prosecdef then 'SECURITY DEFINER' else 'invoker' end
       || '  |  acl=' || coalesce(p.proacl::text, 'NULL  (default: EXECUTE to PUBLIC)')
       as line
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
 order by p.proname, pg_get_function_identity_arguments(p.oid);


-- ── Q5 · RLS policies with their predicates ─────────────────
-- The one M3 depends on. Specifically wanted: the four legacy
-- bookings policies (bookings_admin, bookings_admin_all,
-- bookings_own, bookings_self) whose predicates the repo records
-- only in a comment, and confirmation of which
-- bookings_advisor_select is actually live — the advisor-portal
-- version or the team-lead rewrite.
--
-- It also settles whether supabase_cleanup_policies.sql was ever
-- applied: if the duplicates are absent, it ran.
select tablename || ' | ' || policyname
       || ' | ' || cmd
       || ' | ' || permissive
       || ' | roles=' || array_to_string(roles, ',')
       || ' | USING ' || coalesce(qual, '-')
       || ' | CHECK ' || coalesce(with_check, '-')
       as line
  from pg_policies
 where schemaname = 'public'
 order by tablename, policyname;


-- ── Q6 · Triggers ───────────────────────────────────────────
-- Includes trg_lock_org_id and the advisor-client org attribution
-- triggers. M4 reuses the same trigger pattern for counsellors.
select c.relname || ' | ' || t.tgname || ' | ' || pg_get_triggerdef(t.oid) as line
  from pg_trigger   t
  join pg_class     c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and not t.tgisinternal
 order by c.relname, t.tgname;


-- ── Q7 · Installed extensions ───────────────────────────────
-- Answers the open question in docs/data-model-and-impact.md §5.3:
-- is pg_cron available for the 1st-of-month invoice function and
-- the action reminders, or does that work need an Edge Function
-- plus an external scheduler?
select extname || '  ' || extversion as line
  from pg_extension
 order by extname;


-- ── Q8 · threshold_config, in full ──────────────────────────
-- Small and load-bearing: indicator.low_base is the base-5 floor
-- M2 reuses for psychosocial aggregates, and M7 adds
-- capacity.<practitioner_id> keys here rather than in a new table.
select key || '  =  ' || value::text as line
  from threshold_config
 order by key;


-- ── Q9 · The ungated SECURITY DEFINER sweep ─────────────────
-- Verbatim from CLAUDE.md → Roles & Interfaces. The rule is to
-- re-run it after adding any phase. Running it now establishes
-- the clean baseline M1 will be measured against.
--
-- EXPECTED RESULT: zero rows. Anything returned is a SECURITY
-- DEFINER function reachable by anon or authenticated with no
-- internal gate — i.e. a public read of whatever it touches.
select p.proname, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
   and pg_get_function_result(p.oid) <> 'trigger'
   and (has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
   and not (p.prosrc ~* '\mis_admin\M|\mis_team_lead\M|\memployer_org\M|\mis_advisor\M|\mcurrent_advisor_id\M|\mhr_unit_in_scope\M|\mcan_manage_advisor\M'
         or p.prosrc ~* 'auth\.uid\(\)|auth\.jwt\(\)')
 order by p.proname;
