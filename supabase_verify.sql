-- ============================================================
-- Key Wellness — Multi-Tenancy Migration Verification
-- Paste into Supabase SQL Editor and run. One row per check.
-- NOTE: SQL Editor runs as table owner and BYPASSES RLS, so this
-- verifies structure + the signup-breaking risk. True cross-user
-- RLS isolation must be tested from the browser with the anon key.
-- ============================================================

with checks as (

  -- ── 1. Tables exist ──────────────────────────────────────
  select 1 as ord, 'organizations table exists' as check_name,
    case when to_regclass('public.organizations') is not null then '✅ PASS' else '❌ FAIL' end as status,
    coalesce(to_regclass('public.organizations')::text, 'missing') as detail

  union all
  select 2, 'employers table exists',
    case when to_regclass('public.employers') is not null then '✅ PASS' else '❌ FAIL' end,
    coalesce(to_regclass('public.employers')::text, 'missing')

  union all
  select 3, 'profiles.org_id column exists',
    case when exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='profiles' and column_name='org_id')
      then '✅ PASS' else '❌ FAIL' end,
    coalesce((select data_type from information_schema.columns
      where table_schema='public' and table_name='profiles' and column_name='org_id'), 'missing')

  -- ── 2. Functions exist ───────────────────────────────────
  union all
  select 4, 'function is_admin() exists',
    case when exists (select 1 from pg_proc where proname='is_admin') then '✅ PASS' else '❌ FAIL' end,
    coalesce((select pg_get_function_result(oid) from pg_proc where proname='is_admin' limit 1), 'missing')

  union all
  select 5, 'function employer_org() exists',
    case when exists (select 1 from pg_proc where proname='employer_org') then '✅ PASS' else '❌ FAIL' end,
    coalesce((select pg_get_function_result(oid) from pg_proc where proname='employer_org' limit 1), 'missing')

  union all
  select 6, 'function org_overview() exists',
    case when exists (select 1 from pg_proc where proname='org_overview') then '✅ PASS' else '❌ FAIL' end,
    coalesce((select pg_get_function_arguments(oid) from pg_proc where proname='org_overview' limit 1), 'missing')

  union all
  select 7, 'function handle_new_user() exists',
    case when exists (select 1 from pg_proc where proname='handle_new_user') then '✅ PASS' else '❌ FAIL' end,
    'used by signup trigger'

  union all
  select 8, 'function lock_org_id() exists',
    case when exists (select 1 from pg_proc where proname='lock_org_id') then '✅ PASS' else '❌ FAIL' end,
    'used by org_id lock trigger'

  -- ── 3. SECURITY DEFINER on helpers (required to bypass RLS) ──
  union all
  select 9, 'is_admin / employer_org are SECURITY DEFINER',
    case when (select bool_and(prosecdef) from pg_proc where proname in ('is_admin','employer_org'))
      then '✅ PASS' else '❌ FAIL' end,
    'both must be security definer to avoid RLS recursion'

  -- ── 4. Triggers exist ────────────────────────────────────
  union all
  select 10, 'trigger trg_lock_org_id on profiles',
    case when exists (select 1 from pg_trigger where tgname='trg_lock_org_id' and not tgisinternal)
      then '✅ PASS' else '❌ FAIL' end,
    'locks org_id against client writes'

  union all
  select 11, 'trigger on_auth_user_created on auth.users',
    case when exists (select 1 from pg_trigger where tgname='on_auth_user_created' and not tgisinternal)
      then '✅ PASS' else '❌ FAIL' end,
    'resolves invite_code → org_id at signup'

  -- ── 5. RLS enabled on every protected table ──────────────
  union all
  select 12, 'RLS enabled on all protected tables',
    case when (select bool_and(c.relrowsecurity)
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public'
        and c.relname in ('profiles','assessments','checkins','badges','emergency_fund','organizations','employers'))
      then '✅ PASS' else '❌ FAIL' end,
    coalesce((select string_agg(c.relname, ', ')
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public'
        and c.relname in ('profiles','assessments','checkins','badges','emergency_fund','organizations','employers')
        and c.relrowsecurity = false), 'all enabled')

  -- ── 6. Expected policies exist ───────────────────────────
  union all
  select 13, 'member-table own + admin_read policies present',
    case when (
      select count(*) from pg_policies
      where schemaname='public' and policyname in (
        'profiles_own','profiles_admin_read',
        'assessments_own','assessments_admin_read',
        'checkins_own','checkins_admin_read',
        'badges_own','badges_admin_read',
        'ef_own','ef_admin_read')
    ) = 10 then '✅ PASS' else '❌ FAIL' end,
    (select count(*)::text || ' of 10 found' from pg_policies
      where schemaname='public' and policyname in (
        'profiles_own','profiles_admin_read','assessments_own','assessments_admin_read',
        'checkins_own','checkins_admin_read','badges_own','badges_admin_read','ef_own','ef_admin_read'))

  union all
  select 14, 'org + employer policies present',
    case when (
      select count(*) from pg_policies
      where schemaname='public' and policyname in (
        'orgs_admin_all','orgs_own','employers_admin_all','employers_self_read')
    ) = 4 then '✅ PASS' else '❌ FAIL' end,
    (select count(*)::text || ' of 4 found' from pg_policies
      where schemaname='public' and policyname in (
        'orgs_admin_all','orgs_own','employers_admin_all','employers_self_read'))

  -- ── 7. CRITICAL: no member/employer policy leaks rows to HR ──
  -- HR must have NO policy on member tables. Only *_own and *_admin_read allowed.
  union all
  select 15, 'no extra policies leaking member tables to HR',
    case when not exists (
      select 1 from pg_policies
      where schemaname='public'
        and tablename in ('assessments','checkins','badges','emergency_fund')
        and policyname not like '%\_own' escape '\'
        and policyname not like '%\_admin\_read' escape '\'
    ) then '✅ PASS' else '❌ FAIL' end,
    coalesce((select string_agg(tablename||'.'||policyname, ', ') from pg_policies
      where schemaname='public'
        and tablename in ('assessments','checkins','badges','emergency_fund')
        and policyname not like '%\_own' escape '\'
        and policyname not like '%\_admin\_read' escape '\'), 'none — clean')

  -- ── 8. CRITICAL: signup trigger won't break on NOT NULL cols ──
  -- The trigger inserts only (id, org_id). Any other NOT NULL column
  -- without a default will make EVERY signup fail.
  union all
  select 16, 'profiles has no NOT NULL cols that break the signup trigger',
    case when not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='profiles'
        and is_nullable='NO' and column_default is null
        and column_name not in ('id','org_id')
    ) then '✅ PASS' else '❌ FAIL' end,
    coalesce((select string_agg(column_name, ', ') from information_schema.columns
      where table_schema='public' and table_name='profiles'
        and is_nullable='NO' and column_default is null
        and column_name not in ('id','org_id')),
      'none — trigger is safe')

  -- ── 9. org_id FK integrity ───────────────────────────────
  union all
  select 17, 'profiles.org_id is a FK to organizations',
    case when exists (
      select 1 from information_schema.table_constraints tc
      join information_schema.key_column_usage kcu on tc.constraint_name=kcu.constraint_name
      where tc.constraint_type='FOREIGN KEY' and tc.table_name='profiles' and kcu.column_name='org_id'
    ) then '✅ PASS' else '⚠️ WARN' end,
    'org_id should reference organizations(id)'

)
select check_name, status, detail from checks order by ord;
