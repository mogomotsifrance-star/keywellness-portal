-- ============================================================
-- Rollback — M3b: declining a referral
--
-- Idempotent. Leaves ZERO objects behind.
--
-- ══ THIS DESTROYS A CLINICAL FACT ══════════════════════════
--
-- Dropping declined_at DELETES THE RECORD THAT A COUNSELLOR SAID NO. There is
-- no backup column and nowhere else that fact is written down. After this,
-- every declined referral looks identical to one nobody has read yet — which
-- is the exact ambiguity M3b was built to end.
--
-- If any referral has been declined, EXPORT FIRST:
--
--   select id, from_counsellor_id, to_counsellor_id, declined_at
--     from counselling_referrals where declined_at is not null;
--
-- The block below refuses to run while declined referrals exist, precisely so
-- that this is a decision somebody makes rather than a consequence they
-- discover. Clear them deliberately if you mean it.
--
-- ORDER: restore the two replaced functions to their M3a bodies BEFORE
-- dropping the column they now reference, or they are left calling a column
-- that is gone.
-- ============================================================


-- ── 0. Refuse to silently destroy the record ────────────────

do $$
declare n int;
begin
  if to_regclass('public.counselling_referrals') is null then
    raise notice 'M3b rollback: counselling_referrals is absent — M3 has '
                 'already been rolled back. Nothing to do.';
    return;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='counselling_referrals'
                    and column_name='declined_at') then
    raise notice 'M3b rollback: declined_at is already gone.';
    return;
  end if;

  execute 'select count(*) from counselling_referrals where declined_at is not null'
    into n;
  if n > 0 then
    raise exception 'M3b rollback: % referral(s) have been DECLINED. Dropping '
                    'declined_at deletes the only record that a counsellor said '
                    'no. Export them, clear them deliberately, then re-run.', n;
  end if;
end $$;


-- ── 1–2. The two replaced functions, back to their M3a bodies ──
--
-- WRAPPED IN A GUARD, because both declare `counselling_referrals%rowtype` and
-- PL/pgSQL resolves that AT COMPILE TIME. On a second pass — or after M3's own
-- rollback has already dropped the table — a bare CREATE OR REPLACE fails with
-- `relation "counselling_referrals" does not exist` before it has done
-- anything. Restoring a function that references a table only makes sense
-- while the table is there.

do $g$
begin
  if to_regclass('public.counselling_referrals') is null then
    raise notice 'M3b rollback: counselling_referrals is absent — skipping the '
                 'function restores, since there is nothing for them to read.';
    return;
  end if;

  execute $f$
    create or replace function referral_accept(p_referral_id uuid)
    returns jsonb
    language plpgsql
    security definer
    set search_path = public, auth
    as $b$
    declare
      r        counselling_referrals%rowtype;
      old_link counsellor_clients%rowtype;
      v_me     uuid := current_counsellor_id();
      v_new    uuid;
      v_now    timestamptz := now();
    begin
      if v_me is null then
        raise exception 'only a counsellor can accept a referral';
      end if;

      select * into r from counselling_referrals where id = p_referral_id;
      if not found then raise exception 'no such referral'; end if;

      if r.to_counsellor_id <> v_me then
        raise exception 'only the counsellor a referral was sent to can accept it';
      end if;

      if r.accepted_at is not null then
        return jsonb_build_object(
          'referral_id', r.id, 'already_accepted', true,
          'accepted_at', r.accepted_at,
          'link_id', (select cc.id from counsellor_clients cc
                       where cc.counsellor_id = v_me and cc.is_active
                         and cc.member_user_id is not distinct from
                             (select member_user_id from counsellor_clients
                               where id = r.counsellor_client_id)
                       limit 1));
      end if;

      select * into old_link from counsellor_clients where id = r.counsellor_client_id;
      if not found then raise exception 'the referred caseload link no longer exists'; end if;

      update counsellor_clients
         set is_active = false, ended_at = v_now
       where id = old_link.id and is_active;

      select cc.id into v_new
        from counsellor_clients cc
       where cc.counsellor_id = v_me
         and cc.is_active
         and cc.member_user_id is not distinct from old_link.member_user_id
         and coalesce(lower(cc.email),'') = coalesce(lower(old_link.email),'')
       limit 1;

      if v_new is null then
        insert into counsellor_clients (counsellor_id, member_user_id, full_name,
                                        email, phone, org_id, is_active)
        values (v_me, old_link.member_user_id, old_link.full_name,
                old_link.email, old_link.phone, old_link.org_id, true)
        returning id into v_new;
      end if;

      update counselling_referrals set accepted_at = v_now where id = r.id;

      return jsonb_build_object(
        'referral_id',      r.id,
        'already_accepted', false,
        'accepted_at',      v_now,
        'closed_link_id',   old_link.id,
        'link_id',          v_new,
        'note',             'The previous counsellor''s notes and bookings remain '
                            || 'theirs and are not readable through this referral.');
    end $b$;
  $f$;

  execute 'grant execute on function referral_accept(uuid) to authenticated';

  execute $f$
    create or replace function referral_fact_list()
    returns jsonb
    language plpgsql
    stable
    security definer
    set search_path = public, auth
    as $b$
    begin
      if not is_psychosocial_admin() then raise exception 'not authorised'; end if;

      return coalesce((
        select jsonb_agg(jsonb_build_object(
                 'referred_on', r.created_at::date,
                 'accepted_on', r.accepted_at::date,
                 'from', f.full_name,
                 'to',   t.full_name
               ) order by r.created_at desc)
          from counselling_referrals r
          join counsellors f on f.id = r.from_counsellor_id
          join counsellors t on t.id = r.to_counsellor_id
      ), '[]'::jsonb);
    end $b$;
  $f$;

  execute 'grant execute on function referral_fact_list() to authenticated';
end $g$;


-- ── 3. Then the function, the constraint and the column ─────

drop function if exists referral_decline(uuid);

do $$
begin
  if to_regclass('public.counselling_referrals') is not null then
    execute 'alter table counselling_referrals '
            'drop constraint if exists counselling_referrals_one_outcome';
    execute 'drop index if exists counselling_referrals_open_idx';
    execute 'alter table counselling_referrals drop column if exists declined_at';
  end if;
end $$;


-- ── 4. Clean-slate verification ─────────────────────────────

do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'referral_decline') then
    raise exception 'M3b rollback incomplete: referral_decline survives';
  end if;

  if to_regclass('public.counselling_referrals') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='counselling_referrals'
                    and column_name='declined_at') then
    raise exception 'M3b rollback incomplete: declined_at survives';
  end if;

  -- referral_accept must no longer reference a column that is gone. Only
  -- checked if it still exists: M3's rollback legitimately removes it.
  if exists (select 1 from pg_proc where proname='referral_accept'
              and prosrc ~* '\mdeclined_at\M') then
    raise exception 'M3b rollback: referral_accept still references declined_at';
  end if;

  raise notice 'M3b rollback clean. NOTE: any record that a counsellor declined '
               'a referral is gone, and a declined referral is once again '
               'indistinguishable from one nobody has read.';
end $$;
