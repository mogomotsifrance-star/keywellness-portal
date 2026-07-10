-- ============================================================
-- Fix: "Your booking could not be saved" on the Book a Session page
--
-- Actual root cause (confirmed via the browser network error):
--   PGRST204 "Could not find the 'requested_time' column of
--   'bookings' in the schema cache"
--
-- `requested_time` was added to the insert in index.html's
-- submitBooking() by commit 25fd0aa ("booking reminders (1h
-- before/after)") but the column was never added to the live
-- `bookings` table — no SQL migration for it exists anywhere in
-- this repo. Same story for `client_seen_confirmation` (added by
-- the same commit, read/written by dismissBookingBanner() and the
-- dashboard confirmation banner) and `updated_at` (written by
-- admin.html's updateBookingStatus() when HR confirms/declines a
-- booking — that update's error is currently swallowed, so it may
-- have been silently failing too).
--
-- This was never an RLS problem — bookings already had working
-- insert/select policies. (An earlier version of this file wrongly
-- assumed a missing-policy cause before the real Postgres error was
-- available; this version replaces that with the actual fix.)
-- ============================================================

alter table bookings add column if not exists requested_time text;
alter table bookings add column if not exists client_seen_confirmation boolean not null default false;
alter table bookings add column if not exists updated_at timestamptz;

-- ── Verify ────────────────────────────────────────────────────
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'bookings'
order by ordinal_position;
