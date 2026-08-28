-- ============================================================================
-- Disable the email-confirmation requirement — database half
-- ============================================================================
-- The requirement itself is a GoTrue setting, NOT a database row:
--   Dashboard → Authentication → Sign In / Providers → Email → "Confirm email" → OFF
-- Turning it off stops NEW signups from needing a confirmation link. It does
-- NOT retroactively let already-created, never-confirmed users sign in — GoTrue
-- still rejects them with `email_not_confirmed`. This migration clears that
-- backlog so "no user needs to confirm" is true for existing accounts too.
--
-- As of 2026-08-28 the backlog is exactly ONE account:
--   88e7ecb1-79ca-4aed-b97b-769f5fc94af0  morris@prolearn.co.bw
--   signed up 2026-07-09, confirmation mailed, never confirmed, never signed in
--
-- Phone accounts are unaffected — `phone-signup` already creates them with
-- email_confirm:true (see supabase/functions/phone-signup/index.ts).
--
-- Apply in the Supabase SQL Editor (runs as `postgres`).
-- Rollback: migrations/rollback-confirm-existing-users.sql
-- ============================================================================

begin;

-- Show what is about to change, so the applier sees it before it happens.
select id, email, created_at
  from auth.users
 where email_confirmed_at is null
 order by created_at;

-- Backdate the confirmation to when the link was mailed (or to signup), rather
-- than now() — the account has been usable-in-principle since then, and a
-- deterministic value keeps the rollback exact.
update auth.users
   set email_confirmed_at = coalesce(confirmation_sent_at, created_at),
       updated_at         = now()
 where email_confirmed_at is null;
-- NOTE: auth.users.confirmed_at is a GENERATED column
-- (least(email_confirmed_at, phone_confirmed_at)) — it follows automatically
-- and must not be written directly.

-- Must return 0.
select count(*) as still_unconfirmed
  from auth.users
 where email_confirmed_at is null;

commit;
