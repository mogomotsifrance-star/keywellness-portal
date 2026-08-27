-- ============================================================
-- Rollback — M3a: the referral accept flow
--
-- Idempotent. Leaves ZERO objects behind.
--
-- WHAT IT DOES NOT UNDO: caseload links already opened or closed by an accept.
-- Those are real clinical facts — a counsellor took on a case — and a schema
-- rollback has no business rewriting them. If you need to reverse a specific
-- acceptance, do it deliberately and by hand:
--
--   the closed link:  update counsellor_clients
--                        set is_active = true, ended_at = null where id = ...;
--   the new link:     update counsellor_clients
--                        set is_active = false, ended_at = now() where id = ...;
--   the referral:     update counselling_referrals
--                        set accepted_at = null where id = ...;
--
-- Note that even that does not un-share the handover note, which the receiving
-- counsellor has already read. Nothing can.
-- ============================================================

drop function if exists referral_accept(uuid);

do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'referral_accept') then
    raise exception 'M3a rollback incomplete: referral_accept survives';
  end if;

  -- M3's own objects are not M3a's to remove. Reported, NOT raised: on a
  -- second pass, or after M3 has been rolled back first, counselling_referrals
  -- is legitimately gone and that is not this file's doing. An assertion here
  -- would fail a correct sequence, which is worse than saying nothing.
  if to_regclass('public.counselling_referrals') is null then
    raise notice 'M3a rollback: counselling_referrals is absent — M3 has '
                 'already been rolled back. Nothing here removed it.';
  end if;

  raise notice 'M3a rollback clean. Caseload links already opened or closed by '
               'an acceptance are LEFT ALONE — they are clinical facts, not '
               'schema.';
end $$;
