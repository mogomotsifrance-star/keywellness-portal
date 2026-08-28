-- ============================================================
-- Key Wellness — deleting a user account from the admin dashboard
--
-- Idempotent — safe to re-run.
-- Rollback: migrations/rollback-admin-delete-user.sql
-- Tests:    tests/delete-user-tests.sql (run tests/run-delete-user.sh)
--
-- ══ WHAT THIS IS FOR ═══════════════════════════════════════
--
-- Until now, deleting an account meant hand-writing SQL — see
-- supabase_delete_account_france_prolearn.sql, which took a page of prose to
-- delete ONE admin. That script is the reason this one exists: what it worked
-- out the hard way is encoded here so the next deletion is a button.
--
-- ══ WHY IT IS NOT `delete from auth.users` ═════════════════
--
-- Twenty-one foreign keys point at auth.users with ON DELETE NO ACTION. Every
-- one of them fails the delete until it is dealt with, and two are not called
-- user_id (actions.owner, work_plans.authored_by), so a name-based search
-- misses them. Two further tables reference a user with NO foreign key at all
-- (tool_data, ai_chat_usage) — those do not block the delete, they quietly
-- orphan, which is worse.
--
-- So the references are found by SWEEPING pg_constraint, not by listing column
-- names. _admin_user_refs() does that sweep at call time, which means the
-- preview stays truthful when a new table is added. What each reference MEANS
-- is the one thing a sweep cannot infer, so that lives in
-- _admin_user_delete_plan() as an explicit four-way classification:
--
--   member    rows ABOUT the person       -> deleted
--   grant     a role held by the person   -> deleted
--   unlink    a record that outlives them -> link nulled, row kept
--   reassign  something they AUTHORED     -> repointed to a surviving account
--
-- A reference with no classification is a BLOCKER, not a guess. Add a table
-- with a new FK to auth.users and the delete refuses, naming the column, until
-- somebody decides which of the four it is. That is the safe default: the
-- failure mode of guessing is silently destroying an audit trail.
--
-- ══ THE SUPPORT AUDIT TRAIL — A DELIBERATE SCHEMA CHANGE ═══
--
-- support_actions.actor is NOT NULL REFERENCES auth.users NO ACTION. As it
-- stood, an admin who had ever used the Support screen could NEVER be deleted:
-- the row cannot be removed (that is the point of an audit trail), the column
-- cannot be nulled, and repointing it at another admin would be a lie about
-- who did the thing.
--
-- Since admins are exactly the people who use the Support screen, that made a
-- delete button useless for staff. So this migration WIDENS the trail rather
-- than rewriting it:
--
--   * support_actions gains actor_email and target_email, backfilled.
--   * actor becomes nullable; both FKs become ON DELETE SET NULL.
--   * support_log() records both addresses at write time.
--   * support_recent() falls back to the stored address when the uuid is gone.
--
-- Nothing is amended and nothing is removed. When an account goes, its rows
-- keep the identity a human actually reads — the address — and lose only a
-- pointer to a row that no longer exists. The delete path never UPDATEs or
-- DELETEs a support_actions row; §6 asserts that it cannot start to.
--
-- ══ WHAT DELETION COSTS, STATED PLAINLY ════════════════════
--
--   * The password hash and the auth identity are destroyed. There is no
--     restore. Re-creating the person means a NEW uuid — see the rollback.
--   * Their bookings are deleted, so organisation utilisation recalculated
--     AFTER the deletion differs from before. Already-published org_reports
--     hold their own snapshot and do not change.
--   * A counselling or advisory caseload row is kept and unlinked, not
--     deleted. Clinical records are not collateral of an account deletion.
--
-- ══ THE FOUR REFUSALS ══════════════════════════════════════
--
--   1. You cannot delete yourself.
--   2. You cannot delete the last remaining admin.
--   3. You must type the account's email address back.
--   4. Any reference the plan does not classify stops the whole thing.
--
-- Refusal 2 cannot fire while refusal 1 stands, and that is not an oversight:
-- the caller is an admin, is not the target, and therefore always survives the
-- delete, so a lockout is already impossible. It is written down anyway so
-- that removing refusal 1 — for a "let admins close their own account"
-- feature, say — does not silently make lockout possible again. Refusal 2 is
-- asserted by §6 rather than by the test suite, because no reachable state
-- exercises it.
--
-- Every entry point is gated on is_admin(). Both helpers are `_`-prefixed
-- SECURITY DEFINER and are REVOKEd from public/anon/authenticated, per the
-- rule in CLAUDE.md.
-- ============================================================


