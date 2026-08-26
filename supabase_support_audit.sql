-- ============================================================
-- Key Wellness — member support: the audit trail and its gate
--
-- The database half of the admin-support Edge Function (Prompt 4).
-- Run in the Supabase SQL Editor. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-support-audit.sql
-- Tests:    tests/support-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/support-verify-live.sql (read-only, this editor)
--
-- ── WHY THE AUTHORISATION LIVES HERE AND NOT IN DENO ────────
--
-- The Edge Function holds the service role, which bypasses every policy in
-- this database. If it also decided who may act, the whole authorisation
-- model would live in a TypeScript file with a key that can do anything.
--
-- So the split is: this file decides WHO MAY and records WHAT HAPPENED; the
-- Edge Function does only the things a database cannot — verify a JWT and
-- call the Auth admin API. Every function below is called BY THE EDGE
-- FUNCTION AS THE SIGNED-IN USER, not as the service role, so is_ops_admin()
-- is evaluated against the real caller.
--
-- This is the pattern booking_notify_payload() already uses, and for the same
-- reason: see the header of supabase/functions/send-booking-email/index.ts,
-- which documents what happened the last time an Edge Function decided for
-- itself who the recipient was.
--
-- ── THE NULL TRAP ───────────────────────────────────────────
--
-- Every gate below reads `if not coalesce(is_ops_admin(), false)`. Written as
-- a bare `if not is_ops_admin()`, an unauthenticated caller makes auth.uid()
-- null, which can make the function null, and PL/pgSQL DOES NOT TAKE AN
-- `if null` BRANCH — the raise is skipped and the caller is let through.
-- booking_notify_payload() carries the same guard with the same warning:
-- "Do not 'simplify' this back."
-- ============================================================


-- ── 1. is_ops_admin() ───────────────────────────────────────
-- Defined now as is_admin(). M3 replaces the body with the ops-admin split
-- and NOTHING ELSE CHANGES — every caller already asks the right question.
--
-- Decided 26 Aug: gate the support functions on this from the start rather
-- than on is_admin() directly. France holds admin, and when M3 lands he must
-- lose the ability to trigger a password reset for a counselling client. One
-- function changes; no call site is revisited.

create or replace function is_ops_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  -- M3: replace with the ops-admin mechanism (admins.lines, ops_admins, or a
  -- split of is_admin()). Until then every admin is an ops admin.
  select is_admin();
$$;

grant execute on function is_ops_admin() to authenticated;


-- ── 2. The audit trail ──────────────────────────────────────
-- Denied and failed attempts are recorded too. A support log that only holds
-- successes cannot answer "who tried", which is the question it exists for.

