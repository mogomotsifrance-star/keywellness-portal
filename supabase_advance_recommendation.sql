-- ============================================================
-- Key Wellness — Advance Recommendation Report (advisor portal)
-- ============================================================
-- Adds ONE table and five RPCs. Touches no existing table except to
-- insert timeline notes into advisor_notes (origin = 'system', which the
-- Aug-2026 advisor-ux migration already allows).
--
-- What this is for
--   An advisor opens a client's Report tab, confirms which debts are
--   formal vs informal/high-cost, and presses "Generate Advance
--   Recommendation". The Edge Function `advance-recommendation` computes
--   every figure deterministically, asks Claude for the prose only, and
--   calls advance_recommendation_create() AS THE SIGNED-IN ADVISOR to
--   store the whole thing: the input snapshot, the computed figures, the
--   model's narrative, and the editable content. Hollard can later be
--   shown exactly which numbers produced which recommendation.
--
-- Rules carried over from the rest of the advisor portal
--   * Authorisation is can_manage_advisor(owner): the advisor who holds the
--     client, any team lead, or an admin. Same test as advisor_note_add().
--   * No direct INSERT/UPDATE/DELETE policies. Every write is an RPC with
--     the check inside it. SELECT is allowed under the same test so the
--     portal can list versions with a plain query.
--   * A FINAL report is immutable. To change one, generate a new version.
--   * Members never see these rows (no member policy), even though they
--     can see that an advisor holds a record on them.
--
-- Deploy order
--   1. This file, in the Supabase SQL editor.
--   2. supabase functions deploy advance-recommendation
--      (needs the existing ANTHROPIC_API_KEY secret — same one Ask Key uses)
--   3. advisor.html
--
-- Rollback: migrations/rollback-advance-recommendation.sql
-- ============================================================

