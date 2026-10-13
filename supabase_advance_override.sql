-- ============================================================
-- Key Wealth / Key Wellness: advisor override of the advance (13 Oct 2026)
-- ============================================================
-- The portal computes a recommended advance (compute.ts, Edge Function
-- advance-recommendation). The advisor may set a different amount, say what
-- it is for (use of funds) and why (justification). The next report
-- generated for that client is computed on the advisor's amount.
--
-- Adds three tables, one pure helper, five RPCs and one trigger. Changes no
-- existing table, column, function or policy.
--
--   advance_overrides              one row per saved figure; never deleted.
--                                  At most one active per client.
--   advance_override_allocations   the use-of-funds lines of an override.
--                                  Liability lines carry a SNAPSHOT of lender
--                                  and outstanding balance (liabilities are
--                                  a jsonb array with no ids; see BUILD-NOTES).
--   advance_internal_notes         advisor-only, append-only track record.
--                                  Every save, change and removal writes a
--                                  system note.
--
-- Decisions (Tshenolo, 13 Oct 2026; brief D1-D12 as amended)
--   * The override belongs to the CLIENT (advisor_clients.id), not to a
--     report version. It carries across regenerations, and deleting a draft
--     report touches none of it. client_id is deliberately not a foreign
--     key: an advisor deleting a client record must not delete, and must not
--     be blocked by, the track record.
--   * Cap: advisor_amount <= 4 x gross monthly salary, read here from
--     advisor_clients.assessment -> income -> monthlySalary at save time and
--     snapshotted. No gross salary, no override (GROSS_SALARY_REQUIRED).
--     The CHECK constraints repeat the rule on the row itself.
--   * Use of funds must add up exactly to the amount. A liability line may
--     not exceed that liability's captured balance.
--   * Justification: at least 20 characters. It appears on the report.
--   * None of this is ever written into advisor_clients.assessment, which
--     a linked member can read (advisor_clients_member_read).
--   * Who: can_manage_advisor(client's advisor) = the assigned advisor, a
--     team lead, or an admin. Same test as every advance_recommendation_* RPC.
--     Members and HR: no policy, no access.
--   * A report may only be marked final if it was generated on the figure
--     that is active now (trigger advance_override_finalise_guard), so a
--     report on the portal figure cannot go to HR while an override stands,
--     nor the other way round.
--
-- Written for the Supabase MCP tool: no DROP anywhere.
-- Rollback: migrations/rollback-advance-override.sql (revokes the RPCs,
--           disables the finalise guard, keeps every row).
-- Removal:  migrations/cleanup-advance-override.sql (SQL editor only).
-- ============================================================

-- ── 0. Pure helper: parse a captured amount the way compute.ts pf() does ──
-- "P 44,782.61" -> 44782.61; blank or junk -> 0. No table access, so it is
-- left callable (same class as kw_dti_band); not SECURITY DEFINER.
create or replace function public.kw_pf(p text)
returns numeric
language plpgsql immutable set search_path = public as $$
declare v text := regexp_replace(coalesce(p, ''), '[,P\s]', '', 'g');
begin
  if v ~ '^-?[0-9]*\.?[0-9]+$' or v ~ '^-?[0-9]+\.?$' then return v::numeric; end if;
  -- parseFloat() reads a leading number and ignores the rest
  v := substring(v from '^-?[0-9]*\.?[0-9]+');
  return coalesce(v::numeric, 0);
exception when others then return 0;
end;
$$;

-- ── 1. Tables ────────────────────────────────────────────────
create table if not exists public.advance_overrides (
  id                            uuid        primary key default gen_random_uuid(),
  client_id                     uuid        not null,        -- advisor_clients.id (no FK, see header)
  source_recommendation_id      uuid        null,            -- the report on screen when it was saved
  system_amount                 numeric     null,            -- the portal's figure at that time (snapshot)
  gross_monthly_salary_snapshot numeric     not null check (gross_monthly_salary_snapshot > 0),
  cap_amount                    numeric     not null,
  advisor_amount                numeric     not null,
  justification                 text        not null,
  is_active                     boolean     not null default true,
  created_by                    uuid        not null,
  created_by_email              text        null,
  created_by_name               text        null,
  created_at                    timestamptz not null default now(),
  deactivated_by                uuid        null,
  deactivated_by_email          text        null,
  deactivated_at                timestamptz null,
  deactivation_reason           text        null,             -- 'replaced' or the advisor's removal reason
  constraint advance_overrides_cap_is_4x   check (cap_amount = round(gross_monthly_salary_snapshot * 4, 2)),
  constraint advance_overrides_amount      check (advisor_amount > 0 and advisor_amount <= cap_amount and advisor_amount = round(advisor_amount, 2)),
  constraint advance_overrides_justified   check (char_length(btrim(justification)) >= 20),
  constraint advance_overrides_deactivated check (is_active = (deactivated_at is null))
);
comment on table public.advance_overrides is
  'Advisor-set advance amounts (Advance Recommendation). One active per client; replaced or removed rows stay, inactive. Written only by advance_override_save/remove. Never in advisor_clients.assessment.';

create unique index if not exists advance_overrides_one_active
  on public.advance_overrides (client_id) where is_active;
create index if not exists advance_overrides_client_idx
  on public.advance_overrides (client_id, created_at desc);

create table if not exists public.advance_override_allocations (
  id                  uuid    primary key default gen_random_uuid(),
  override_id         uuid    not null references public.advance_overrides(id) on delete restrict,
  kind                text    not null check (kind in ('liability','other')),
  liability_index     int     null,       -- index into assessment.liabilities at save time
  lender              text    null,       -- snapshot
  outstanding_balance numeric null,       -- snapshot
  other_purpose       text    null,
  amount              numeric not null check (amount > 0 and amount = round(amount, 2)),
  sort_order          int     not null default 0,
  constraint advance_override_allocations_shape check (
    (kind = 'liability' and liability_index is not null and lender is not null and outstanding_balance > 0
       and other_purpose is null and amount <= outstanding_balance)
    or
    (kind = 'other' and liability_index is null and lender is null and outstanding_balance is null
       and char_length(btrim(other_purpose)) >= 3)
  )
);
create index if not exists advance_override_allocations_override_idx
  on public.advance_override_allocations (override_id, sort_order);

create table if not exists public.advance_internal_notes (
  id           uuid        primary key default gen_random_uuid(),
  client_id    uuid        not null,         -- advisor_clients.id (no FK, see header)
  override_id  uuid        null references public.advance_overrides(id) on delete restrict,
  recommendation_id uuid   null,             -- the report on screen, if any (no FK: drafts can be discarded)
  kind         text        not null check (kind in ('advisor','system')),
  author_id    uuid        null,             -- null for system notes
  actor_email  text        null,             -- who wrote it, or whose action caused a system note
  actor_name   text        null,
  body         text        not null check (char_length(btrim(body)) between 1 and 4000),
  created_at   timestamptz not null default now(),
  constraint advance_internal_notes_author check ((kind = 'system') = (author_id is null))
);
comment on table public.advance_internal_notes is
  'Advisor-only internal notes on a client''s advance. Append-only: no update or delete for anyone (no policy, no privilege, and a trigger). Never on the report, never visible to HR or the member.';
create index if not exists advance_internal_notes_client_idx
  on public.advance_internal_notes (client_id, created_at desc);

-- ── 2. RLS: advisors (caseload) and admins read; nobody writes directly ──
alter table public.advance_overrides            enable row level security;
alter table public.advance_override_allocations enable row level security;
alter table public.advance_internal_notes       enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='advance_overrides' and policyname='advance_overrides_read') then
    create policy advance_overrides_read on public.advance_overrides for select to authenticated using (
      exists (select 1 from advisor_clients ac where ac.id = advance_overrides.client_id and can_manage_advisor(ac.advisor_id)));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='advance_override_allocations' and policyname='advance_override_allocations_read') then
    create policy advance_override_allocations_read on public.advance_override_allocations for select to authenticated using (
      exists (select 1 from advance_overrides o join advisor_clients ac on ac.id = o.client_id
               where o.id = advance_override_allocations.override_id and can_manage_advisor(ac.advisor_id)));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='advance_internal_notes' and policyname='advance_internal_notes_read') then
    create policy advance_internal_notes_read on public.advance_internal_notes for select to authenticated using (
      exists (select 1 from advisor_clients ac where ac.id = advance_internal_notes.client_id and can_manage_advisor(ac.advisor_id)));
  end if;
