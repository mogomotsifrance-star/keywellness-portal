-- Rollback for supabase_delete_account_france_prolearn.sql
--
-- READ THIS FIRST: this rollback is PARTIAL, and deliberately so.
--
-- Deleting a row from auth.users destroys the password hash and the identity
-- record with it. Nothing in SQL brings those back. There is no backup table
-- here on purpose — parking auth rows in a public-schema table is how
-- _m1_session_mode_backup ended up flagged as an RLS hole, and a stored
-- password hash is a worse thing to leave lying around than this rollback is
-- to lose.
--
-- So: if france@prolearn.co.bw must exist again it has to be re-created
-- through Supabase Auth (invite or sign-up), and it comes back with a NEW
-- uuid. What this script does is put the four references back afterwards.
--
-- Run only AFTER the account has been re-created in Auth.

begin;

do $$
declare
  v_new uuid;
  v_kw  uuid;
begin
  select id into v_new from auth.users where lower(email) = 'france@prolearn.co.bw';
  if v_new is null then
    raise exception 're-create france@prolearn.co.bw in Supabase Auth first, then run this';
  end if;

  select id into v_kw from auth.users where lower(email) = 'france@keywealth.co.bw';
  if v_kw is null then
    raise exception 'france@keywealth.co.bw not found — cannot identify the rows to hand back';
  end if;

  -- Restore the admin grant.
  insert into admins (email) values ('france@prolearn.co.bw') on conflict do nothing;

  -- Hand back exactly the four rows the forward script moved, by id, and only
  -- if they are still sitting on the keywealth account. Anything France has
  -- legitimately authored under keywealth since is left alone.
  update org_reports set created_by = v_new
   where id = '5f23c993-fe37-4ff4-a66f-d0ef3dfa2864' and created_by = v_kw;

  update org_reports set published_by = v_new
   where id = '022ad3ed-5c96-4802-b48f-ef759ffde326' and published_by = v_kw;

  update program_activities set created_by = v_new
   where id = '18366c2e-4760-47d0-9750-ebeef159fd72' and created_by = v_kw;

  update bookings set attendance_confirmed_by = v_new
   where id in ('dbc2488c-2d23-451c-b16d-d2e8c555786a',
                '273cd2bf-67f9-4962-b56f-b23dcb39897d')
     and attendance_confirmed_by = v_kw;
end $$;

commit;
