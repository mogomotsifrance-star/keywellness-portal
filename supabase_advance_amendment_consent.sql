-- ============================================================
-- Key Wellness: no new consent form when a report is amended (Batch 2, 14 Oct 2026)
-- ============================================================
-- Decision (Tshenolo, 13 Oct 2026): an amended report for the same
-- application does not need a new consent form. The original consent covers
-- sharing an advance recommendation with HR; changing the amount does not
-- change what the member agreed to. A genuinely new application still needs
-- its own form. The guard that blocks finalising a report whose figures do not
-- match the active advisor figure stays.
--
-- WHY THIS SHAPE
--   There is no application id. Since 5 Oct, one consent form backs exactly one
--   final report: partial unique index advance_recommendations_one_final_per_consent
--   on (consent_id) where status = 'final'. An amended final therefore cannot
--   reuse consent_id. Instead it records amends_id = the final it amends, leaves
--   consent_id null, and the consent check follows amends_id back to the form.
--   The index, the "one form, one application" rule and every existing final
--   are untouched.
--
-- WHAT COUNTS AS AN AMENDMENT (_advance_amendment_of; all four, checked here):
--   1. the client's latest final report F rests on a consent form that is
--      recorded and not withdrawn (directly, or through F's own amends chain);
--   2. the draft was generated after F was marked final;
--   3. the draft has the same consultation date as F (input.prep.
--      consultation_date). Regenerating from a report carries its date forward;
--      a new consultation date is a new application and needs its own form;
--   4. the advisor figure changed after F was marked final (an override saved
--      or removed after F.finalised_at): the amount is what changed.
--   Anything else needs a recorded form, exactly as before.
--
-- CHANGES TWO EXISTING FUNCTION BODIES (backed up first, kw_fn_backup tag
-- 'advance-amendment-consent'; the rollback restores from there):
--   advance_recommendation_finalise(uuid)   amendment path added, tried FIRST so
--                                           an amendment never consumes a fresh
--                                           form meant for the next application
--   kw_advance_final_needs_consent()        accepts amends_id instead of consent_id
--                                           when the row qualifies; amends_id of
--                                           a final cannot change
-- ADDS: column amends_id, two private helpers, one gated read RPC.
--
-- Written for the Supabase MCP tool: no DROP.
-- Rollback: migrations/rollback-advance-amendment-consent.sql
-- ============================================================

-- ── 0. The two bodies this replaces must be the expected ones ──
do $$
declare v_fin text; v_trg text;
begin
  select p.prosrc into v_fin from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'advance_recommendation_finalise'
     and pg_get_function_identity_arguments(p.oid) = 'p_id uuid';
  select p.prosrc into v_trg from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'kw_advance_final_needs_consent';
  if v_fin is null or v_trg is null then raise exception 'finalise or consent trigger function not found'; end if;
  if v_fin not like '%One form finalises one report.%' or v_fin like '%amends_id%' then
    raise exception 'advance_recommendation_finalise is not the 5 Oct consent body; read it first';
  end if;
  if v_trg not like '%the consent form a final report relied on cannot be changed%' or v_trg like '%amends_id%' then
    raise exception 'kw_advance_final_needs_consent is not the 5 Oct body; read it first';
  end if;
end $$;

-- ── 1. Back up both bodies (once) ────────────────────────────
insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'advance-amendment-consent', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('advance_recommendation_finalise', 'kw_advance_final_needs_consent')
   and p.prosrc not like '%amends_id%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'advance-amendment-consent' and b.proname = p.proname);

do $$
begin
  if (select count(distinct proname) from kw_fn_backup where tag = 'advance-amendment-consent') <> 2 then
    raise exception 'expected backups of both functions under advance-amendment-consent';
  end if;
end $$;

-- ── 2. Column ────────────────────────────────────────────────
alter table public.advance_recommendations
  add column if not exists amends_id uuid null references public.advance_recommendations(id) on delete restrict;
comment on column public.advance_recommendations.amends_id is
  'Set when this report was finalised as an amendment of an earlier final for the same application (14 Oct 2026). Its consent is that report''s consent; consent_id stays null.';

-- ── 3. Private helpers (no data returned to callers; revoked) ──
-- The consent form a report rests on: its own, or, for an amendment, the one
-- the amended report rests on. Null if none.
create or replace function public._advance_report_consent(p_report uuid)
returns uuid
language plpgsql stable set search_path = public as $$
declare v_id uuid := p_report; v_consent uuid; v_amends uuid; v_hops int := 0;
begin
  loop
    select consent_id, amends_id into v_consent, v_amends from advance_recommendations where id = v_id;
    if not found then return null; end if;
    if v_consent is not null then return v_consent; end if;
    if v_amends is null then return null; end if;
    v_id := v_amends; v_hops := v_hops + 1;
    if v_hops > 50 then return null; end if;
  end loop;
end;
$$;
revoke execute on function public._advance_report_consent(uuid) from public, anon, authenticated;

-- The final report this draft amends, or null (the four rules in the header).
create or replace function public._advance_amendment_of(p_draft uuid)
returns uuid
language plpgsql stable set search_path = public as $$
declare d advance_recommendations; f advance_recommendations; v_consent uuid;
begin
  select * into d from advance_recommendations where id = p_draft;
  if not found or d.status <> 'draft' then return null; end if;
  select * into f from advance_recommendations
   where client_id = d.client_id and status = 'final' and id <> d.id
   order by finalised_at desc nulls last, version desc limit 1;
  if not found then return null; end if;
  -- 1. F's form recorded and not withdrawn
  v_consent := _advance_report_consent(f.id);
  if v_consent is null or not exists (select 1 from advance_consents c
       where c.id = v_consent and c.client_id = d.client_id and c.withdrawn_at is null) then
    return null;
  end if;
  -- 2. generated after F was marked final
  if f.finalised_at is null or d.generated_at <= f.finalised_at then return null; end if;
  -- 3. same consultation date (same application)
  if nullif(d.input -> 'prep' ->> 'consultation_date', '') is null
     or (d.input -> 'prep' ->> 'consultation_date') is distinct from (f.input -> 'prep' ->> 'consultation_date') then
    return null;
  end if;
  -- 4. the advisor figure changed after F was marked final
  if not exists (select 1 from advance_overrides o where o.client_id = d.client_id
                   and (o.created_at > f.finalised_at or o.deactivated_at > f.finalised_at)) then
    return null;
  end if;
  return f.id;
end;
$$;
revoke execute on function public._advance_amendment_of(uuid) from public, anon, authenticated;

-- ── 4. Finalise: amendment path first, then the recorded-form path ──
create or replace function public.advance_recommendation_finalise(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_status  text;
  v_client  uuid;
  v_version int;
  v_advisor uuid := current_advisor_id();
  v_consent uuid;
  v_amends  uuid;
  v_amends_version int;
  v_recorded_at timestamptz;
  v_email   text;
  v_name    text;
begin
  select ac.advisor_id, r.status, r.client_id, r.version into v_owner, v_status, v_client, v_version
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then return; end if;   -- idempotent

  -- 14 Oct 2026: an amendment of the same application finalises on the form
  -- its original rests on. Tried first, so it never uses up a fresh form.
  v_amends := _advance_amendment_of(p_id);
  if v_amends is not null then
    select version into v_amends_version from advance_recommendations where id = v_amends;
    select recorded_at into v_recorded_at from advance_consents where id = _advance_report_consent(v_amends);
    update advance_recommendations
       set status = 'final', finalised_at = now(), finalised_by = auth.uid(), updated_at = now(),
           amends_id = v_amends
     where id = p_id;
    select email into v_email from auth.users where id = auth.uid();
    select full_name into v_name from advisors where id = v_advisor;
    insert into advance_internal_notes (client_id, recommendation_id, kind, author_id, actor_email, actor_name, body)
    values (v_client, p_id, 'system', null, v_email, v_name,
            format('Report amended after consent recorded on %s. Existing consent applied. (v%s amends final v%s; marked final by %s.)',
                   to_char(v_recorded_at at time zone 'Africa/Gaborone', 'FMDD Mon YYYY'),
                   v_version, v_amends_version, coalesce(v_name, v_email, 'an advisor')));
    if v_advisor is not null then
      insert into advisor_notes (client_id, advisor_id, body, origin)
      values (v_client, v_advisor, format('Advance Recommendation v%s marked final (amends v%s; existing consent applied).', v_version, v_amends_version), 'system');
    end if;
    return;
  end if;

  -- 5 Oct 2026: a final report goes to the employer's HR, so the employee's
  -- signed consent form must be on record. One form finalises one report.
  select c.id into v_consent
    from advance_consents c
   where c.client_id = v_client and c.withdrawn_at is null
     and not exists (select 1 from advance_recommendations r2
                      where r2.consent_id = c.id and r2.status = 'final')
   order by c.recorded_at desc
   limit 1;
  if v_consent is null then
    raise exception 'The employee''s signed consent form must be recorded before this report can be finalised.';
  end if;

  update advance_recommendations
     set status = 'final', finalised_at = now(), finalised_by = auth.uid(), updated_at = now(),
         consent_id = v_consent
   where id = p_id;

  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (v_client, v_advisor, format('Advance Recommendation v%s marked final.', v_version), 'system');
  end if;
end;
$$;
revoke execute on function public.advance_recommendation_finalise(uuid) from public, anon;
grant execute on function public.advance_recommendation_finalise(uuid) to authenticated;

-- ── 5. The trigger: the same rule for any write that makes a report final ──
create or replace function public.kw_advance_final_needs_consent()
returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'final' and (tg_op = 'INSERT' or old.status is distinct from 'final') then
    if new.consent_id is not null then
      if new.amends_id is not null or not exists (
           select 1 from advance_consents c
            where c.id = new.consent_id and c.client_id = new.client_id and c.withdrawn_at is null) then
        raise exception 'The employee''s signed consent form must be recorded before this report can be finalised.';
      end if;
    else
      -- 14 Oct 2026: an amendment rests on the form of the report it amends.
      if tg_op = 'INSERT' or new.amends_id is null
         or new.amends_id is distinct from _advance_amendment_of(new.id) then
        raise exception 'The employee''s signed consent form must be recorded before this report can be finalised.';
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status = 'final' and new.consent_id is distinct from old.consent_id then
    raise exception 'the consent form a final report relied on cannot be changed';
  end if;
  if tg_op = 'UPDATE' and old.status = 'final' and new.amends_id is distinct from old.amends_id then
    raise exception 'the report a final amendment relied on cannot be changed';
  end if;
  return new;
end;
$$;

-- ── 6. What the page shows before Mark final (read-only, gated) ──
create or replace function public.advance_finalise_basis(p_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_owner uuid; v_client uuid; v_status text; v_amends uuid; v_cons uuid;
  f advance_recommendations; k advance_consents;
begin
  select ac.advisor_id, r.client_id, r.status into v_owner, v_client, v_status
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client' using errcode = '42501'; end if;
  if v_status <> 'draft' then
    v_cons := _advance_report_consent(p_id);
    select * into k from advance_consents where id = v_cons;
    select * into f from advance_recommendations where id = (select amends_id from advance_recommendations where id = p_id);
    return jsonb_build_object('mode', case when f.id is not null then 'amendment' when k.id is not null then 'consent' else 'none' end,
      'amends', case when f.id is null then null else jsonb_build_object('version', f.version, 'finalised_at', f.finalised_at) end,
      'consent', case when k.id is null then null else jsonb_build_object('form_signed_on', k.form_signed_on, 'recorded_at', k.recorded_at, 'recorded_by_name', k.recorded_by_name) end);
  end if;
  v_amends := _advance_amendment_of(p_id);
  if v_amends is not null then
    select * into f from advance_recommendations where id = v_amends;
    select * into k from advance_consents where id = _advance_report_consent(v_amends);
    return jsonb_build_object('mode', 'amendment',
      'amends', jsonb_build_object('version', f.version, 'finalised_at', f.finalised_at),
      'consent', jsonb_build_object('form_signed_on', k.form_signed_on, 'recorded_at', k.recorded_at, 'recorded_by_name', k.recorded_by_name));
  end if;
  select c.* into k from advance_consents c
   where c.client_id = v_client and c.withdrawn_at is null
     and not exists (select 1 from advance_recommendations r2 where r2.consent_id = c.id and r2.status = 'final')
   order by c.recorded_at desc limit 1;
  if k.id is not null then
    return jsonb_build_object('mode', 'consent', 'amends', null,
      'consent', jsonb_build_object('form_signed_on', k.form_signed_on, 'recorded_at', k.recorded_at, 'recorded_by_name', k.recorded_by_name));
  end if;
  return jsonb_build_object('mode', 'none', 'amends', null, 'consent', null);
end;
$$;
revoke execute on function public.advance_finalise_basis(uuid) from public, anon;
grant execute on function public.advance_finalise_basis(uuid) to authenticated;

-- ── 7. Verify (read-only) ────────────────────────────────────
-- select proname from kw_fn_backup where tag = 'advance-amendment-consent';          -- 2 rows
-- select has_function_privilege('authenticated','public._advance_amendment_of(uuid)','EXECUTE');  -- false
-- select has_function_privilege('anon','public.advance_finalise_basis(uuid)','EXECUTE');          -- false