end $$;

revoke all on public.advance_overrides, public.advance_override_allocations, public.advance_internal_notes from anon;
revoke insert, update, delete, truncate on public.advance_overrides, public.advance_override_allocations, public.advance_internal_notes from public, authenticated;
grant select on public.advance_overrides, public.advance_override_allocations, public.advance_internal_notes to authenticated;

-- ── 3. Append-only guards ────────────────────────────────────
-- Notes and allocations: never updated, never deleted.
create or replace function public.advance_override_append_only()
returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end;
$$;
revoke execute on function public.advance_override_append_only() from public, anon, authenticated;

create or replace trigger advance_internal_notes_append_only
  before update or delete on public.advance_internal_notes
  for each row execute function public.advance_override_append_only();
create or replace trigger advance_internal_notes_no_truncate
  before truncate on public.advance_internal_notes
  for each statement execute function public.advance_override_append_only();
create or replace trigger advance_override_allocations_append_only
  before update or delete on public.advance_override_allocations
  for each row execute function public.advance_override_append_only();
create or replace trigger advance_override_allocations_no_truncate
  before truncate on public.advance_override_allocations
  for each statement execute function public.advance_override_append_only();

-- Overrides: never deleted; the only permitted change is active -> inactive,
-- once, with nothing else on the row touched.
create or replace function public.advance_overrides_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'advance_overrides rows are never deleted' using errcode = '42501';
  end if;
  if not (old.is_active and not new.is_active
          and new.deactivated_at is not null and new.deactivated_by is not null
          and (new.id, new.client_id, new.source_recommendation_id, new.system_amount,
               new.gross_monthly_salary_snapshot, new.cap_amount, new.advisor_amount,
               new.justification, new.created_by, new.created_by_email, new.created_by_name, new.created_at)
              is not distinct from
              (old.id, old.client_id, old.source_recommendation_id, old.system_amount,
               old.gross_monthly_salary_snapshot, old.cap_amount, old.advisor_amount,
               old.justification, old.created_by, old.created_by_email, old.created_by_name, old.created_at)) then
    raise exception 'an advance override can only be deactivated, once; save a new one to change it' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.advance_overrides_guard() from public, anon, authenticated;

