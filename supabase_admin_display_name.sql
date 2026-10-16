-- ============================================================
-- Key Wellness: admins get a display name for internal notes (16 Oct 2026)
-- ============================================================
-- Internal notes name the author from advisors.full_name. An admin with no
-- advisors row had no name anywhere, so notes read
-- "removed by lone@keywellness.co.bw (admin)". Decision (Tshenolo, 16 Oct
-- 2026): give admins a display name, so the note reads "Lone Male (admin)".
--
-- ADDS: admins.full_name (nullable) and sets it for Lone Male.
-- CHANGES the four note writers by asserted substitution on the live bodies
-- (backed up under kw_fn_backup tag 'admin-display-name'): after the existing
-- advisors.full_name lookup, fall back to admins.full_name for the same email.
--   advance_override_save, advance_override_remove,
--   advance_internal_note_add, advance_recommendation_finalise
-- An advisor's own name still wins; an admin with no name still shows by email.
--
-- admins stays SELECT-only under RLS (admins_read: own row). This migration
-- writes one name as the owner; there is no page to edit names yet.
-- MCP-safe (no DROP).
-- Rollback: migrations/rollback-admin-display-name.sql
-- ============================================================

alter table public.admins
  add column if not exists full_name text null
  check (full_name is null or char_length(btrim(full_name)) between 1 and 120);
comment on column public.admins.full_name is
  'Display name for internal notes when the admin has no advisors row (16 Oct 2026).';

do $$
declare n int;
begin
  update public.admins set full_name = 'Lone Male'
   where lower(email) = 'lone@keywellness.co.bw' and full_name is distinct from 'Lone Male';
  get diagnostics n = row_count;
  if not exists (select 1 from public.admins where lower(email) = 'lone@keywellness.co.bw' and full_name = 'Lone Male') then
    raise exception 'Lone''s admins row not found or not named';
  end if;
end $$;

insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'admin-display-name', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('advance_override_save', 'advance_override_remove', 'advance_internal_note_add', 'advance_recommendation_finalise')
   and p.prosrc not like '%from admins where lower(email) = lower(v_email)%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'admin-display-name' and b.proname = p.proname);

do $$
declare
  v_def text; fn text; n int; v_from text; v_to text;
  v_fallback text := 'if v_name is null then select full_name into v_name from admins where lower(email) = lower(v_email); end if;';
begin
  if (select count(distinct proname) from kw_fn_backup where tag = 'admin-display-name') <> 4 then
    raise exception 'expected backups of the four note writers under admin-display-name';
  end if;
  foreach fn in array array['advance_override_save', 'advance_override_remove', 'advance_internal_note_add', 'advance_recommendation_finalise'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = fn;
    if v_def like '%from admins where lower(email) = lower(v_email)%' then raise exception '% is already patched', fn; end if;
    if fn = 'advance_recommendation_finalise' then
      v_from := E'    select full_name into v_name from advisors where id = v_advisor;\n';
      v_to   := v_from || '    ' || v_fallback || E'\n';
    else
      v_from := E'  select full_name into v_name from advisors where id = current_advisor_id();\n';
      v_to   := v_from || '  ' || v_fallback || E'\n';
    end if;
    n := (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from);
    if n <> 1 then raise exception '%: expected the name lookup once, found %', fn, n; end if;
    execute replace(v_def, v_from, v_to);
  end loop;
end $$;

do $$
begin
  if (select count(*) from pg_proc where proname in ('advance_override_save', 'advance_override_remove', 'advance_internal_note_add', 'advance_recommendation_finalise')
        and prosrc like '%from admins where lower(email) = lower(v_email)%') <> 4 then
    raise exception 'fallback not in all four writers';
  end if;
  if has_function_privilege('anon', 'public.advance_override_save(uuid,uuid,numeric,text,jsonb)', 'EXECUTE') then
    raise exception 'grants changed';
  end if;
end $$;
