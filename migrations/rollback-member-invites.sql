-- ============================================================
-- Key Wellness — rollback for supabase_member_invites.sql
-- Run in the Supabase SQL Editor. Idempotent.
--
-- Restores handle_new_user() and support_can() to their pre-invite bodies
-- (the live bodies as read on 3 Sep 2026), removes 'send_invite' from the
-- audit action check, and drops the invite functions and table.
--
-- Deploy the previous admin-support Edge Function version BEFORE running
-- this, or its send_invite action will fail loudly (which is the safe
-- failure — nothing is sent).
--
-- Audit rows with action = 'send_invite' would violate the restored check,
-- so they are relabelled 'lookup' with the original action prefixed into
-- detail rather than deleted: the trail is never shortened by a rollback.
-- ============================================================

drop function if exists invite_list(uuid, int);
drop function if exists invite_mark(uuid, text, text);
drop function if exists invite_to_send(uuid);
drop function if exists invite_stage(uuid, uuid, jsonb);

-- handle_new_user — pre-invite body
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  code     text;
  resolved uuid;
begin
  code := upper(coalesce(new.raw_user_meta_data ->> 'invite_code', ''));

  if code <> '' then
    select id into resolved
    from organizations
    where upper(invite_code) = code
      and is_active = true;
  end if;

  insert into profiles (id, org_id)
  values (new.id, resolved)
  on conflict (id) do update
    set org_id = coalesce(profiles.org_id, excluded.org_id);

  return new;
end $$;

-- support_can — pre-invite body
create or replace function support_can(p_action text, p_target_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_day_start timestamptz := (date_trunc('day', now() at time zone 'Africa/Gaborone'))
                             at time zone 'Africa/Gaborone';
  n_actor_day    int;
  n_actor_minute int;
  n_target_day   int;
  n_global_day   int;
begin
  if not coalesce(is_admin(), false) then
    return jsonb_build_object('allowed', false, 'reason', 'not authorised');
  end if;

  select count(*) into n_actor_day
    from support_actions
   where actor = auth.uid() and outcome = 'ok' and created_at >= v_day_start;
  if n_actor_day >= 30 then
    return jsonb_build_object('allowed', false, 'reason', 'daily limit reached (30)');
  end if;

  select count(*) into n_actor_minute
    from support_actions
   where actor = auth.uid() and created_at >= now() - interval '1 minute';
  if n_actor_minute >= 5 then
    return jsonb_build_object('allowed', false, 'reason', 'too fast — wait a minute');
  end if;

  if p_action = 'send_password_reset' and p_target_user is not null then
    select count(*) into n_target_day
      from support_actions
     where action = 'send_password_reset' and target_user = p_target_user
       and outcome = 'ok' and created_at >= v_day_start;
    if n_target_day >= 3 then
      return jsonb_build_object('allowed', false,
        'reason', 'this member has already had 3 reset links today');
    end if;
  end if;

  select count(*) into n_global_day
    from support_actions
   where outcome = 'ok' and created_at >= v_day_start;
  if n_global_day >= 100 then
    return jsonb_build_object('allowed', false, 'reason', 'daily limit reached for the whole team');
  end if;

  return jsonb_build_object('allowed', true, 'reason', null);
end $$;

grant execute on function support_can(text, uuid) to authenticated;

-- audit action check — back to the four actions
update support_actions
   set action = 'lookup', detail = left('send_invite: ' || coalesce(detail,''), 500)
 where action = 'send_invite';

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'support_actions_action_check') then
    alter table support_actions drop constraint support_actions_action_check;
  end if;
  alter table support_actions add constraint support_actions_action_check
    check (action in ('lookup','send_password_reset','resend_booking_confirmation','delete_user'));
end $$;

drop table if exists member_invites;

do $$
begin
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relname = 'member_invites') then
    raise exception 'rollback incomplete: member_invites still exists';
  end if;
  raise notice 'member invites rolled back.';
end $$;