create or replace trigger advance_overrides_guard
  before update or delete on public.advance_overrides
  for each row execute function public.advance_overrides_guard();
create or replace trigger advance_overrides_no_truncate
  before truncate on public.advance_overrides
  for each statement execute function public.advance_override_append_only();

-- ── 4. RPCs ──────────────────────────────────────────────────
-- Format a pula amount for a note: 'P 22,000.00'.
-- Inline expression used below: 'P ' || to_char(x, 'FM999,999,999,990.00')

-- Everything the advisor panel needs, in one call.
create or replace function public.advance_override_get(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_owner  uuid;
  v_ass    jsonb;
  v_gross  numeric;
  v_active advance_overrides;
  v_out    jsonb;
begin
  select advisor_id, assessment into v_owner, v_ass from advisor_clients where id = p_client_id;
  if not found then raise exception 'client not found'; end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;

  v_gross := round(kw_pf(v_ass -> 'income' ->> 'monthlySalary'), 2);
  select * into v_active from advance_overrides where client_id = p_client_id and is_active;

  v_out := jsonb_build_object(
    'gross_monthly_salary', case when v_gross > 0 then v_gross end,
    'cap', case when v_gross > 0 then round(v_gross * 4, 2) end,
    'liabilities', coalesce((
      select jsonb_agg(jsonb_build_object(
               'liability_index', (l.ord - 1)::int,
               'lender', coalesce(nullif(btrim(l.r ->> 'institution'), ''), nullif(btrim(l.r ->> 'item'), ''), 'Liability'),
               'item', l.r ->> 'item',
               'balance', round(kw_pf(l.r ->> 'balance'), 2),
               'instalment', round(kw_pf(l.r ->> 'monthlyInstalment'), 2))
             order by l.ord)
        from jsonb_array_elements(case when jsonb_typeof(v_ass -> 'liabilities') = 'array' then v_ass -> 'liabilities' else '[]'::jsonb end)
             with ordinality as l(r, ord)
       where kw_pf(l.r ->> 'balance') > 0
    ), '[]'::jsonb),
    'active', case when v_active.id is null then null else
      to_jsonb(v_active) || jsonb_build_object('allocations', coalesce((
        select jsonb_agg(to_jsonb(a) order by a.sort_order) from advance_override_allocations a where a.override_id = v_active.id
      ), '[]'::jsonb)) end,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'advisor_amount', o.advisor_amount, 'system_amount', o.system_amount,
               'is_active', o.is_active, 'created_at', o.created_at, 'created_by_name', coalesce(o.created_by_name, o.created_by_email),
               'deactivated_at', o.deactivated_at, 'deactivation_reason', o.deactivation_reason) order by o.created_at desc)
        from advance_overrides o where o.client_id = p_client_id
    ), '[]'::jsonb),
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
               'author', coalesce(n.actor_name, n.actor_email)) order by n.created_at desc, n.id)
        from advance_internal_notes n where n.client_id = p_client_id
    ), '[]'::jsonb),
    'latest_final', (
      select jsonb_build_object('id', r.id, 'version', r.version, 'finalised_at', r.finalised_at)
        from advance_recommendations r where r.client_id = p_client_id and r.status = 'final'
       order by r.finalised_at desc nulls last limit 1)
  );
  return v_out;
