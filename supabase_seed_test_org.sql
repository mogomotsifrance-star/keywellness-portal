-- ============================================================
-- Key Wellness — Seed test company org + assign unassigned accounts
-- Run in Supabase SQL Editor. Safe to re-run (idempotent org insert).
--
-- WARNING: step 3 assigns EVERY profile with org_id IS NULL to the
-- test org — that includes any real member who hasn't been assigned
-- an org yet, not just your test accounts. Run the PREVIEW (step 2)
-- first and eyeball the list before running the UPDATE (step 3).
-- ============================================================

-- ── 1. Confirm the existing test org ──────────────────────────
-- "Test Co" already exists with invite_code TEST-1234 — just look it up.
select id, name, invite_code, is_active
from organizations
where invite_code = 'TEST-1234';
-- If this returns no rows, stop — the invite_code below won't match anything.

-- ── 2. PREVIEW — check who this will affect before updating ──
select id, first_name, last_name, org_id
from profiles
where org_id is null;

-- ── 3. Assign every unassigned profile to the test org ────────
-- Only run this after reviewing step 2's output.
update profiles
set org_id = (select id from organizations where invite_code = 'TEST-1234')
where org_id is null;

-- ── 4. Verify ───────────────────────────────────────────────
select o.name, count(p.id) as member_count
from organizations o
left join profiles p on p.org_id = o.id
where o.invite_code = 'TEST-1234'
group by o.name;

-- ── 5. LOOKUP — identify the profile(s) just assigned to Test Co ──
-- Confirms whether this was actually a test account or a real member
-- who simply hadn't been assigned an org yet.
select p.id, p.first_name, p.last_name, u.email, u.created_at as account_created
from profiles p
join auth.users u on u.id = p.id
where p.org_id = (select id from organizations where invite_code = 'TEST-1234');

-- ── 6. UNDO — only run this if step 5 shows a real member, not a test account ──
-- Reverts that specific profile back to unassigned. Replace the uuid with
-- the id from step 5's output — do NOT run this blind against the whole org.
-- update profiles set org_id = null where id = '<paste-profile-id-here>';

-- ── 7. Reaching 5 members for org_overview() to un-suppress ──────
-- org_overview() hides all data until an org has ≥5 enrolled profiles.
-- Recommended: sign up 4+ fresh test accounts through the normal portal
-- signup flow, entering invite code TEST-1234 in the "Company code" field.
-- handle_new_user() auto-assigns org_id at signup — no manual SQL needed,
-- and it doesn't touch any existing real member data.
--
-- (Fabricating profiles directly via SQL isn't practical here: profiles.id
-- is a foreign key to auth.users(id), so a profile can't exist without a
-- real Supabase Auth user behind it — there's no clean way to insert that
-- via SQL without bypassing Supabase Auth entirely.)

-- ============================================================
-- Bulk assign — every account in the DB is confirmed test data
-- Run this instead of steps 2/3 if you want ALL member accounts
-- (not just unassigned ones) moved to Test Co in one go.
--
-- Excludes admins and employers on purpose: an HR manager's own
-- profile must stay org_id NULL so they aren't counted as a member
-- of the org they manage (see supabase_multitenancy.sql step 10
-- comments) — assigning them here would double them up as both
-- manager and "employee" of Test Co.
-- ============================================================

-- NOTE: uses NOT EXISTS rather than NOT IN. If admins/employers ever has a
-- row with a NULL email, `NOT IN (select ... including a NULL)` silently
-- evaluates to NULL for every row and the WHERE clause matches nothing —
-- NOT EXISTS with a correlated subquery doesn't have that failure mode.

-- ── 8. PREVIEW — every profile that will be touched, and current org ──
select p.id, p.first_name, p.last_name, u.email, p.org_id as current_org_id
from profiles p
join auth.users u on u.id = p.id
where not exists (select 1 from employers e where e.user_id = p.id)
  and not exists (select 1 from employers e where lower(e.email) = lower(u.email))
  and not exists (select 1 from admins a where lower(a.email) = lower(u.email));