-- ── 1. The support audit trail keeps its identities ─────────

do $$
begin
  if to_regclass('public.support_actions') is null then
    raise exception 'apply supabase_support_audit.sql first — support_actions does not exist';
  end if;
  -- support_log() and support_recent() are re-created below, gated on
  -- is_admin(). supabase_support_audit.sql wrote them against is_ops_admin(),
  -- which M4a REMOVED — so the text there is stale, and re-applying it would
  -- point the Support screen at a function that does not exist. Refuse rather
  -- than create a body that only fails when somebody clicks.
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'is_admin') then
    raise exception 'is_admin() does not exist — this migration gates everything on it';
  end if;
end $$;

alter table support_actions add column if not exists actor_email  text;
alter table support_actions add column if not exists target_email text;

update support_actions s
   set actor_email = lower(u.email)
  from auth.users u
 where u.id = s.actor and s.actor_email is null;

update support_actions s
   set target_email = lower(u.email)
  from auth.users u
 where u.id = s.target_user and s.target_email is null;

alter table support_actions alter column actor drop not null;

do $$
declare r record;
begin
  -- Repoint both FKs at ON DELETE SET NULL. Found by catalogue, not by
  -- constraint name — auto-generated names differ between environments.
  for r in
    select c.conname, a.attname
      from pg_constraint c
      join lateral unnest(c.conkey) k(attnum) on true
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
     where c.contype   = 'f'
       and c.conrelid  = 'public.support_actions'::regclass
       and c.confrelid = 'auth.users'::regclass
       and c.confdeltype <> 'n'
  loop
    execute format('alter table support_actions drop constraint %I', r.conname);
    execute format('alter table support_actions add constraint %I foreign key (%I) '
                   'references auth.users(id) on delete set null',
                   'support_actions_' || r.attname || '_fkey', r.attname);
  end loop;
end $$;

-- 'delete_user' joins the allowed actions. Replaced rather than
-- added-if-missing: it already exists, with a narrower list.
alter table support_actions drop constraint if exists support_actions_action_check;
alter table support_actions add constraint support_actions_action_check
  check (action in ('lookup','send_password_reset','resend_booking_confirmation','delete_user'));

-- support_log(), unchanged in signature and in its refusal to take an actor
-- from an argument. It now also stores the two addresses, so the trail stays
-- readable after either account is gone.
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
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;
  if auth.uid() is null then
    raise exception 'no caller identity';
  end if;

  insert into support_actions (actor, actor_email, action, target_user, target_email,
                               target_booking, outcome, detail)
  values (auth.uid(),
          lower(auth.jwt() ->> 'email'),
          p_action,
          p_target_user,
          (select lower(email) from auth.users where id = p_target_user),
          p_target_booking,
          p_outcome,
          left(coalesce(p_detail, ''), 500))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function support_log(text, text, uuid, uuid, text) to authenticated;