end;
$$;
revoke execute on function public.advance_override_get(uuid) from public, anon;
grant execute on function public.advance_override_get(uuid) to authenticated;


-- Save (or change) the override. One transaction: retire the active one,
-- insert the new one and its lines, write the system note.
create or replace function public.advance_override_save(
  p_client_id                uuid,
  p_source_recommendation_id uuid,
  p_amount                   numeric,
  p_justification            text,
  p_allocations              jsonb
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text;
  v_name   text;
  v_owner  uuid;
  v_ass    jsonb;
  v_liabs  jsonb;
  v_gross  numeric;
  v_cap    numeric;
  v_system numeric;
  v_prev   advance_overrides;
  v_new    advance_overrides;
  v_line   jsonb;
  v_i      int := 0;
  v_sum    numeric := 0;
  v_kind   text;
  v_idx    int;
  v_amt    numeric;
  v_liab   jsonb;
  v_bal    numeric;
  v_lender text;
  v_purpose text;
  v_seen   int[] := '{}';
  v_old    numeric;
begin
  if v_uid is null then raise exception 'please sign in' using errcode = '42501'; end if;

  select advisor_id, assessment into v_owner, v_ass from advisor_clients where id = p_client_id;
  if not found then raise exception 'client not found'; end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('advance_override:' || p_client_id::text));

  -- The report on screen supplies the portal's figure for the track record.
  -- A report generated on an override carries the portal figure it replaced.
  if p_source_recommendation_id is null then
    raise exception 'open the Advance Recommendation report before setting an advance';
  end if;
  select coalesce((r.computed -> 'override' ->> 'system_amount')::numeric,
                  (r.computed -> 'advance' ->> 'amount')::numeric, 0)
    into v_system
    from advance_recommendations r where r.id = p_source_recommendation_id and r.client_id = p_client_id;
  if not found then raise exception 'that report does not belong to this client'; end if;

  -- D3: gross salary, read here, never from the caller.
  v_gross := round(kw_pf(v_ass -> 'income' ->> 'monthlySalary'), 2);
  if v_gross is null or v_gross <= 0 then
    raise exception 'GROSS_SALARY_REQUIRED: record the gross monthly salary on the Income tab before setting an advance';
  end if;
  v_cap := round(v_gross * 4, 2);

  if p_amount is null or p_amount <= 0 then raise exception 'the advance must be more than zero'; end if;
  if p_amount <> round(p_amount, 2) then raise exception 'the advance can have at most two decimals'; end if;
  if p_amount > v_cap then
    raise exception 'ABOVE_CAP: the advance cannot exceed P % (4 x gross monthly salary)', to_char(v_cap, 'FM999,999,999,990.00');
  end if;
  if p_justification is null or char_length(btrim(p_justification)) < 20 then
    raise exception 'the justification must be at least 20 characters';
  end if;
  if char_length(p_justification) > 2000 then raise exception 'the justification is limited to 2,000 characters'; end if;

  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'add at least one use-of-funds line';
  end if;
  if jsonb_array_length(p_allocations) > 30 then raise exception 'at most 30 use-of-funds lines'; end if;
  v_liabs := case when jsonb_typeof(v_ass -> 'liabilities') = 'array' then v_ass -> 'liabilities' else '[]'::jsonb end;

  -- Validate every line before writing anything.
  for v_line in select * from jsonb_array_elements(p_allocations) loop
    v_i := v_i + 1;
    v_kind := v_line ->> 'kind';
    begin v_amt := (v_line ->> 'amount')::numeric; exception when others then v_amt := null; end;
    if v_amt is null or v_amt <= 0 then raise exception 'use-of-funds line %: enter an amount above zero', v_i; end if;
    if v_amt <> round(v_amt, 2) then raise exception 'use-of-funds line %: at most two decimals', v_i; end if;
    if v_kind = 'liability' then
      begin v_idx := (v_line ->> 'liability_index')::int; exception when others then v_idx := null; end;
      if v_idx is null or v_idx < 0 or v_idx >= jsonb_array_length(v_liabs) then
        raise exception 'use-of-funds line %: that liability is no longer on the client''s record; reload and try again', v_i;
      end if;
      if v_idx = any(v_seen) then raise exception 'use-of-funds line %: that liability is already on another line', v_i; end if;
      v_seen := v_seen || v_idx;
      v_bal := round(kw_pf(v_liabs -> v_idx ->> 'balance'), 2);
      if v_bal <= 0 then
        raise exception 'use-of-funds line %: that liability has no outstanding balance captured; capture it on the Liabilities tab or use an Other line', v_i;
      end if;
      if v_amt > v_bal then
        raise exception 'use-of-funds line %: P % is more than the outstanding balance of P %', v_i,
          to_char(v_amt, 'FM999,999,999,990.00'), to_char(v_bal, 'FM999,999,999,990.00');
      end if;
    elsif v_kind = 'other' then
      v_purpose := btrim(coalesce(v_line ->> 'purpose', ''));
      if char_length(v_purpose) < 3 then raise exception 'use-of-funds line %: say what the money is for', v_i; end if;
      if char_length(v_purpose) > 200 then raise exception 'use-of-funds line %: the purpose is limited to 200 characters', v_i; end if;
    else
      raise exception 'use-of-funds line %: choose a liability or Other', v_i;
    end if;
    v_sum := v_sum + v_amt;
  end loop;
  if v_sum <> p_amount then
    raise exception 'the use-of-funds lines add up to P %, not the P % advance', to_char(v_sum, 'FM999,999,999,990.00'), to_char(p_amount, 'FM999,999,999,990.00');
  end if;

  select email into v_email from auth.users where id = v_uid;
  select full_name into v_name from advisors where id = current_advisor_id();

  -- Retire the current one (D9).
  select * into v_prev from advance_overrides where client_id = p_client_id and is_active for update;
  if v_prev.id is not null then
    update advance_overrides
       set is_active = false, deactivated_by = v_uid, deactivated_by_email = v_email,
           deactivated_at = now(), deactivation_reason = 'replaced'
     where id = v_prev.id;
  end if;

  insert into advance_overrides
    (client_id, source_recommendation_id, system_amount, gross_monthly_salary_snapshot, cap_amount,
     advisor_amount, justification, created_by, created_by_email, created_by_name)
  values
    (p_client_id, p_source_recommendation_id, v_system, v_gross, v_cap,
     p_amount, btrim(p_justification), v_uid, v_email, v_name)
  returning * into v_new;

  v_i := 0;
  for v_line in select * from jsonb_array_elements(p_allocations) loop
    v_i := v_i + 1;
    v_amt := (v_line ->> 'amount')::numeric;
    if v_line ->> 'kind' = 'liability' then
      v_idx := (v_line ->> 'liability_index')::int;
      v_liab := v_liabs -> v_idx;
      v_lender := coalesce(nullif(btrim(v_liab ->> 'institution'), ''), nullif(btrim(v_liab ->> 'item'), ''), 'Liability');
      insert into advance_override_allocations (override_id, kind, liability_index, lender, outstanding_balance, amount, sort_order)
      values (v_new.id, 'liability', v_idx, left(v_lender, 200), round(kw_pf(v_liab ->> 'balance'), 2), v_amt, v_i);
    else
      insert into advance_override_allocations (override_id, kind, other_purpose, amount, sort_order)
      values (v_new.id, 'other', btrim(v_line ->> 'purpose'), v_amt, v_i);
    end if;
  end loop;

  -- D7: the automatic note. "Old" is the previous advisor figure, else the portal's.
  v_old := coalesce(v_prev.advisor_amount, v_system);
  insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, body)
  values (p_client_id, v_new.id, p_source_recommendation_id, 'system', null, v_email, v_name,
          format('Advance changed from P %s%s to P %s. Cap P %s (4 x gross monthly salary of P %s). Saved by %s.',
                 to_char(v_old, 'FM999,999,999,990.00'),
                 case when v_prev.id is null then ' (portal calculation)' else ' (previous advisor figure)' end,
                 to_char(p_amount, 'FM999,999,999,990.00'),
                 to_char(v_cap, 'FM999,999,999,990.00'), to_char(v_gross, 'FM999,999,999,990.00'),
                 coalesce(v_name, v_email, 'an advisor')));

  return to_jsonb(v_new) || jsonb_build_object('allocations', (
    select jsonb_agg(to_jsonb(a) order by a.sort_order) from advance_override_allocations a where a.override_id = v_new.id));
