-- Rollback for supabase_confirm_existing_users.sql
--
-- Reverts the single account that migration confirmed. If the forward
-- migration's first SELECT listed MORE than this id, add those ids here before
-- running — the rollback is deliberately explicit rather than a blanket
-- un-confirm, so it can never strike a legitimately confirmed member.
--
-- This does NOT restore the "Confirm email" GoTrue setting — flip that back on
-- in the Dashboard (Authentication → Sign In / Providers → Email).

begin;

update auth.users
   set email_confirmed_at = null,
       updated_at         = now()
 where id = '88e7ecb1-79ca-4aed-b97b-769f5fc94af0'
   and last_sign_in_at is null;   -- refuse to un-confirm an account already in use

select id, email, email_confirmed_at
  from auth.users
 where id = '88e7ecb1-79ca-4aed-b97b-769f5fc94af0';

commit;
