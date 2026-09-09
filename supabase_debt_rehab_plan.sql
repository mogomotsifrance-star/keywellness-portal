-- ============================================================
-- Key Wellness — Debt Rehab Plan (advisor portal, INTERNAL ONLY)
-- ============================================================
-- Adds ONE table and six RPCs. Touches no existing table except to
-- insert timeline notes into advisor_notes (origin = 'system', which the
-- Aug-2026 advisor-ux migration already allows). Companion to
-- supabase_advance_recommendation.sql and built to the same shape.
--
-- What this is for
--   An advisor opens a client's Report tab, switches to "Debt Rehab Plan",
--   confirms the action on each debt (RETAIN / CONSOLIDATE / RENEGOTIATE)
--   and which assets may be treated as levers, and presses Generate. The
--   Edge Function `debt-rehab-plan` computes every figure, action, phase
--   band and review trigger deterministically, asks Claude for the prose
--   only, and calls debt_rehab_plan_create() AS THE SIGNED-IN ADVISOR to
--   store the input snapshot, the computed figures, the model's narrative
--   and the editable content.
--
-- INTERNAL-ONLY BY STRUCTURE — read this before touching the table
--   The Advance Recommendation is a document the employer sees. This one
--   never is: it is a working document for the Key Wellness advisor and
--   prints "CONFIDENTIAL — INTERNAL DEBT REHAB PLAN". So this table has
--   NO SELECT POLICY AT ALL. Every read goes through debt_rehab_plan_list()
--   which is gated on can_manage_advisor() — the
--   advisor who holds the client, any team lead, or an admin. There is no
--   member policy, no employer / HR policy, and no RPC an employer role can
--   reach. Do not add any of them; a `create policy` on this table is the
--   one line that would turn an internal document into an exported one.
--
-- Other rules carried over from the advisor portal
--   * No direct INSERT/UPDATE/DELETE. Every write is an RPC with the check
--     inside it. The check is written `if can_manage_advisor(x) IS DISTINCT
--     FROM true`, not `if not can_manage_advisor(x)`: for a caller with no
--     advisors row the function returns NULL, and `if not NULL` never raises.
--     See supabase_fix_can_manage_advisor_null.sql for the gate itself.
--   * A FINAL plan is immutable. To change one, generate a new version.
--   * No organisation gate. The Report tab offers the view when the client's
--     DSR band is strained/over-indebted or the latest Advance Recommendation
--     has Debt Rehab on; the database does not re-derive that, because the
--     document is internal and harmless to any client it is generated for.
--
-- Deploy order
--   1. supabase_advance_recommendation.sql (already live) — the Edge Function
--      reads the client's latest Advance Recommendation as context.
--   2. This file, in the Supabase SQL editor.
--   3. supabase functions deploy debt-rehab-plan (existing ANTHROPIC_API_KEY)
--   4. advisor.html
--
-- Rollback: migrations/rollback-debt-rehab-plan.sql
-- ============================================================

-- ── 1. Table ─────────────────────────────────────────────────
create table if not exists public.debt_rehab_plans (
  id               uuid        primary key default gen_random_uuid(),
  client_id        uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id       uuid        null references advisors(id) on delete set null,   -- who generated it
  created_by       uuid        null references auth.users(id) on delete set null,
  version          int         not null,
  status           text        not null default 'draft' check (status in ('draft','final')),
  -- Exactly what went in: the client-record subset, the advisor's confirmed
  -- actions and lever opt-outs, the Advance Recommendation context and the
  -- note excerpts. Enough to re-run computeRehab() byte-for-byte.
  input            jsonb       not null,
  -- Every figure, action, band, trigger and gap, from computeRehab(). Never edited.
  computed         jsonb       not null,
  -- What the model returned, verbatim. Never edited.
  narrative        jsonb       null,
  -- The plan as the advisor sees and edits it while status = draft.
  content          jsonb       not null,
  -- Checkable items (phase actions, lever opt-ins, review triggers), editable while draft.
  -- The Advance Recommendation calls this column `conditions`; same shape.
  actions          jsonb       not null default '[]'::jsonb,
  model            text        null,
  input_tokens     int         null,
  output_tokens    int         null,
  narrative_source text        not null default 'model' check (narrative_source in ('model','fallback')),
  generated_at     timestamptz not null default now(),
  updated_at       timestamptz null,
  finalised_at     timestamptz null,
  finalised_by     uuid        null references auth.users(id) on delete set null,
  unique (client_id, version)
);

