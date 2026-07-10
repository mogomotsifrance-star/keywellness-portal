-- Diagnose "magic link send error" — run each block in the Supabase SQL Editor,
-- one at a time. Replace 'YOUR_EMAIL' with the address you tested with.
-- Read-only checks; nothing here modifies data.

-- ── 1. Does the account exist, and is its state normal? ──
-- Look for: banned_until set, deleted_at set, email_confirmed_at null
-- (shouldn't block magic link, but rules out an odd account state),
-- or multiple rows for the same email (shouldn't happen — email is unique).
select id, email, created_at, confirmed_at, email_confirmed_at,
       last_sign_in_at, banned_until, deleted_at, is_sso_user, raw_app_meta_data
from auth.users
where email = 'YOUR_EMAIL';

-- ── 2. Recent auth audit events for this user ──
-- Shows what GoTrue actually recorded for recent attempts. Look at the
-- `payload->>'action'` and `payload->>'error'` (if present) for the most
-- recent rows around the time you tried. A failed SEND (SMTP/rate-limit
-- error) often does NOT produce a row here at all, since the audit log
-- mostly records successful actions — if block 2 shows nothing near your
-- attempt time, that itself is informative (points to a send-time failure
-- that never got past the point where GoTrue logs the action).
select id, created_at, payload
from auth.audit_log_entries
where payload->>'actor_username' = 'YOUR_EMAIL'
   or payload->'traits'->>'email' = 'YOUR_EMAIL'
order by created_at desc
limit 20;

-- ── 3. Any recent audit activity at all, across all users ──
-- Useful to confirm the audit table itself is populating normally right now
-- (sanity check that this isn't a wider outage) and to see if OTHER users'
-- sends are succeeding/failing around the same time.
select created_at, payload->>'action' as action, payload->>'actor_username' as who
from auth.audit_log_entries
order by created_at desc
limit 20;

-- ── 4. One-time tokens table — was a magic-link token actually issued? ──
-- If a row exists here for your user with a recent created_at/updated_at,
-- GoTrue DID generate and store the token server-side — meaning the error
-- happened at the EMAIL SEND step (SMTP/provider), not token generation.
-- If no row exists, the failure happened earlier, before token issuance.
select id, user_id, token_type, created_at, updated_at
from auth.one_time_tokens
where user_id = (select id from auth.users where email = 'YOUR_EMAIL')
order by updated_at desc
limit 5;
