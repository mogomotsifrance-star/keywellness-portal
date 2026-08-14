-- ============================================================
-- Key Wellness — France's Advisor option missing from the chooser
--
-- Symptom: on sign-in, france@keywealth.co.bw is offered "My Portal"
-- and "HR Dashboard" but not "Advisor Portal" (and, per CLAUDE.md,
-- "Admin" should be there too).
--
-- The chooser shows Advisor only when advisor_me() returns a row,
-- which requires an `advisors` row that is is_active and matches
-- France's user_id or email. Admin shows only when `admins` has a
-- row whose email EXACTLY equals the login email (case-sensitive
-- match in index.html).
--
-- Run PART 1 first to see which piece is missing, then PART 2 to fix.
-- Safe to re-run. PRODUCTION-LIVE on apply.
-- ROLLBACK: delete/deactivate the advisors row (see foot of file).
-- ============================================================


-- ── PART 1 · DIAGNOSE — run these SELECTs and read the output ──

-- 1a. Do the advisor functions exist? (0 rows = supabase_advisor_portal.sql
--     and supabase_advisor_rpcs.sql were never applied — run those FIRST,
--     in that order, then this file.)
select proname from pg_proc
where proname in ('advisor_me', 'current_advisor_id')
  and pronamespace = 'public'::regnamespace;

-- 1b. Is France in advisors, and active?
--     0 rows = never seeded (PART 2 fixes). is_active=false = deactivated
--     (PART 2 fixes). user_id NULL is fine — email match covers it.
select id, email, full_name, is_active, user_id
from advisors
where lower(email) = 'france@keywealth.co.bw';

-- 1c. Is France in admins, with an exact-case email?
--     index.html matches admins by exact string equality, so
--     'France@keywealth.co.bw' would NOT match. Expect one all-lowercase row.
select email from admins
where lower(email) = 'france@keywealth.co.bw';

-- 1d. France's actual auth account email, for comparison:
select id, email from auth.users
where lower(email) = 'france@keywealth.co.bw';


-- ── PART 2 · FIX — seed / reactivate the advisor row ──────────

do $$
declare
  v_uid uuid;
begin
  -- France's auth account already exists, so the signup-time backfill
  -- trigger will never run for them — link user_id here directly.
  select id into v_uid from auth.users
  where lower(email) = 'france@keywealth.co.bw'
  limit 1;

  if exists (select 1 from advisors where lower(email) = 'france@keywealth.co.bw') then
    update advisors
       set is_active  = true,
           user_id    = coalesce(user_id, v_uid),
           updated_at = now()
     where lower(email) = 'france@keywealth.co.bw';
    raise notice 'advisors row existed — reactivated and user_id ensured';
  else
    insert into advisors (email, full_name, title, user_id)
    values ('france@keywealth.co.bw', 'France Mogomotsi',
            'Financial Wellness Advisor', v_uid);
    raise notice 'advisors row created (user_id %)', v_uid;
  end if;

  -- Normalise the admins email to lowercase so index.html's exact-match
  -- lookup finds it (no-op if already lowercase or absent).
  update admins
     set email = lower(email)
   where lower(email) = 'france@keywealth.co.bw'
     and email <> lower(email);
end $$;


-- ── VERIFY ───────────────────────────────────────────────────
-- Re-run 1b: expect one row, is_active = true, user_id not null.
-- Then France signs out and back in (or hard-refreshes index.html):
-- the chooser should now offer My Portal / Advisor Portal / HR Dashboard
-- (+ Admin if 1c returned a row).
--
-- Browser-console check while logged in as France:
--   await sb.rpc('advisor_me');   // expect the advisor object, not null


-- ── ROLLBACK ─────────────────────────────────────────────────
-- Prefer deactivating (keeps history / FK references intact):
--   update advisors set is_active = false, updated_at = now()
--   where lower(email) = 'france@keywealth.co.bw';
-- Hard delete only if the row was created by mistake and holds no clients:
--   delete from advisors where lower(email) = 'france@keywealth.co.bw';
-- ============================================================