-- Reads the stored address once the account it pointed at is gone.
create or replace function support_recent(p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not coalesce(is_admin(), false) then
    raise exception 'not authorised';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id,
             'at', s.created_at,
             'actor', coalesce(au.email, s.actor_email),
             'action', s.action,
             'target', coalesce(tu.email, s.target_email),
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


-- ── 2. What each reference to a user MEANS ──────────────────
-- The one thing the pg_constraint sweep cannot work out for itself. Anything
-- absent from this list is treated as a blocker, never as a default.
--
--   member    delete the row      — it is a record OF that person
--   grant     delete the row      — it is a role they held
--   unlink    null the column     — the record outlives the account
--   reassign  repoint the column  — they authored or owned it
--
-- Columns whose FK already says ON DELETE CASCADE or SET NULL are absent on
-- purpose: PostgreSQL does them, and listing them here would do the work
-- twice. The sweep still reports them, so the preview can show them.

create or replace function _admin_user_delete_plan()
returns table (tbl text, col text, mode text)
language sql
immutable
as $$
  select * from (values
    -- Records OF the person.
    ('bookings',              'user_id',                 'member'),
    ('reward_fulfilments',    'user_id',                 'member'),
    ('tool_data',             'user_id',                 'member'),   -- no FK
    ('ai_chat_usage',         'user_id',                 'member'),   -- no FK
    -- A role they held. (admins / employers / hr_unit_scope / advisors /
    -- counsellors are keyed by EMAIL as well, and are handled by name inside
    -- admin_user_delete — an email-keyed grant is invisible to an FK sweep.)
    ('psychosocial_admins',   'user_id',                 'grant'),
    -- Records that outlive the account. A caseload row carries the clinical
    -- history; deleting the account must not delete the case.
    ('counsellor_clients',    'member_user_id',          'unlink'),
    ('counsellors',           'user_id',                 'unlink'),
    -- Things they authored, owned, or confirmed.
    ('actions',               'created_by',              'reassign'),
    ('actions',               'owner',                   'reassign'),
    ('advisor_clients',       'created_by',              'reassign'),
    ('advisors',              'created_by',              'reassign'),
    ('billing_handovers',     'prepared_by',             'reassign'),
    ('billing_handovers',     'invoice_confirmed_by',    'reassign'),
    ('bookings',              'attendance_confirmed_by', 'reassign'),
    ('meetings',              'created_by',              'reassign'),
    ('org_contracts',         'created_by',              'reassign'),
    ('org_contracts',         'account_manager',         'reassign'),
    ('org_headcount_reports', 'reported_by',             'reassign'), -- no FK
    ('org_reports',           'created_by',              'reassign'),
    ('org_reports',           'published_by',            'reassign'),
    ('program_activities',    'created_by',              'reassign'),
    ('reward_fulfilments',    'fulfilled_by',            'reassign'), -- no FK
    ('work_plans',            'authored_by',             'reassign')
  ) t(tbl, col, mode);
$$;

revoke execute on function _admin_user_delete_plan() from public, anon, authenticated;


-- ── 3. Every reference to one account, counted ──────────────
-- Sweeps pg_constraint for FKs to auth.users, then adds the handful of columns
-- that reference a user WITHOUT one. Returns a row per column holding at least
-- one reference, with its delete rule and its classification.
--
--   rule  c = cascade   n = set null   a = no action   x = no FK at all
--
-- Only 'a' and 'x' need doing by hand; 'c' and 'n' are reported so the preview
-- can tell an admin what the database will do on its own.

create or replace function _admin_user_refs(p_user uuid)
returns table (tbl text, col text, del_rule text, mode text, n bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  r record;
  v bigint;
begin
  for r in
    select c.conrelid::regclass::text as t,
           a.attname::text            as c,
           case c.confdeltype when 'c' then 'c' when 'n' then 'n' else 'a' end as d
      from pg_constraint c
      join lateral unnest(c.conkey) k(attnum) on true
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
     where c.contype      = 'f'
       and c.confrelid    = 'auth.users'::regclass
       and c.connamespace = 'public'::regnamespace
    union all
    -- Referencing columns with NO foreign key. Counted only while they still
    -- have none, so adding one later does not double-count.
    select p.tbl, p.col, 'x'
      from _admin_user_delete_plan() p
     where to_regclass('public.' || p.tbl) is not null
       and not exists (
         select 1
           from pg_constraint c
           join lateral unnest(c.conkey) k(attnum) on true
           join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
          where c.contype   = 'f'
            and c.confrelid = 'auth.users'::regclass
            and c.conrelid  = to_regclass('public.' || p.tbl)
            and a.attname   = p.col)
  loop
    if to_regclass(r.t) is null then continue; end if;
    execute format('select count(*) from %s where %I = $1', r.t, r.c)
       into v using p_user;
    if v > 0 then
      tbl := r.t; col := r.c; del_rule := r.d; n := v;
      select p.mode into mode
        from _admin_user_delete_plan() p
       where p.tbl = r.t and p.col = r.c;
      if mode is null then
        -- Cascade and set-null need no plan entry: the database does them.
        mode := case r.d when 'c' then 'auto-delete'
                         when 'n' then 'auto-unlink'
                         else 'UNCLASSIFIED' end;
      end if;
      return next;
    end if;
  end loop;
end $$;

revoke execute on function _admin_user_refs(uuid) from public, anon, authenticated;


-- ── 4. admin_user_delete_preview() ──────────────────────────
-- Everything an admin should read BEFORE they confirm. Takes an id OR an
-- email: an account that never finished onboarding has no profiles row and so
-- never appears in the users table, and those are exactly the ones most often
-- worth deleting.

create or replace function admin_user_delete_preview(
  p_user_id uuid default null,
  p_email   text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_id       uuid;
  v_email    text;
  v_roles    text[] := '{}';
  v_blockers text[] := '{}';
  v_refs     jsonb;
  v_admins   int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select u.id, lower(u.email) into v_id, v_email
    from auth.users u
   where (p_user_id is not null and u.id = p_user_id)
      or (p_user_id is null and p_email is not null
          and lower(u.email) = lower(trim(p_email)))
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'msg', 'No account found.');
  end if;

  if exists (select 1 from admins where lower(email) = v_email)
    then v_roles := v_roles || 'admin'; end if;
  if exists (select 1 from employers where user_id = v_id or lower(email) = v_email)
    then v_roles := v_roles || 'hr'; end if;
  if exists (select 1 from advisors where user_id = v_id or lower(email) = v_email)
    then v_roles := v_roles || 'advisor'; end if;
  if to_regclass('public.counsellors') is not null
     and exists (select 1 from counsellors where user_id = v_id or lower(email) = v_email)
    then v_roles := v_roles || 'counsellor'; end if;
  if to_regclass('public.psychosocial_admins') is not null
     and exists (select 1 from psychosocial_admins where user_id = v_id or lower(email) = v_email)
    then v_roles := v_roles || 'psychosocial_admin'; end if;
  if exists (select 1 from profiles where id = v_id)
    then v_roles := v_roles || 'member'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'table', r.tbl, 'column', r.col, 'rule', r.del_rule,
           'mode',  r.mode, 'n', r.n) order by r.mode, r.tbl, r.col), '[]'::jsonb)
    into v_refs
    from _admin_user_refs(v_id) r;

  -- Refusal 1: yourself.
  if v_id = auth.uid() or v_email = lower(auth.jwt() ->> 'email') then
    v_blockers := v_blockers || 'This is your own account. Ask another admin to delete it.';
  end if;

  -- Refusal 2: the last admin.
  select count(*) into v_admins from admins;
  if 'admin' = any(v_roles) and v_admins <= 1 then
    v_blockers := v_blockers ||
      'This is the only admin account. Deleting it would lock everyone out of the admin dashboard.';
  end if;

  -- Refusal 4: a reference nobody has classified.
  v_blockers := v_blockers || coalesce((
    select array_agg(format('Unclassified reference: %s.%s holds %s row(s). '
                            'Add it to _admin_user_delete_plan() before deleting.',
                            r->>'table', r->>'column', r->>'n'))
      from jsonb_array_elements(v_refs) r
     where r->>'mode' = 'UNCLASSIFIED'), '{}');

  return jsonb_build_object(
    'ok',           true,
    'user_id',      v_id,
    'email',        v_email,
    'name',         (select nullif(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), '')
                       from profiles where id = v_id),
    'org',          (select o.name from profiles p
                       join organizations o on o.id = p.org_id where p.id = v_id),
    'created_at',   (select created_at        from auth.users where id = v_id),
    'last_sign_in', (select last_sign_in_at   from auth.users where id = v_id),
    'roles',        to_jsonb(v_roles),
    'refs',         v_refs,
    'reassign_n',   (select coalesce(sum((r->>'n')::bigint), 0)
                       from jsonb_array_elements(v_refs) r where r->>'mode' = 'reassign'),
    'delete_n',     (select coalesce(sum((r->>'n')::bigint), 0)
                       from jsonb_array_elements(v_refs) r
                      where r->>'mode' in ('member', 'auto-delete')),
    'reassign_to',  lower(auth.jwt() ->> 'email'),
    'blockers',     to_jsonb(v_blockers)
  );
