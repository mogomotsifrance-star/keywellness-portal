-- ============================================================
-- ROLLBACK — booking_notify_payload()
-- Reverses supabase_booking_notify_payload.sql. Safe to re-run.
--
-- ORDER MATTERS. This function is what the rewritten send-booking-email
-- Edge Function uses to find out who to email. Dropping it while that
-- version is deployed breaks every booking notification: the function
-- will return ok:false and no mail will go out.
--
-- So roll back the Edge Function FIRST (redeploy the previous version),
-- and only then run this. Bookings themselves are never affected either
-- way — they are written before any email is attempted, by every caller.
--
-- Be aware what reverting the Edge Function restores: the version that
-- takes its recipient from the request body and never checks the caller's
-- JWT. Do not leave it deployed longer than the rollback needs.
-- ============================================================

drop function if exists booking_notify_payload(uuid);


-- ── Verify ───────────────────────────────────────────────────
--
--   select count(*) as should_be_zero
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'booking_notify_payload';
-- ============================================================
