-- ============================================================
-- Key Wellness: internal notes record the author's role (Batch 3, 14 Oct 2026)
-- ============================================================
-- Decision (Tshenolo, 13 Oct 2026): team leads keep the right to set and
-- remove advisor figures (no change). Every figure change must say who made it
-- and in what role, so it is always clear whether an advisor or a team lead
-- made it.
--
-- Before this, the automatic notes named the person ("Saved by France
-- Mogomotsi.") but not the role. Staff can hold several roles (France is
-- advisor, team lead and admin), so the name alone does not say in which
-- capacity they acted.
--
-- Role, decided per client by _advance_actor_role(owner):
--   'assigned advisor'  the caller is the client's advisor (even if also a lead)
--   'team lead'         otherwise, the caller is a team lead
--   'admin'             otherwise, the caller is an admin
--   'staff'             any other caller the RPC's own gate let through (none today)
--
-- ADDS: advance_internal_notes.actor_role, helper _advance_actor_role (revoked).
-- CHANGES five existing bodies by substitution on the LIVE definition (the M3
-- pattern: read pg_get_functiondef, replace exact text, assert each replacement
-- happened exactly once, execute). Nothing is retyped. Bodies backed up first
-- under kw_fn_backup tag 'advance-notes-role':
--   advance_override_save      "Saved by NAME (ROLE)."        + actor_role
--   advance_override_remove    "removed by NAME (ROLE)."      + actor_role
--   advance_internal_note_add  actor_role on advisor notes; returns role
--   advance_override_get       each note carries its role
--   advance_recommendation_finalise  amendment note "marked final by NAME (ROLE)" + actor_role
--
-- Written for the Supabase MCP tool: no DROP.
-- Rollback: migrations/rollback-advance-notes-role.sql
-- ============================================================

-- ── 1. Back up the five live bodies (once, and only unpatched ones) ──
insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'advance-notes-role', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('advance_override_save', 'advance_override_remove', 'advance_internal_note_add',
                     'advance_override_get', 'advance_recommendation_finalise')
   and p.prosrc not like '%_advance_actor_role%' and p.prosrc not like '%actor_role%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'advance-notes-role' and b.proname = p.proname);

do $$
begin
  if (select count(distinct proname) from kw_fn_backup where tag = 'advance-notes-role') <> 5 then
    raise exception 'expected backups of all five functions under advance-notes-role';
  end if;
end $$;

-- ── 2. Column and helper ─────────────────────────────────────
alter table public.advance_internal_notes
  add column if not exists actor_role text null
  check (actor_role in ('assigned advisor', 'team lead', 'admin', 'staff'));
comment on column public.advance_internal_notes.actor_role is
  'The capacity the author acted in for this client (14 Oct 2026): assigned advisor, team lead, admin. Null on rows written before then.';

create or replace function public._advance_actor_role(p_owner uuid)
returns text
language sql stable set search_path = public as $$
  select case
           when current_advisor_id() is not null and current_advisor_id() = p_owner then 'assigned advisor'
           when is_team_lead() then 'team lead'
           when is_admin() then 'admin'
           else 'staff'
         end;
$$;
revoke execute on function public._advance_actor_role(uuid) from public, anon, authenticated;