end $$;

grant execute on function admin_user_delete_preview(uuid, text) to authenticated;


-- ── 5. admin_user_delete() ──────────────────────────────────
-- p_confirm_email must equal the account's own address. That is not a
-- formality: the id arrives from a table row, and the address is the only
-- thing the admin has actually read.
--
-- p_reassign_to defaults to the admin doing the deleting — the same choice
-- supabase_delete_account_france_prolearn.sql made by hand. Every surviving
-- record then names a real account.

create or replace function admin_user_delete(
  p_user_id       uuid,
  p_confirm_email text,
  p_reassign_to   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_email    text;
  v_to       uuid;
  v_to_email text;
  v_admins   int;
  r          record;
  v_n        bigint;
  v_done     jsonb := '{}'::jsonb;
  v_left     bigint;
  v_stuck    text;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select lower(u.email) into v_email from auth.users u where u.id = p_user_id;
  if v_email is null then raise exception 'no account with that id'; end if;

  -- Refusal 3, before anything else: the address must be typed back.
  if lower(trim(coalesce(p_confirm_email, ''))) <> v_email then
    raise exception 'the confirmation email does not match this account';
  end if;

  -- Refusal 1: yourself.
  if p_user_id = auth.uid() or v_email = lower(auth.jwt() ->> 'email') then
    raise exception 'you cannot delete your own account';
  end if;

  -- Refusal 2: the last admin. Unreachable while refusal 1 stands — see the
  -- header. Kept so that removing refusal 1 cannot quietly reopen lockout.
  select count(*) into v_admins from admins;
  if exists (select 1 from admins where lower(email) = v_email) and v_admins <= 1 then
    raise exception 'this is the only admin account — deleting it would lock everyone out';
  end if;

  -- Refusal 4: anything unclassified stops the whole thing, before any write.
  select string_agg(format('%s.%s (%s rows)', r2.tbl, r2.col, r2.n), ', ')
    into v_stuck
    from _admin_user_refs(p_user_id) r2
   where r2.mode = 'UNCLASSIFIED';
  if v_stuck is not null then
    raise exception 'unclassified reference(s) to this account: %. '
                    'Add them to _admin_user_delete_plan() first.', v_stuck;
  end if;

  v_to := coalesce(p_reassign_to, auth.uid());
  if v_to is null then raise exception 'no caller identity'; end if;
  if v_to = p_user_id then
    raise exception 'cannot reassign this account''s records to itself';
  end if;
  select lower(email) into v_to_email from auth.users where id = v_to;
  if v_to_email is null then
    raise exception 'the account to reassign records to does not exist';
  end if;

  -- ── Deletes first, so nothing is reassigned that is about to go ──
  -- (one person can be both the subject of a booking and, as staff, the one
  -- who confirmed attendance on a different one.)
  for r in select p.tbl, p.col from _admin_user_delete_plan() p
            where p.mode in ('member', 'grant') order by p.tbl, p.col
  loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format('delete from %I where %I = $1', r.tbl, r.col) using p_user_id;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_done := v_done || jsonb_build_object(r.tbl || '.' || r.col, v_n); end if;
  end loop;

  -- ── Records that outlive the account ──
  for r in select p.tbl, p.col from _admin_user_delete_plan() p
            where p.mode = 'unlink' order by p.tbl, p.col
  loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format('update %I set %I = null where %I = $1', r.tbl, r.col, r.col)
      using p_user_id;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_done := v_done || jsonb_build_object(r.tbl || '.' || r.col, v_n); end if;
  end loop;

  -- ── Things they authored ──
  for r in select p.tbl, p.col from _admin_user_delete_plan() p
            where p.mode = 'reassign' order by p.tbl, p.col
  loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format('update %I set %I = $2 where %I = $1', r.tbl, r.col, r.col)
      using p_user_id, v_to;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_done := v_done || jsonb_build_object(r.tbl || '.' || r.col, v_n); end if;
  end loop;

  -- ── Email-keyed role grants, invisible to any FK sweep ──
  delete from admins        where lower(email)    = v_email;
  delete from employers     where lower(email)    = v_email;
  delete from hr_unit_scope where lower(hr_email) = v_email;
  if to_regclass('public.psychosocial_admins') is not null then
    delete from psychosocial_admins where lower(email) = v_email;
  end if;

  -- Rosters are closed, not deleted: an advisor's row is the anchor for their
  -- caseload and their notes. Clearing user_id and is_active means a future
  -- account on the same address does not silently inherit the role.
  update advisors set is_active = false, user_id = null
   where user_id = p_user_id or lower(email) = v_email;
  if to_regclass('public.counsellors') is not null then
    update counsellors set is_active = false, user_id = null
     where user_id = p_user_id or lower(email) = v_email;
  end if;

  -- ── Re-sweep. Refuses rather than hitting a foreign-key violation ──
  select coalesce(sum(r2.n), 0) into v_left
    from _admin_user_refs(p_user_id) r2
   where r2.del_rule = 'a';
  if v_left > 0 then
    raise exception 'still % blocking reference(s) after the plan ran — nothing deleted', v_left;
  end if;

  delete from auth.users where id = p_user_id;

  -- The audit entry outlives the account, so it holds the address rather than
  -- a pointer to a row that no longer exists.
  insert into support_actions (actor, actor_email, action, target_user, target_email,
                               outcome, detail)
  values (auth.uid(), lower(auth.jwt() ->> 'email'), 'delete_user', null, v_email, 'ok',
          left('deleted ' || v_email || ' (' || p_user_id || '); records reassigned to '
               || v_to_email || '; ' || v_done::text, 500));

  return jsonb_build_object(
    'ok',            true,
    'email',         v_email,
    'reassigned_to', v_to_email,
    'changed',       v_done,
    'msg',           'Account ' || v_email || ' deleted.'
  );
end $$;

grant execute on function admin_user_delete(uuid, text, uuid) to authenticated;


-- ── 6. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  -- The two helpers must not be reachable with the published anon key.
  -- CLAUDE.md's rule: PUBLIC holds EXECUTE on every new function until it is
  -- revoked, and SECURITY DEFINER bypasses RLS.
  if has_function_privilege('anon',          '_admin_user_refs(uuid)',     'EXECUTE')
  or has_function_privilege('authenticated', '_admin_user_refs(uuid)',     'EXECUTE')
  or has_function_privilege('anon',          '_admin_user_delete_plan()',  'EXECUTE')
  or has_function_privilege('authenticated', '_admin_user_delete_plan()',  'EXECUTE') then
    raise exception 'delete-user: an internal helper is still reachable by anon/authenticated';
  end if;

  -- Both entry points must gate. A delete RPC that forgets is_admin() is a
  -- public account-deletion endpoint.
  if (select prosrc from pg_proc where proname = 'admin_user_delete') !~* '\mis_admin\M' then
    raise exception 'delete-user: admin_user_delete is not gated on is_admin()';
  end if;
  if (select prosrc from pg_proc where proname = 'admin_user_delete_preview') !~* '\mis_admin\M' then
    raise exception 'delete-user: admin_user_delete_preview is not gated on is_admin()';
  end if;

  -- The delete path may only APPEND to the support audit trail. An UPDATE or
  -- DELETE here would mean the trail can be rewritten by the very thing it
  -- exists to record.
  if (select prosrc from pg_proc where proname = 'admin_user_delete')
     ~* '(update|delete\s+from)\s+support_actions' then
    raise exception 'delete-user: admin_user_delete amends support_actions';
  end if;

  -- Refusals 1 and 2 must live in the delete itself, not only in the preview —
  -- the preview is advisory, the RPC is the control.
  if (select prosrc from pg_proc where proname = 'admin_user_delete') !~* 'own account' then
    raise exception 'delete-user: admin_user_delete lost the self-delete refusal';
  end if;
  if (select prosrc from pg_proc where proname = 'admin_user_delete') !~* 'only admin account' then
    raise exception 'delete-user: admin_user_delete lost the last-admin refusal';
  end if;

  select count(*) into n from support_actions where actor is not null and actor_email is null;
  if n > 0 then
    raise exception 'delete-user: % support_actions row(s) have no actor_email after backfill', n;
  end if;

  raise notice 'delete-user applied. Every reference to an account is swept from '
               'pg_constraint and classified; an unclassified one refuses the delete.';
end $$;
