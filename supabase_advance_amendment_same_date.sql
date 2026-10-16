-- ============================================================
-- Key Wellness: any new version for the same consultation reuses the consent (16 Oct 2026)
-- ============================================================
-- Decision (Tshenolo, 16 Oct 2026), revising Batch 2 of 14 Oct: drop the
-- "advisor figure changed after the last final" condition. An amendment is
-- any new version with the same consultation date as the client's last final
-- report, where that report's consent is on record and not withdrawn.
-- Wording-only amendments therefore reuse the existing consent too, and get
-- the same automatic internal note (written by advance_recommendation_finalise,
-- unchanged). A new consultation date still needs its own form. The
-- stale-figure guard (advance_override_finalise_guard) is untouched.
--
-- _advance_amendment_of keeps three rules:
--   1. the last final's consent is recorded and not withdrawn
--   2. the draft was generated after that final
--   3. same consultation date
-- and loses rule 4 (an override saved or removed after that final).
--
-- Method: substitution on the LIVE body, asserted (exactly one occurrence),
-- after backing it up under kw_fn_backup tag 'advance-amendment-same-date'.
-- MCP-safe (no DROP).
-- Rollback: migrations/rollback-advance-amendment-same-date.sql
-- ============================================================

insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'advance-amendment-same-date', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = '_advance_amendment_of'
   and p.prosrc like '%from advance_overrides o%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'advance-amendment-same-date' and b.proname = '_advance_amendment_of');

do $$
declare
  v_def text;
  v_from text := E'  if not exists (select 1 from advance_overrides o where o.client_id = d.client_id\n'
              || E'                   and (o.created_at > f.finalised_at or o.deactivated_at > f.finalised_at)) then\n'
              || E'    return null;\n'
              || E'  end if;\n';
  v_to   text := E'  -- 16 Oct 2026: no longer requires the advisor figure to have changed;\n'
              || E'  -- any new version for the same consultation reuses the consent.\n';
  n int;
begin
  if not exists (select 1 from kw_fn_backup where tag = 'advance-amendment-same-date' and proname = '_advance_amendment_of') then
    raise exception 'no backup of _advance_amendment_of under advance-amendment-same-date';
  end if;
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_advance_amendment_of';
  n := (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from);
  if n <> 1 then raise exception '_advance_amendment_of: expected the rule-4 block once, found %', n; end if;
  execute replace(v_def, v_from, v_to);
  -- CREATE OR REPLACE keeps the ACL; restate the revoke anyway.
  revoke execute on function public._advance_amendment_of(uuid) from public, anon, authenticated;
end $$;

do $$
begin
  if (select prosrc like '%advance_overrides%' from pg_proc where proname = '_advance_amendment_of') then
    raise exception 'rule 4 still present';
  end if;
  if (select prosrc not like '%consultation_date%' or prosrc not like '%withdrawn_at is null%' or prosrc not like '%d.generated_at <= f.finalised_at%'
        from pg_proc where proname = '_advance_amendment_of') then
    raise exception 'one of rules 1 to 3 went missing';
  end if;
end $$;