end;
$$;
revoke execute on function public.advance_override_save(uuid, uuid, numeric, text, jsonb) from public, anon;
grant execute on function public.advance_override_save(uuid, uuid, numeric, text, jsonb) to authenticated;


-- Remove the override (D8). The row stays, inactive; the next report
-- generated uses the portal's figure.
create or replace function public.advance_override_remove(p_client_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_name  text;
  v_owner uuid;
  v_prev  advance_overrides;
begin
  if v_uid is null then raise exception 'please sign in' using errcode = '42501'; end if;
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if not found then raise exception 'client not found'; end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'give a short reason for removing the advance figure';
  end if;
  perform pg_advisory_xact_lock(hashtext('advance_override:' || p_client_id::text));

  select * into v_prev from advance_overrides where client_id = p_client_id and is_active for update;
  if v_prev.id is null then raise exception 'there is no advisor figure to remove'; end if;

  select email into v_email from auth.users where id = v_uid;
  select full_name into v_name from advisors where id = current_advisor_id();

  update advance_overrides
     set is_active = false, deactivated_by = v_uid, deactivated_by_email = v_email,
         deactivated_at = now(), deactivation_reason = left(btrim(p_reason), 500)
   where id = v_prev.id;

  insert into advance_internal_notes (client_id, override_id, kind, author_id, actor_email, actor_name, body)
  values (p_client_id, v_prev.id, 'system', null, v_email, v_name,
          format('Advisor figure of P %s removed by %s. The report reverts to the portal calculation%s. Reason: %s',
                 to_char(v_prev.advisor_amount, 'FM999,999,999,990.00'),
                 coalesce(v_name, v_email, 'an advisor'),
                 case when v_prev.system_amount is not null
                      then ' (P ' || to_char(v_prev.system_amount, 'FM999,999,999,990.00') || ' when the figure was set)' else '' end,
                 left(btrim(p_reason), 500)));
end;
$$;
revoke execute on function public.advance_override_remove(uuid, text) from public, anon;
grant execute on function public.advance_override_remove(uuid, text) to authenticated;


-- An advisor's own internal note.
create or replace function public.advance_internal_note_add(
  p_client_id uuid, p_body text, p_recommendation_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_owner uuid;
  v_email text;
  v_name  text;
  v_row   advance_internal_notes;
begin
  if v_uid is null then raise exception 'please sign in' using errcode = '42501'; end if;
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if not found then raise exception 'client not found'; end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;
  if p_body is null or char_length(btrim(p_body)) = 0 then raise exception 'the note is empty'; end if;
  if char_length(p_body) > 4000 then raise exception 'a note is limited to 4,000 characters'; end if;
  if p_recommendation_id is not null and not exists (
       select 1 from advance_recommendations where id = p_recommendation_id and client_id = p_client_id) then
    p_recommendation_id := null;
  end if;

  select email into v_email from auth.users where id = v_uid;
  select full_name into v_name from advisors where id = current_advisor_id();

  insert into advance_internal_notes (client_id, override_id, recommendation_id, kind, author_id, actor_email, actor_name, body)
  values (p_client_id, (select id from advance_overrides where client_id = p_client_id and is_active),
          p_recommendation_id, 'advisor', v_uid, v_email, v_name, btrim(p_body))
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'kind', v_row.kind, 'body', v_row.body,
                            'created_at', v_row.created_at, 'author', coalesce(v_row.actor_name, v_row.actor_email));
end;
$$;
revoke execute on function public.advance_internal_note_add(uuid, text, uuid) from public, anon;
grant execute on function public.advance_internal_note_add(uuid, text, uuid) to authenticated;


-- What the Edge Function feeds compute(): the active override, without the
-- internal notes and without who set it. Called AS THE ADVISOR.
create or replace function public.advance_override_effective(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_owner uuid;
  v_o     advance_overrides;
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if not found then raise exception 'client not found'; end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;
  select * into v_o from advance_overrides where client_id = p_client_id and is_active;
  if v_o.id is null then return null; end if;
  return jsonb_build_object(
    'id', v_o.id, 'amount', v_o.advisor_amount, 'justification', v_o.justification,
    'system_amount', v_o.system_amount, 'cap', v_o.cap_amount,
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object('kind', a.kind, 'liability_index', a.liability_index, 'lender', a.lender,
               'outstanding_balance', a.outstanding_balance, 'purpose', a.other_purpose, 'amount', a.amount) order by a.sort_order)
        from advance_override_allocations a where a.override_id = v_o.id), '[]'::jsonb));
