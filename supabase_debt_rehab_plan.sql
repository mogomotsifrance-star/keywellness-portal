-- ============================================================
-- Key Wellness — Debt Rehab Plan (advisor portal, INTERNAL)
-- ============================================================
--
-- WHAT THIS CHANGES
--   Adds one table (debt_rehab_plans) and five functions. It creates a third
--   view on the advisor portal's Report tab: a debt-by-debt, phase-by-phase
--   working plan the advisor regenerates every few months as the client's
--   position moves.
--
-- WHAT THIS DOES NOT CHANGE
--   No existing table, function, policy or grant is altered. The only write
--   to anything that already exists is a system note on the client's
--   timeline (advisor_notes, origin = 'system'), which the Aug-2026
--   advisor-ux migration already allows. advance_recommendations is read
--   only, and only by the Edge Function as the signed-in advisor.
--
-- THIS DOCUMENT IS INTERNAL BY STRUCTURE, NOT BY A FLAG
--   A Debt Rehab Plan names the client's debts, their assets, their spending
--   and the behaviour behind all three. It is written for a Key Wellness
--   advisor and for nobody else. That is enforced here, in the schema:
--
--     * ONE policy on the table: SELECT, under can_manage_advisor().
--     * NO member policy. The person the plan is about cannot read it, even
--       though they can see that an advisor holds a record on them.
--     * NO HR or employer policy, and no path by which one could be reached.
--       Nothing in this file consults organizations, employers or
--       hr_unit_scope, because no employer-facing question about this table
--       has an answer.
--     * NO INSERT, UPDATE or DELETE policy at all. Every write is an RPC
--       with the authorisation check inside it.
--
--   If a future migration adds a read path to this table for anyone other
--   than the advisor who holds the caseload, their team lead or an admin,
--   that migration is wrong. The plan carries a printed banner saying so:
--   "CONFIDENTIAL — INTERNAL DEBT REHAB PLAN (Key Wellness use only — not
--   for distribution to employer or employee)".
--
-- WHO MAY GENERATE ONE
--   Any advisor, for any client in their caseload. There is deliberately NO
--   offers_advances gate, unlike the Advance Recommendation: that document
--   names an employer's advance programme and a payroll deduction, so it
--   only applies where the employer runs one. This document names nothing
--   outside Key Wellness, and a client in trouble needs it whether or not
--   their employer has a programme.
--
-- WHAT BREAKS IF THIS IS WRONG
--   The failure that matters is a read path: if the policy below were
--   written with an OR that admitted a member or an employer, a client's
--   full debt position would become readable by their HR department. The
--   database tests prove all three denials separately (tests/rehab-db-tests.sql,
--   assertions "member cannot see", "an employer/HR user cannot see",
--   "another advisor cannot see"). Run them before applying this anywhere.
--
-- HOW TO UNDO IT
--   migrations/rollback-debt-rehab-plan.sql drops the table and all five
--   functions and leaves nothing behind but the timeline notes. Applied
--   twice it is still clean.
--
-- DEPLOY ORDER
--   1. This file.
--   2. supabase functions deploy advance-recommendation   (v3 — its imports
--      moved into _shared/kw-finance.ts in the same commit as this feature)
--   3. supabase functions deploy debt-rehab-plan
--      (needs the existing ANTHROPIC_API_KEY secret — the one Ask Key uses)
--   4. advisor.html
-- ============================================================

