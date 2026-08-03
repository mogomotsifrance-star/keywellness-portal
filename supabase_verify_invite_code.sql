-- ============================================================
-- Key Wellness — verify_invite_code() (Sedimosa Phase 2, Batch 2 support)
-- Run in the Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- PRODUCTION-LIVE on apply; additive; nothing depends on it until the Batch 2
-- frontend ships (and the frontend fails GRACEFULLY if this isn't applied yet —
-- it falls back to the signup trigger's own code resolution).
--
-- Purpose: let the (pre-auth, anon) signup form check that a typed company code
-- resolves to an ACTIVE organisation BEFORE creating the account, so a typo
-- can't silently create an orphaned public member. Compulsory company codes are
-- a locked decision for this phase.
--
-- Disclosure surface: returns a single boolean (code valid / not). Invite codes
-- are already shared with employees, so a boolean oracle is low-risk. No org
-- names, ids, or any other row data are exposed.
--
-- ROLLBACK: migrations/rollback-verify-invite-code.sql
-- ============================================================

create or replace function verify_invite_code(p_code text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from organizations
    where upper(invite_code) = upper(trim(p_code))
      and is_active = true
  );
$$;

-- Anon must call this during signup (before authentication); authenticated too.
grant execute on function verify_invite_code(text) to anon, authenticated;

-- Verify:
-- select verify_invite_code('TEST-1234');           -- expect true (active Test Co)
-- select verify_invite_code('definitely-not-real'); -- expect false
-- ============================================================
