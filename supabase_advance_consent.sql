-- ============================================================
-- Advance Recommendation: a recorded consent form before finalise
-- Written 5 Oct 2026. Rollback: migrations/rollback-advance-consent.sql
--
-- WHY
--   A final Advance Recommendation goes to the employer's HR (Hollard), one
--   per employee: HR uses it to decide the advance with the employee. Each
--   employee signs a paper consent form before their first session. Until
--   now nothing recorded that form, and advance_recommendation_finalise()
--   would finalise without it.
--
-- WHAT
--   advance_consents          one row per signed form: client, the date the
--                             form was signed, who recorded it and when.
--                             Withdrawal columns are here for the full consent
--                             build (after HR Batch 1); nothing sets them yet.
--   advance_consent_record()  records a form. Only the client's assigned
--                             advisor or an admin. The signing date cannot be
--                             in the future (Botswana date). Refuses a second
--                             form while one is recorded and not yet used.
--   advance_recommendations.consent_id
--                             the form a final report relied on, stamped by
--                             finalise. One form finalises ONE report: the
--                             drafts of an application share it, and the next
--                             application needs a new form (partial unique
--                             index on consent_id where status = 'final').
--   advance_recommendation_finalise()
--                             unchanged except: refuses without an unused,
--                             unwithdrawn form for the client, and stamps it.
--   trigger kw_advance_final_needs_consent
--                             the same rule for ANY write that makes a row
--                             final (service role, a future code path), and a
--                             final report's consent_id cannot be changed.
--
-- WHAT DOES NOT CHANGE
--   Drafts: generate, edit, regenerate, discard, print. Who may finalise
--   (can_manage_advisor, as before). HR sees none of this table: its only
--   SELECT policy is can_manage_advisor() on the client's advisor.
--
-- DELIBERATE: recorded_by has no foreign key to auth.users. A new FK to
-- auth.users makes admin_user_delete() refuse every delete until the column is
-- classified in _admin_user_delete_plan() (CLAUDE.md). The row keeps
-- recorded_by_name / recorded_by_email, which is what a person reads; the uuid
-- may dangle after an account is deleted, like support_actions before its FK.
--
-- Idempotent: safe to run twice.
-- ============================================================

begin;

-- ── 0. The finalise body this replaces must be the expected one ──
do $$
declare v_src text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'advance_recommendation_finalise'
     and pg_get_function_identity_arguments(p.oid) = 'p_id uuid';
  if v_src is null then
    raise exception 'advance_recommendation_finalise(uuid) not found';
  end if;
  if v_src not like '%set status = ''final'', finalised_at = now(), finalised_by = auth.uid(), updated_at = now()%' then
    raise exception 'advance_recommendation_finalise is not the body this migration was written against; read it first';
  end if;
end $$;

-- ── 1. Capture the pre-change body (once) ────────────────────
insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'advance-consent-gate', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'advance_recommendation_finalise'
   and pg_get_function_identity_arguments(p.oid) = 'p_id uuid'
   and p.prosrc not like '%advance_consents%'          -- never back up the patched body
   and not exists (select 1 from kw_fn_backup b
                    where b.tag = 'advance-consent-gate' and b.proname = 'advance_recommendation_finalise');

do $$
begin
  if not exists (select 1 from kw_fn_backup where tag = 'advance-consent-gate'
                  and proname = 'advance_recommendation_finalise') then
    raise exception 'no backup of advance_recommendation_finalise under advance-consent-gate';
  end if;
end $$;

-- ── 2. The record ────────────────────────────────────────────
create table if not exists public.advance_consents (
  id                  uuid        primary key default gen_random_uuid(),
  client_id           uuid        not null references public.advisor_clients(id) on delete cascade,
  method              text        not null default 'paper_form' check (method in ('paper_form')),
  form_signed_on      date        not null,
  recorded_by         uuid        not null,     -- auth.uid(); no FK, see header
  recorded_by_name    text        not null,
  recorded_by_email   text        null,
  recorded_at         timestamptz not null default now(),
  withdrawn_at        timestamptz null,
  withdrawn_by        uuid        null,
  withdrawn_by_name   text        null
);
create index if not exists advance_consents_client_idx on public.advance_consents (client_id);

alter table public.advance_consents enable row level security;
drop policy if exists advance_consents_read on public.advance_consents;
create policy advance_consents_read on public.advance_consents for select
  using (exists (select 1 from public.advisor_clients ac
                  where ac.id = advance_consents.client_id and can_manage_advisor(ac.advisor_id)));