-- ── 1. Table ─────────────────────────────────────────────────
-- Mirrors advance_recommendations column for column, with one rename:
-- `conditions` is `actions` here, because what the advisor ticks on this
-- document is a list of things to do, not a list of terms to impose.
create table if not exists public.debt_rehab_plans (
  id             uuid        primary key default gen_random_uuid(),
  client_id      uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id     uuid        null references advisors(id) on delete set null,   -- who generated it
  created_by     uuid        null references auth.users(id) on delete set null,
  version        int         not null,
  status         text        not null default 'draft' check (status in ('draft','final')),
  -- Exactly what went in: the client-record subset, the advisor's confirmed
  -- actions, the Advance Recommendation cross-reference and the thresholds
  -- in force. Enough to re-run computeRehab() byte-for-byte.
  input          jsonb       not null,
  -- Every figure, action, phase band, trigger and gap, from computeRehab().
  -- Never edited. Two of these blobs diff themselves, which is what makes a
  -- later version comparison cheap.
  computed       jsonb       not null,
  -- What the model returned, verbatim, plus any error. Never edited.
  narrative      jsonb       null,
  -- The plan as the advisor sees and edits it. Starts as the generated text;
  -- in-place edits are saved here while status = 'draft'.
  content        jsonb       not null,
  -- The checkable action items — phase actions, levers, gaps, triggers.
  actions        jsonb       not null default '[]'::jsonb,
  model          text        null,
  input_tokens   int         null,
  output_tokens  int         null,
  narrative_source text      not null default 'model' check (narrative_source in ('model','fallback')),
  generated_at   timestamptz not null default now(),
  updated_at     timestamptz null,
  finalised_at   timestamptz null,
  finalised_by   uuid        null references auth.users(id) on delete set null,
  unique (client_id, version)
);

comment on table public.debt_rehab_plans is
  'INTERNAL Debt Rehab Plans generated from the advisor portal Report tab. One row per generated version; drafts are editable through RPCs, finals are immutable. Every figure and every per-debt action comes from computeRehab() in the Edge Function, never from the model. Internal by structure: the only read path is the SELECT policy under can_manage_advisor() — there is no member, HR or employer policy and none may be added. This document is not for distribution to an employer or to the client.';

create index if not exists debt_rehab_plans_client_idx
  on public.debt_rehab_plans (client_id, version desc);
create index if not exists debt_rehab_plans_advisor_day_idx
  on public.debt_rehab_plans (advisor_id, generated_at);

alter table public.debt_rehab_plans enable row level security;

-- ── 2. RLS — one policy, read only, no direct writes ─────────
-- The advisor who holds the caseload, their team lead, or an admin. The same
-- test that already keeps members out of advance_recommendations.
drop policy if exists debt_rehab_plans_read on public.debt_rehab_plans;
create policy debt_rehab_plans_read on public.debt_rehab_plans
  for select using (
    exists (
      select 1 from advisor_clients ac
      where ac.id = debt_rehab_plans.client_id
        and can_manage_advisor(ac.advisor_id)
    )
  );

-- ── 3. RPCs ──────────────────────────────────────────────────

-- "May I generate one more today?" — checked by the Edge Function BEFORE it
-- spends a model call. Its own counter, not shared with the Advance
-- Recommendation: 40 of each per advisor per Gaborone day, far above any real
-- caseload and low enough to stop a runaway loop.
create or replace function public.debt_rehab_plan_can_generate()
returns boolean
language sql security definer stable set search_path = public as $$
  select current_advisor_id() is not null
     and (
       select count(*) from debt_rehab_plans
       where advisor_id = current_advisor_id()
         and generated_at >= (date_trunc('day', now() at time zone 'Africa/Gaborone') at time zone 'Africa/Gaborone')
     ) < 40;
$$;
revoke execute on function public.debt_rehab_plan_can_generate() from public, anon;
grant execute on function public.debt_rehab_plan_can_generate() to authenticated;