-- ── 3. Substitute on the live bodies ─────────────────────────
do $$
declare
  v_def text;
  v_new text;
  -- [function, from, to] triples; each "from" must occur exactly once.
  subs text[][] := array[
    -- save: the system note
    array['advance_override_save',
          'insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, body)',
          'insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, actor_role, body)'],
    array['advance_override_save',
          '''system'', null, v_email, v_name,',
          '''system'', null, v_email, v_name, _advance_actor_role(v_owner),'],
    array['advance_override_save',
          'Saved by %s.''',
          'Saved by %s (%s).'''],
    array['advance_override_save',
          'coalesce(v_name, v_email, ''an advisor'')));',
          'coalesce(v_name, v_email, ''an advisor''), _advance_actor_role(v_owner)));'],
    -- remove: the system note
    array['advance_override_remove',
          'insert into advance_internal_notes (client_id, override_id, kind, author_id, actor_email, actor_name, body)',
          'insert into advance_internal_notes (client_id, override_id, kind, author_id, actor_email, actor_name, actor_role, body)'],
    array['advance_override_remove',
          '''system'', null, v_email, v_name,',
          '''system'', null, v_email, v_name, _advance_actor_role(v_owner),'],
    array['advance_override_remove',
          'removed by %s.',
          'removed by %s (%s).'],
    array['advance_override_remove',
          'coalesce(v_name, v_email, ''an advisor''),',
          'coalesce(v_name, v_email, ''an advisor''), _advance_actor_role(v_owner),'],
    -- an advisor's own note
    array['advance_internal_note_add',
          'insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, body)',
          'insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, actor_role, body)'],
    array['advance_internal_note_add',
          'v_email, v_name, btrim(p_body))',
          'v_email, v_name, _advance_actor_role(v_owner), btrim(p_body))'],
    array['advance_internal_note_add',
          '''author'', coalesce(v_row.actor_name, v_row.actor_email));',
          '''author'', coalesce(v_row.actor_name, v_row.actor_email), ''role'', v_row.actor_role);'],
    -- the panel's history
    array['advance_override_get',
          '''author'', coalesce(n.actor_name, n.actor_email))',
          '''author'', coalesce(n.actor_name, n.actor_email), ''role'', n.actor_role)'],
    -- the amendment note written by finalise (Batch 2)
    array['advance_recommendation_finalise',
          'insert into advance_internal_notes (client_id, recommendation_id, kind, author_id, actor_email, actor_name, body)',
          'insert into advance_internal_notes (client_id, recommendation_id, kind, author_id, actor_email, actor_name, actor_role, body)'],
    array['advance_recommendation_finalise',
          '''system'', null, v_email, v_name,',
          '''system'', null, v_email, v_name, _advance_actor_role(v_owner),'],
    array['advance_recommendation_finalise',
          'marked final by %s.)''',
          'marked final by %s (%s).)'''],
    array['advance_recommendation_finalise',
          'v_version, v_amends_version, coalesce(v_name, v_email, ''an advisor'')));',
          'v_version, v_amends_version, coalesce(v_name, v_email, ''an advisor''), _advance_actor_role(v_owner)));']
  ];
  fn text;
  i int;
  n int;
begin
  foreach fn in array array['advance_override_save', 'advance_override_remove', 'advance_internal_note_add',
                            'advance_override_get', 'advance_recommendation_finalise'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = fn;
    if v_def is null then raise exception '% not found', fn; end if;
    if v_def like '%_advance_actor_role%' then raise exception '% is already patched', fn; end if;
    v_new := v_def;
    for i in 1 .. array_length(subs, 1) loop
      continue when subs[i][1] <> fn;
      n := (length(v_new) - length(replace(v_new, subs[i][2], ''))) / length(subs[i][2]);
      if n <> 1 then
        raise exception '%: expected exactly one occurrence of [%], found %', fn, subs[i][2], n;
      end if;
      v_new := replace(v_new, subs[i][2], subs[i][3]);
    end loop;
    execute v_new;
  end loop;
end $$;

-- ── 4. Assert the result ─────────────────────────────────────
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosrc like '%_advance_actor_role(v_owner)%'
         and p.proname in ('advance_override_save', 'advance_override_remove', 'advance_internal_note_add',
                           'advance_recommendation_finalise')) <> 4 then
    raise exception 'role not wired into all four writers';
  end if;
  if (select prosrc not like '%''role'', n.actor_role%' from pg_proc where proname = 'advance_override_get') then
    raise exception 'advance_override_get does not return the role';
  end if;
  -- ACLs survive CREATE OR REPLACE; check anyway.
  if has_function_privilege('anon', 'public.advance_override_save(uuid,uuid,numeric,text,jsonb)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.advance_override_save(uuid,uuid,numeric,text,jsonb)', 'EXECUTE') then
    raise exception 'advance_override_save grants changed';
  end if;
end $$;
