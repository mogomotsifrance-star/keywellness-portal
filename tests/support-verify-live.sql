-- ============================================================
-- Key Wellness — member support: live verification (READ-ONLY)
--
-- Run in the Supabase SQL Editor BEFORE applying supabase_support_audit.sql
-- and again AFTER. Every block returns a single text column called `line`.
--
-- READ-ONLY. No insert, update, delete or DDL. V4 uses
-- set_config(..., true) to set a JWT claim for the CURRENT TRANSACTION only,
-- which is how auth.jwt() reads identity on Supabase; it is discarded at
-- commit and writes nothing.
-- ============================================================


-- ── V1 · Is it applied? ─────────────────────────────────────
select 'support_actions      : ' ||
       case when to_regclass('public.support_actions') is not null
            then 'PRESENT' else 'absent' end as line
union all
select 'is_ops_admin()       : ' ||
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='is_ops_admin')
            then 'PRESENT' else 'absent' end
union all
select 'support RPCs         : ' ||
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public'
           and p.proname in ('support_lookup','support_can','support_log','support_recent'))
       || ' of 4';


-- ── V2 · The policy surface ─────────────────────────────────
-- AFTER: exactly ONE policy, SELECT, and nothing else. No insert, update or
-- delete policy exists by design — rows are written by support_log() only,
-- and nobody can amend or remove one.
select tablename || ' | ' || policyname || ' | ' || cmd
       || ' | USING ' || coalesce(qual,'-') as line
  from pg_policies
 where schemaname='public' and tablename='support_actions'
union all
select 'RLS enabled : ' || (select relrowsecurity::text from pg_class c
                              join pg_namespace n on n.oid=c.relnamespace
                             where n.nspname='public' and c.relname='support_actions')
 where to_regclass('public.support_actions') is not null;


-- ── V3 · Grants ─────────────────────────────────────────────
-- The RPCs are callable by authenticated and gated inside. The TABLE must not
-- be writable by anyone through a grant.
select 'support_lookup callable by authenticated : ' ||
       coalesce(has_function_privilege('authenticated','support_lookup(text)','EXECUTE')::text,'n/a')
       || '   (must be true)' as line
union all
select 'support_actions INSERT by authenticated  : ' ||
       coalesce(has_table_privilege('authenticated','support_actions','INSERT')::text,'n/a')
       || '   (must be false)'
union all
select 'support_actions DELETE by authenticated  : ' ||
       coalesce(has_table_privilege('authenticated','support_actions','DELETE')::text,'n/a')
       || '   (must be false)';


-- ── V4 · The gate answers, as an admin ──────────────────────
select set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);

select 'is_ops_admin() for an admin : ' || is_ops_admin()::text
       || '   (must be true, and equals is_admin() until M3)' as line
union all
select 'support_can(lookup)         : ' || support_can('lookup')::text;


-- ── V5 · The trail so far ───────────────────────────────────
select set_config('request.jwt.claims', '{"email":"lone@keywellness.co.bw"}', true);

select coalesce((
  select string_agg(
    (r ->> 'at') || ' | ' || (r ->> 'actor') || ' | ' || (r ->> 'action')
    || ' | ' || coalesce(r ->> 'target','-') || ' | ' || (r ->> 'outcome'),
    chr(10) order by r ->> 'at' desc)
    from jsonb_array_elements(support_recent(20)) r
), 'no support actions recorded yet') as line;


-- ── V6 · The ungated sweep, for the new functions ───────────
-- Expect ZERO rows. is_ops_admin is now a gate name and CLAUDE.md's regex
-- knows it; if this returns anything, a support function is reachable without
-- a gate.
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as line
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
   and pg_get_function_result(p.oid) <> 'trigger'
   and (has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
   and p.proname in ('is_ops_admin','support_lookup','support_can',
                     'support_log','support_recent')
   and not (p.prosrc ~* '\mis_admin\M|\mis_ops_admin\M'
         or p.prosrc ~* 'auth\.uid\(\)|auth\.jwt\(\)');