comment on table public.debt_rehab_plans is
  'INTERNAL-ONLY Debt Rehab Plans generated from the advisor portal Report tab. No SELECT policy by design: reads go through debt_rehab_plan_list() under can_manage_advisor(). Never add a member, HR or employer read path. Every figure comes from computeRehab() in the Edge Function, never from the model.';

create index if not exists debt_rehab_plans_client_idx
  on public.debt_rehab_plans (client_id, version desc);
create index if not exists debt_rehab_plans_advisor_day_idx
  on public.debt_rehab_plans (advisor_id, generated_at);

alter table public.debt_rehab_plans enable row level security;
-- Deliberately no `create policy` here. See the header.

-- ── 2. RPCs ──────────────────────────────────────────────────

-- "May I generate one more today?" — 40 per advisor per Gaborone day on
-- this table, a separate pool from the Advance Recommendation's 40.
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
  v_advisor  uuid := current_advisor_id();
  v_owner    uuid;
  v_version  int;
  v_row      debt_rehab_plans;
  v_headline text := coalesce(p_computed->>'headline', 'plan generated');
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  if can_manage_advisor(v_owner) is distinct from true then raise exception 'not authorised for that client'; end if;
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

  -- Timeline entry. An admin with no advisors row generates without a note.
  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (p_client_id, v_advisor,
            format('Debt Rehab Plan v%s generated — %s.', v_version, v_headline),
            'system');
  end if;

  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.debt_rehab_plan_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) from public, anon;
grant execute on function public.debt_rehab_plan_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) to authenticated;


-- THE read path. Every version for one client, newest first. There is no
-- policy behind this: a caller who is not the client's advisor, a team
-- lead or an admin gets an exception, and a direct select gets zero rows.
create or replace function public.debt_rehab_plan_list(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_owner uuid;
  v_out   jsonb;
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  if can_manage_advisor(v_owner) is distinct from true then raise exception 'not authorised for that client'; end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.version desc), '[]'::jsonb) into v_out
    from (
      select id, client_id, version, status, generated_at, updated_at, finalised_at,
             model, narrative_source, content, actions, computed, input
        from debt_rehab_plans where client_id = p_client_id
    ) r;
  return v_out;
end;
$$;
revoke execute on function public.debt_rehab_plan_list(uuid) from public, anon;
grant execute on function public.debt_rehab_plan_list(uuid) to authenticated;


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
  if can_manage_advisor(v_owner) is distinct from true then raise exception 'not authorised for that client'; end if;
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
  if can_manage_advisor(v_owner) is distinct from true then raise exception 'not authorised for that client'; end if;
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


-- Delete a DRAFT. Finals cannot be deleted from the portal — audit trail.
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
  if can_manage_advisor(v_owner) is distinct from true then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then raise exception 'final plans cannot be discarded'; end if;
  delete from debt_rehab_plans where id = p_id;
end;
$$;
revoke execute on function public.debt_rehab_plan_discard(uuid) from public, anon;
grant execute on function public.debt_rehab_plan_discard(uuid) to authenticated;


-- ── 3. Verify ────────────────────────────────────────────────
-- select count(*) from debt_rehab_plans;                                   -- 0 on a fresh install
-- select debt_rehab_plan_can_generate();                                   -- true as an advisor
-- select proname from pg_proc where proname like 'debt_rehab_plan_%';      -- 6 rows
-- select policyname from pg_policies where tablename = 'debt_rehab_plans'; -- 0 rows, by design