end;
$$;
revoke execute on function public.advance_override_effective(uuid) from public, anon;
grant execute on function public.advance_override_effective(uuid) to authenticated;


-- ── 5. Finalise guard ────────────────────────────────────────
-- A report may become final only if it was generated on the figure that is
-- active now: the active override's id and amount, or no override at all.
-- Additive: a second BEFORE UPDATE trigger beside the consent trigger; the
-- finalise RPC itself is untouched.
create or replace function public.advance_override_finalise_guard()
returns trigger
language plpgsql set search_path = public as $$
declare
  v_o advance_overrides;
begin
  if new.status = 'final' and old.status is distinct from 'final' then
    select * into v_o from advance_overrides where client_id = new.client_id and is_active;
    if v_o.id is null then
      if new.computed ? 'override' then
        raise exception 'This report was generated on an advisor figure that has since been removed. Generate a new version before marking it final.';
      end if;
    elsif (new.computed -> 'override' ->> 'id') is distinct from v_o.id::text
       or (new.computed -> 'advance' ->> 'amount')::numeric is distinct from v_o.advisor_amount then
      raise exception 'This report was not generated on the advance figure set now (P %). Generate a new version before marking it final.',
        to_char(v_o.advisor_amount, 'FM999,999,999,990.00');
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.advance_override_finalise_guard() from public, anon, authenticated;

create or replace trigger advance_override_finalise_guard
  before update on public.advance_recommendations
  for each row execute function public.advance_override_finalise_guard();

-- ── 6. Verify (read-only) ────────────────────────────────────
-- select relname, relrowsecurity from pg_class where relname in ('advance_overrides','advance_override_allocations','advance_internal_notes');
-- select tablename, policyname, cmd from pg_policies where tablename like 'advance_over%' or tablename = 'advance_internal_notes';  -- 3 SELECT
-- select proname, has_function_privilege('anon', oid, 'EXECUTE') anon, has_function_privilege('authenticated', oid, 'EXECUTE') auth
--   from pg_proc where proname like 'advance_override_%' or proname = 'advance_internal_note_add';