-- Store a freshly generated plan. Called by the Edge Function with the
-- advisor's own JWT, so current_advisor_id() and can_manage_advisor() are
-- evaluated against the real caller.
--
-- Note what is NOT here: no organisation lookup, no offers_advances check.
-- This document applies to any client the caller may manage.
create or replace function public.debt_rehab_plan_create(
  p_client_id uuid,
  p_input     jsonb,
  p_computed  jsonb,
  p_narrative jsonb,
  p_content   jsonb,
  p_actions   jsonb,
  p_model     text,
  p_input_tokens  int,
  p_output_tokens int,
  p_narrative_source text default 'model'
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_advisor   uuid := current_advisor_id();
  v_owner     uuid;
  v_version   int;
  v_row       debt_rehab_plans;
  v_headline  text := coalesce(p_computed->>'headline', '?');
  v_counts    jsonb := coalesce(p_computed->'counts', '{}'::jsonb);
  v_shortfall text := p_computed->'budget'->>'shortfall';
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  if not coalesce(can_manage_advisor(v_owner), false) then raise exception 'not authorised for that client'; end if;
  if p_input is null or p_computed is null or p_content is null then raise exception 'incomplete payload'; end if;

  select coalesce(max(version), 0) + 1 into v_version
    from debt_rehab_plans where client_id = p_client_id;

  insert into debt_rehab_plans
    (client_id, advisor_id, created_by, version, input, computed, narrative, content, actions,
     model, input_tokens, output_tokens, narrative_source)
  values
    (p_client_id, v_advisor, auth.uid(), v_version, p_input, p_computed, p_narrative, p_content,
     coalesce(p_actions, '[]'::jsonb), p_model, p_input_tokens, p_output_tokens,
     coalesce(p_narrative_source, 'model'))
  returning * into v_row;

  -- Timeline entry, so the generation shows up in the client's notes trail.
  -- An admin with no advisors row generates without a note rather than failing.
  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (p_client_id, v_advisor,
            format('Debt Rehab Plan v%s generated — %s; retain %s, consolidate %s, renegotiate %s%s.',
                   v_version, v_headline,
                   coalesce(v_counts->>'retain', '0'),
                   coalesce(v_counts->>'consolidate', '0'),
                   coalesce(v_counts->>'renegotiate', '0'),
                   case when v_shortfall is not null and v_shortfall <> 'null' and (v_shortfall)::numeric > 0
                        then format('; shortfall P %s', v_shortfall) else '' end),
            'system');
  end if;

  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.debt_rehab_plan_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) from public, anon;
grant execute on function public.debt_rehab_plan_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) to authenticated;


-- Save the advisor's in-place edits. Drafts only.
create or replace function public.debt_rehab_plan_update(
  p_id uuid, p_content jsonb, p_actions jsonb
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_status text;
begin
  select ac.advisor_id, r.status into v_owner, v_status
    from debt_rehab_plans r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'plan not found'; end if;
  if not coalesce(can_manage_advisor(v_owner), false) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then raise exception 'plan is final — generate a new version to change it'; end if;

  update debt_rehab_plans
     set content    = coalesce(p_content, content),
         actions    = coalesce(p_actions, actions),
         updated_at = now()
   where id = p_id;
end;
$$;
revoke execute on function public.debt_rehab_plan_update(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.debt_rehab_plan_update(uuid, jsonb, jsonb) to authenticated;


-- Lock a draft. After this nothing on the row changes again.
create or replace function public.debt_rehab_plan_finalise(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_status  text;
  v_client  uuid;
  v_version int;
  v_advisor uuid := current_advisor_id();
begin
  select ac.advisor_id, r.status, r.client_id, r.version into v_owner, v_status, v_client, v_version
    from debt_rehab_plans r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'plan not found'; end if;
  if not coalesce(can_manage_advisor(v_owner), false) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then return; end if;   -- idempotent

  update debt_rehab_plans
     set status = 'final', finalised_at = now(), finalised_by = auth.uid(), updated_at = now()
   where id = p_id;

  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (v_client, v_advisor, format('Debt Rehab Plan v%s marked final.', v_version), 'system');
  end if;
end;
$$;
revoke execute on function public.debt_rehab_plan_finalise(uuid) from public, anon;
grant execute on function public.debt_rehab_plan_finalise(uuid) to authenticated;


-- Delete a DRAFT the advisor does not want to keep. Finals cannot be deleted
-- from the portal at all — that is the audit trail.
create or replace function public.debt_rehab_plan_discard(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_status text;
begin
  select ac.advisor_id, r.status into v_owner, v_status
    from debt_rehab_plans r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'plan not found'; end if;
  if not coalesce(can_manage_advisor(v_owner), false) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then raise exception 'final plans cannot be discarded'; end if;
  delete from debt_rehab_plans where id = p_id;
end;
$$;
revoke execute on function public.debt_rehab_plan_discard(uuid) from public, anon;
grant execute on function public.debt_rehab_plan_discard(uuid) to authenticated;


-- ── 4. Verify ────────────────────────────────────────────────
-- select count(*) from debt_rehab_plans;                          -- 0 on a fresh install
-- select debt_rehab_plan_can_generate();                          -- true as an advisor
-- select proname from pg_proc where proname like 'debt_rehab_plan_%';  -- 4 rows + can_generate = 5
-- select policyname, cmd from pg_policies where tablename = 'debt_rehab_plans';
--   -- exactly one row: debt_rehab_plans_read | SELECT. More than one is a finding.
