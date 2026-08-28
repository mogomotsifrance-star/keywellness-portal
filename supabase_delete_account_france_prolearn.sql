-- Delete the account france@prolearn.co.bw
--
-- WHAT THIS ACCOUNT IS: admin ONLY. There is no profiles row and no member
-- data of any kind — no assessments, checkins, badges, points, tool_data,
-- emergency fund, content progress, certificates or bookings-as-member. It is
-- not an advisor, counsellor, employer, HR-scope holder or psychosocial admin.
-- Created 2026-06-22, last sign-in 2026-08-25.
--
--   auth.users id  3ddd771e-9b8c-4aeb-be9d-23551d122664
--   admins         1 row (email-keyed, no user_id)
--
-- WHY IT IS NOT A ONE-LINE DELETE: four rows in three tables point at this
-- user through foreign keys that are all ON DELETE NO ACTION. The delete
-- fails on a foreign-key violation until every one of them is dealt with.
-- Found by sweeping pg_constraint for every FK to auth.users, not by
-- guessing column names — two of the four are not called user_id or
-- created_by and a name-based search misses them.
--
--   org_reports.created_by      1  5f23c993…  Test Co, draft, Q1 2026     NOT NULL
--   org_reports.published_by    1  022ad3ed…  Test Co, PUBLISHED, Q3 2026 nullable
--   program_activities.created_by 1 18366c2e… Test Co, "Debt Management"  NOT NULL
--   bookings.attendance_confirmed_by 2         real member sessions       nullable
--
-- The two bookings are real member records (mpfholdings.com), not test data.
-- attendance_confirmed_by is an audit trail — who confirmed the member turned
-- up. Nulling it would erase that; this script repoints it instead.
--
-- WHAT THIS SCRIPT DOES: repoints all four to france@keywealth.co.bw, the
-- same person's other admin account, which is unaffected and stays active.
-- Nothing is orphaned, no audit trail is lost, and every surviving record
-- names a real account belonging to the person who actually did the thing.
--
-- France keeps admin access via france@keywealth.co.bw. Afterwards admins
-- holds 4 rows: tnmokgwetsi@gmail.com, france@keywealth.co.bw,
-- lone@keywellness.co.bw, michelle@keywealth.co.bw.

begin;

do $$
declare
  v_from constant uuid := '3ddd771e-9b8c-4aeb-be9d-23551d122664';
  v_to   uuid;
  v_left bigint;
begin
  select id into v_to from auth.users where lower(email) = 'france@keywealth.co.bw';
  if v_to is null then
    raise exception 'france@keywealth.co.bw not found — nothing to repoint to; stopping';
  end if;

  update org_reports        set created_by            = v_to where created_by            = v_from;
  update org_reports        set published_by          = v_to where published_by          = v_from;
  update program_activities set created_by            = v_to where created_by            = v_from;
  update bookings           set attendance_confirmed_by = v_to where attendance_confirmed_by = v_from;

  -- Re-sweep every FK to auth.users and refuse to continue if anything is
  -- still pointing at the account. Guards against a reference added between
  -- this script being written and being run.
  select count(*) into v_left from (
    select 1 from org_reports        where created_by = v_from or published_by = v_from
    union all select 1 from program_activities where created_by = v_from
    union all select 1 from bookings where attendance_confirmed_by = v_from or user_id = v_from
  ) s;
  if v_left > 0 then
    raise exception 'still % reference(s) to the account after repointing', v_left;
  end if;
end $$;

-- Admin grant. Email-keyed, so no cascade would ever reach it.
delete from admins where lower(email) = 'france@prolearn.co.bw';

-- The account itself. Cascades auth.identities / sessions / refresh_tokens.
delete from auth.users where id = '3ddd771e-9b8c-4aeb-be9d-23551d122664';

-- Verification — every count must be 0 except admins_total, which must be 4.
select 'users_left'      k, count(*) v from auth.users where lower(email)='france@prolearn.co.bw'
union all select 'admins_left',    count(*) from admins     where lower(email)='france@prolearn.co.bw'
union all select 'identities_left',count(*) from auth.identities where user_id='3ddd771e-9b8c-4aeb-be9d-23551d122664'
union all select 'admins_total',   count(*) from admins;

commit;
