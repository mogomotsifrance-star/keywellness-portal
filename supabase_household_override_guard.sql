-- ============================================================
-- Key Wellness: a loan only the spouse is liable for cannot be settled
-- with the client's advance (23 Nov 2026)
-- ============================================================
-- advance_override_get() offers every liability with a balance as a
-- use-of-funds line and advance_override_save() accepts any of them. Both
-- learn assessment.liabilities[].liable. Absent means the client, so nothing
-- changes for a record that has never set it.
--
-- Method: substitution on the LIVE body, asserted (exactly one occurrence),
-- after backing it up under kw_fn_backup tag 'household-override-guard'.
-- No DROP. Safe to run twice.
-- Rollback: migrations/rollback-household-override-guard.sql
-- ============================================================
begin;

insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'household-override-guard', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('advance_override_get','advance_override_save')
   and p.prosrc not like '%''liable''%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'household-override-guard' and b.proname = p.proname);

do $$
declare
  v_def text;
  v_from text;
  v_to text;
  n int;
begin
  if (select count(*) from kw_fn_backup where tag = 'household-override-guard') <> 2 then
    raise exception 'expected two bodies in kw_fn_backup under household-override-guard';
  end if;

  select pg_get_functiondef(p.oid) into strict v_def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'advance_override_get';
  if v_def not like '%''liable''%' then
    v_from := 'where kw_pf(l.r ->> ''balance'') > 0';
    v_to   := v_from || ' and coalesce(l.r ->> ''liable'', ''client'') <> ''spouse''';
    n := (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from);
    if n <> 1 then raise exception 'advance_override_get: expected the balance filter once, found %', n; end if;
    execute replace(v_def, v_from, v_to);
  end if;

  select pg_get_functiondef(p.oid) into strict v_def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'advance_override_save';
  if v_def not like '%''liable''%' then
    v_from := 'v_seen := v_seen || v_idx;';
    v_to   := v_from || E'\n      if coalesce(v_liabs -> v_idx ->> ''liable'', ''client'') = ''spouse'' then\n'
           || E'        raise exception ''use-of-funds line %: the client is not liable for that loan'', v_i;\n      end if;';
    n := (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from);
    if n <> 1 then raise exception 'advance_override_save: expected the seen-list line once, found %', n; end if;
    execute replace(v_def, v_from, v_to);
  end if;

  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname in ('advance_override_get','advance_override_save')
         and p.prosrc like '%''liable''%') <> 2 then
    raise exception 'the guard is not in both functions';
  end if;
end $$;

commit;