-- Writes only through the RPC. RLS already refuses them; the grants say so too.
revoke all on public.advance_consents from anon;
revoke insert, update, delete, truncate, references, trigger on public.advance_consents from authenticated;
grant select on public.advance_consents to authenticated;

alter table public.advance_recommendations
  add column if not exists consent_id uuid null references public.advance_consents(id) on delete restrict;
create unique index if not exists advance_recommendations_one_final_per_consent
  on public.advance_recommendations (consent_id) where status = 'final';

-- ── 3. Recording a form ──────────────────────────────────────
create or replace function public.advance_consent_record(p_client_id uuid, p_form_signed_on date)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_advisor uuid := current_advisor_id();
  v_name    text;
  v_id      uuid;
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  -- coalesce: with no advisor row, v_advisor = v_owner is NULL, and
  -- "if not (false or null)" does not raise. That would let anyone in.
  if not (is_admin() or coalesce(v_advisor = v_owner, false)) then
    raise exception 'only the client''s advisor or an admin can record a consent form';
  end if;
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_form_signed_on is null then raise exception 'enter the date the form was signed'; end if;
  if p_form_signed_on > (now() at time zone 'Africa/Gaborone')::date then
    raise exception 'the date the form was signed cannot be in the future';
  end if;
  if p_form_signed_on < date '2020-01-01' then
    raise exception 'check the date the form was signed';
  end if;
  if exists (select 1 from advance_consents c
              where c.client_id = p_client_id and c.withdrawn_at is null
                and not exists (select 1 from advance_recommendations r
                                 where r.consent_id = c.id and r.status = 'final')) then
    raise exception 'a signed consent form is already recorded for this application';
  end if;

  v_name := coalesce((select full_name from advisors where id = v_advisor),
                     nullif(auth.jwt() ->> 'email', ''), 'unknown');
  insert into advance_consents (client_id, form_signed_on, recorded_by, recorded_by_name, recorded_by_email)
  values (p_client_id, p_form_signed_on, auth.uid(), v_name, nullif(auth.jwt() ->> 'email', ''))
  returning id into v_id;

  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (p_client_id, v_advisor,
            format('Signed consent form on file (signed %s) recorded for the Advance Recommendation.',
                   to_char(p_form_signed_on, 'FMDD Mon YYYY')), 'system');
  end if;
  return v_id;
end;
$$;
revoke execute on function public.advance_consent_record(uuid, date) from public, anon;
grant  execute on function public.advance_consent_record(uuid, date) to authenticated;

-- ── 4. Finalise: the same body plus the consent check ────────
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
begin
  select ac.advisor_id, r.status, r.client_id, r.version into v_owner, v_status, v_client, v_version
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then return; end if;   -- idempotent

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
grant  execute on function public.advance_recommendation_finalise(uuid) to authenticated;

-- ── 5. The same rule for any write ───────────────────────────
create or replace function public.kw_advance_final_needs_consent()
returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'final' and (tg_op = 'INSERT' or old.status is distinct from 'final') then
    if new.consent_id is null or not exists (
         select 1 from advance_consents c
          where c.id = new.consent_id and c.client_id = new.client_id and c.withdrawn_at is null) then
      raise exception 'The employee''s signed consent form must be recorded before this report can be finalised.';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status = 'final' and new.consent_id is distinct from old.consent_id then
    raise exception 'the consent form a final report relied on cannot be changed';
  end if;
  return new;
end;
$$;
revoke execute on function public.kw_advance_final_needs_consent() from public, anon, authenticated;

drop trigger if exists advance_recommendations_final_needs_consent on public.advance_recommendations;
create trigger advance_recommendations_final_needs_consent
  before insert or update on public.advance_recommendations
  for each row execute function public.kw_advance_final_needs_consent();

-- ── 6. Assert ────────────────────────────────────────────────
do $$
begin
  if (select prosrc from pg_proc where proname = 'advance_recommendation_finalise') not like '%advance_consents%' then
    raise exception 'finalise was not replaced';
  end if;
  if has_function_privilege('anon', 'public.advance_consent_record(uuid,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.advance_recommendation_finalise(uuid)', 'EXECUTE') then
    raise exception 'an advance RPC is anon-callable';
  end if;
  if has_table_privilege('authenticated', 'public.advance_consents', 'INSERT')
     or has_table_privilege('authenticated', 'public.advance_consents', 'UPDATE')
     or has_table_privilege('authenticated', 'public.advance_consents', 'DELETE') then
    raise exception 'authenticated can write advance_consents directly';
  end if;
end $$;

commit;