create table if not exists support_actions (
  id             uuid primary key default gen_random_uuid(),
  actor          uuid not null references auth.users(id),
  action         text not null,
  target_user    uuid references auth.users(id),
  target_booking uuid references bookings(id) on delete set null,
  outcome        text not null,
  detail         text,
  created_at     timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'support_actions_action_check') then
    alter table support_actions add constraint support_actions_action_check
      check (action in ('lookup','send_password_reset','resend_booking_confirmation'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'support_actions_outcome_check') then
    alter table support_actions add constraint support_actions_outcome_check
      check (outcome in ('ok','denied','error'));
  end if;
end $$;

create index if not exists support_actions_actor_idx   on support_actions (actor, created_at desc);
create index if not exists support_actions_target_idx  on support_actions (target_user, created_at desc);
create index if not exists support_actions_recent_idx  on support_actions (created_at desc);

alter table support_actions enable row level security;

-- READ ONLY, and only for an ops admin. There is deliberately no INSERT,
-- UPDATE or DELETE policy: rows are written by support_log() (definer) and
-- nobody can amend or remove one, including the person who caused it.
drop policy if exists support_actions_admin_read on support_actions;
create policy support_actions_admin_read on support_actions
  for select using (is_ops_admin());

revoke insert, update, delete on table support_actions from anon, authenticated;


-- ── 3. support_lookup() ─────────────────────────────────────
-- Finds the person the admin means. Returns FULL email addresses: an admin
-- already sees every member address on the admin users page, and masking here
-- would add friction without adding a control (decided 26 Aug). The control
-- that matters is elsewhere — see support_can() and the Edge Function: the
-- caller passes back a user_id from THIS result, never an address.

create or replace function support_lookup(p_q text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_q text := btrim(coalesce(p_q, ''));
begin
  if not coalesce(is_ops_admin(), false) then
    raise exception 'not authorised';
  end if;

  -- Three characters is enough to be a search and short enough to be useful;
  -- an empty query must not return the whole membership.
  if length(v_q) < 3 then
    raise exception 'search needs at least 3 characters';
  end if;

  return coalesce((
    select jsonb_agg(x order by x ->> 'email')
      from (
        select jsonb_build_object(
                 'user_id', u.id,
                 'email',   u.email,
                 'name',    btrim(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')),
                 'roles',   (
                   select coalesce(jsonb_agg(r), '[]'::jsonb) from (
                     select 'member' as r where p.id is not null
                     union all
                     select 'admin'   where exists (select 1 from admins a
                                                    where lower(a.email) = lower(u.email))
                     union all
                     select 'advisor' where exists (select 1 from advisors ad
                                                    where ad.is_active
                                                      and (ad.user_id = u.id
                                                        or lower(ad.email) = lower(u.email)))
                     union all
                     select 'hr'      where exists (select 1 from employers e
                                                    where e.user_id = u.id
                                                       or lower(e.email) = lower(u.email))
                   ) rr
                 ),
                 'created_at', u.created_at
               ) as x
          from auth.users u
          left join profiles p on p.id = u.id
         where u.email ilike '%' || v_q || '%'
            or btrim(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')) ilike '%' || v_q || '%'
         limit 10
      ) s
  ), '[]'::jsonb);
end $$;

grant execute on function support_lookup(text) to authenticated;


-- ── 4. support_can() — the gate and the three rate limits ───
-- Called before every privileged action. Returns {allowed, reason} rather
-- than raising, so the Edge Function can record a 'denied' audit row and
-- answer the caller in one shape.
--
-- Windows are Gaborone days, not UTC days — the same boundary ai_chat_usage
-- uses, so a limit resets when the working day does.

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
  if not coalesce(is_ops_admin(), false) then
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

  -- The axis that actually matters. Repeated resets against ONE person is
  -- what an attacker does; the actor's own daily cap would never notice it.
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


-- ── 5. support_log() ────────────────────────────────────────
-- The only way a row reaches support_actions. Writes the actor from
-- auth.uid(), never from an argument, so a caller cannot log as someone else.

create or replace function support_log(
  p_action         text,
  p_outcome        text,
  p_target_user    uuid default null,
  p_target_booking uuid default null,
  p_detail         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
begin
  if not coalesce(is_ops_admin(), false) then
    raise exception 'not authorised';
  end if;
  if auth.uid() is null then
    raise exception 'no caller identity';
  end if;

  insert into support_actions (actor, action, target_user, target_booking, outcome, detail)
  values (auth.uid(), p_action, p_target_user, p_target_booking, p_outcome,
          left(coalesce(p_detail, ''), 500))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function support_log(text, text, uuid, uuid, text) to authenticated;


-- ── 6. support_recent() ─────────────────────────────────────
-- The Support screen's left column. The audit trail is the primary content of
-- that screen, not a hidden table — a support tool nobody can see the use of
-- is a support tool nobody can hold to account.

create or replace function support_recent(p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not coalesce(is_ops_admin(), false) then
    raise exception 'not authorised';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id,
             'at', s.created_at,
             'actor', au.email,
             'action', s.action,
             'target', tu.email,
             'outcome', s.outcome,
             'detail', s.detail
           ) order by s.created_at desc)
      from (select * from support_actions
             order by created_at desc
             limit greatest(1, least(coalesce(p_limit, 50), 200))) s
      left join auth.users au on au.id = s.actor
      left join auth.users tu on tu.id = s.target_user
  ), '[]'::jsonb);
end $$;

grant execute on function support_recent(int) to authenticated;


-- ── 7. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'support_actions';
  if n <> 1 then
    raise exception 'support: expected exactly 1 policy on support_actions (read), found %', n;
  end if;

  if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                  where ns.nspname='public' and c.relname='support_actions' and c.relrowsecurity) then
    raise exception 'support: RLS is not enabled on support_actions';
  end if;

  raise notice 'support audit applied. Remember: M3 replaces the body of '
               'is_ops_admin() and France loses this capability at that point.';
end $$;