-- ── 1. Table ─────────────────────────────────────────────────
create table if not exists public.advance_recommendations (
  id             uuid        primary key default gen_random_uuid(),
  client_id      uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id     uuid        null references advisors(id) on delete set null,   -- who generated it
  created_by     uuid        null references auth.users(id) on delete set null,
  version        int         not null,
  status         text        not null default 'draft' check (status in ('draft','final')),
  -- Exactly what went in: the client-record subset + the advisor's
  -- confirmed classification. Enough to re-run compute() byte-for-byte.
  input          jsonb       not null,
  -- Every figure, the tier and the decision, from compute(). Never edited.
  computed       jsonb       not null,
  -- What the model returned, verbatim. Never edited.
  narrative      jsonb       null,
  -- The report as the advisor sees and edits it. Starts as the generated
  -- text; the advisor's in-place edits are saved here while status = draft.
  content        jsonb       not null,
  -- Operating-condition and checklist toggles, also editable while draft.
  conditions     jsonb       not null default '[]'::jsonb,
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

comment on table public.advance_recommendations is
  'Advance Recommendation Reports generated from the advisor portal Report tab. One row per generated version; drafts are editable through RPCs, finals are immutable. Every figure comes from compute() in the Edge Function, never from the model.';

create index if not exists advance_recommendations_client_idx
  on public.advance_recommendations (client_id, version desc);
create index if not exists advance_recommendations_advisor_day_idx
  on public.advance_recommendations (advisor_id, generated_at);

alter table public.advance_recommendations enable row level security;

-- ── 2. RLS — read under the caseload test, no direct writes ──
drop policy if exists advance_recommendations_read on public.advance_recommendations;
create policy advance_recommendations_read on public.advance_recommendations
  for select using (
    exists (
      select 1 from advisor_clients ac
      where ac.id = advance_recommendations.client_id
        and can_manage_advisor(ac.advisor_id)
    )
  );

-- ── 3. RPCs ──────────────────────────────────────────────────

-- "May I generate one more today?" — checked by the Edge Function BEFORE
-- it spends a model call. 40 per advisor per Gaborone day is far above
-- any real caseload and low enough to stop a runaway loop.
create or replace function public.advance_recommendation_can_generate()
returns boolean
language sql security definer stable set search_path = public as $$
  select current_advisor_id() is not null
     and (
       select count(*) from advance_recommendations
       where advisor_id = current_advisor_id()
         and generated_at >= (date_trunc('day', now() at time zone 'Africa/Gaborone') at time zone 'Africa/Gaborone')
     ) < 40;
$$;
revoke execute on function public.advance_recommendation_can_generate() from public, anon;
grant execute on function public.advance_recommendation_can_generate() to authenticated;


-- Store a freshly generated report. Called by the Edge Function with the
-- advisor's own JWT, so current_advisor_id() and can_manage_advisor() are
-- evaluated against the real caller.
create or replace function public.advance_recommendation_create(
  p_client_id uuid,
  p_input     jsonb,
  p_computed  jsonb,
  p_narrative jsonb,
  p_content   jsonb,
  p_conditions jsonb,
  p_model     text,
  p_input_tokens  int,
  p_output_tokens int,
  p_narrative_source text default 'model'
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_owner   uuid;
  v_version int;
  v_row     advance_recommendations;
  v_tier    text := coalesce(p_computed->>'tier', '?');
  v_amount  text := coalesce(p_computed->'advance'->>'amount', null);
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if p_input is null or p_computed is null or p_content is null then raise exception 'incomplete payload'; end if;

  select coalesce(max(version), 0) + 1 into v_version
    from advance_recommendations where client_id = p_client_id;

  insert into advance_recommendations
    (client_id, advisor_id, created_by, version, input, computed, narrative, content, conditions,
     model, input_tokens, output_tokens, narrative_source)
  values
    (p_client_id, v_advisor, auth.uid(), v_version, p_input, p_computed, p_narrative, p_content,
     coalesce(p_conditions, '[]'::jsonb), p_model, p_input_tokens, p_output_tokens,
     coalesce(p_narrative_source, 'model'))
  returning * into v_row;

  -- Timeline entry, so the generation shows up in the client's notes trail.
  -- An admin with no advisors row generates without a note rather than failing.
  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (p_client_id, v_advisor,
            format('Advance Recommendation v%s generated — %s%s.',
                   v_version, v_tier,
                   case when v_amount is not null then format(', P %s over %s months', v_amount, p_computed->>'term_months') else ', no advance' end),
            'system');
  end if;

  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.advance_recommendation_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) from public, anon;
grant execute on function public.advance_recommendation_create(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text, int, int, text) to authenticated;


-- Save the advisor's in-place edits. Drafts only.
create or replace function public.advance_recommendation_update(
  p_id uuid, p_content jsonb, p_conditions jsonb
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_status text;
begin
  select ac.advisor_id, r.status into v_owner, v_status
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then raise exception 'report is final — generate a new version to change it'; end if;

  update advance_recommendations
     set content    = coalesce(p_content, content),
         conditions = coalesce(p_conditions, conditions),
         updated_at = now()
   where id = p_id;
end;
$$;
revoke execute on function public.advance_recommendation_update(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.advance_recommendation_update(uuid, jsonb, jsonb) to authenticated;


-- Lock a draft. After this nothing on the row changes again.
create or replace function public.advance_recommendation_finalise(p_id uuid)
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
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then return; end if;   -- idempotent

  update advance_recommendations
     set status = 'final', finalised_at = now(), finalised_by = auth.uid(), updated_at = now()
   where id = p_id;

  if v_advisor is not null then
    insert into advisor_notes (client_id, advisor_id, body, origin)
    values (v_client, v_advisor, format('Advance Recommendation v%s marked final.', v_version), 'system');
  end if;
end;
$$;
revoke execute on function public.advance_recommendation_finalise(uuid) from public, anon;
grant execute on function public.advance_recommendation_finalise(uuid) to authenticated;


-- Delete a DRAFT the advisor does not want to keep. Finals cannot be
-- deleted from the portal at all — that is the audit trail.
create or replace function public.advance_recommendation_discard(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_status text;
begin
  select ac.advisor_id, r.status into v_owner, v_status
    from advance_recommendations r join advisor_clients ac on ac.id = r.client_id
   where r.id = p_id;
  if v_owner is null then raise exception 'report not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;
  if v_status <> 'draft' then raise exception 'final reports cannot be discarded'; end if;
  delete from advance_recommendations where id = p_id;
end;
$$;
revoke execute on function public.advance_recommendation_discard(uuid) from public, anon;
grant execute on function public.advance_recommendation_discard(uuid) to authenticated;


-- ── 4. Verify ────────────────────────────────────────────────
-- select count(*) from advance_recommendations;                       -- 0 on a fresh install
-- select advance_recommendation_can_generate();                       -- true as an advisor
-- select proname from pg_proc where proname like 'advance_recommendation_%'; -- 5 rows