-- ── 9. Assign all non-admin, non-employer profiles to Test Co ──
update profiles p
set org_id = (select id from organizations where invite_code = 'TEST-1234')
from auth.users u
where u.id = p.id
  and not exists (select 1 from employers e where e.user_id = p.id)
  and not exists (select 1 from employers e where lower(e.email) = lower(u.email))
  and not exists (select 1 from admins a where lower(a.email) = lower(u.email));

-- ── 10. Verify ──────────────────────────────────────────────
select o.name, count(p.id) as member_count
from organizations o
left join profiles p on p.org_id = o.id
where o.invite_code = 'TEST-1234'
group by o.name;

-- ============================================================
-- If step 10 still shows a low count — diagnose auth.users vs profiles
-- A profiles row is only created once someone logs into the portal and
-- the app runs its signup trigger / saveUser() upsert. An account that
-- exists in auth.users but never fully logged in has NO profiles row,
-- so there's nothing for the UPDATE above to attach an org_id to.
-- ============================================================

-- ── 11. Compare counts ────────────────────────────────────────
select
  (select count(*) from auth.users)  as auth_users_count,
  (select count(*) from profiles)    as profiles_count;

-- ── 12. List auth.users accounts with NO matching profiles row ──
-- These are the accounts the bulk update above could not touch.
select u.id, u.email, u.created_at
from auth.users u
left join profiles p on p.id = u.id
where p.id is null
order by u.created_at desc;

-- ── 13. Fix — log into the portal once per missing account ────
-- There's no safe SQL shortcut for this: profiles are only created
-- through the app's own signup/login flow (handle_new_user() trigger
-- + saveUser()), which also seeds first_name/consent/etc. correctly.
-- For each email listed in step 12: sign in to the portal as that
-- user once (entering invite code TEST-1234 at signup if the account
-- doesn't exist yet) — the profile row will be created automatically,
-- and re-running steps 8-10 will then pick it up.

-- ============================================================
-- If the count is STILL stuck at the same number after re-running
-- step 9 (no error, but org_id doesn't change) — the real blocker
-- is very likely trg_lock_org_id, a BEFORE UPDATE trigger from
-- supabase_multitenancy.sql that reverts org_id to its old value
-- unless is_admin() is true. is_admin() reads auth.jwt() ->> 'email',
-- but the SQL Editor runs as the raw `postgres` role with no JWT/
-- session context at all — so is_admin() is false for every query
-- run here, and the trigger silently no-ops every org_id change.
-- ============================================================

-- ── 14. Confirm the trigger is the blocker ─────────────────────
select is_admin() as is_admin_in_sql_editor;
-- Expect: false (or an error if is_admin() itself fails without a JWT).
-- Either result confirms the trigger will block org_id updates here.

select tgname, tgenabled
from pg_trigger
where tgrelid = 'public.profiles'::regclass and not tgisinternal;
-- Look for trg_lock_org_id — 'O' in tgenabled means it's active and firing.

-- ── 15. Fix — disable the trigger for this one statement only ──
-- Safe because you're connected as `postgres` (table owner), and the
-- trigger is re-enabled immediately after. Nothing else runs in between.
alter table profiles disable trigger trg_lock_org_id;

update profiles p
set org_id = (select id from organizations where invite_code = 'TEST-1234')
from auth.users u
where u.id = p.id
  and not exists (select 1 from employers e where e.user_id = p.id)
  and not exists (select 1 from employers e where lower(e.email) = lower(u.email))
  and not exists (select 1 from admins a where lower(a.email) = lower(u.email));

alter table profiles enable trigger trg_lock_org_id;

-- ── 16. Verify ──────────────────────────────────────────────
select o.name, count(p.id) as member_count
from organizations o
left join profiles p on p.org_id = o.id
where o.invite_code = 'TEST-1234'
group by o.name;
