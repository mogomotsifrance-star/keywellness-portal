-- ============================================================
-- Key Wellness: advisor document access log (13 Oct 2026)
-- ============================================================
-- Adds ONE table and ONE RPC. Changes nothing that exists.
--
-- What this is for
--   The advisor portal's Documents tab gains View (PDF and images open in an
--   in-page viewer) beside Download. Every view and every download is
--   recorded here: who, which document, which client, when, which action.
--
-- THE LIMITATION (read this before relying on the log)
--   Documents are not in Supabase Storage. They are base64 data inside
--   advisor_clients.assessment -> 'documents', and the whole row reaches the
--   advisor's browser when the client list loads. The database therefore
--   cannot refuse a view: the bytes are already on the page. This log
--   records what the PAGE reports, through log_document_access(). The page
--   will not open or download a file unless that call succeeds, but a
--   person with the row in hand (dev tools, a JSON export) can read a file
--   without a log row. Moving documents to a private bucket ("F" in
--   BUILD-NOTES) is what makes the log binding.
--
-- Rules
--   * One write path: log_document_access(), SECURITY DEFINER, gated on
--     can_manage_advisor(client's advisor) = assigned advisor, team lead, admin.
--     A member or HR user gets 'not authorised'.
--   * No INSERT / UPDATE / DELETE policy for anyone. Table privileges for
--     anon and authenticated are revoked as well, and a trigger refuses
--     UPDATE, DELETE and TRUNCATE even for the table owner's sessions.
--   * No foreign keys. client_id is not a FK so an advisor deleting a client
--     record keeps the trail; actor_id is not a FK to auth.users so
--     admin_user_delete() has nothing new to classify. The actor's email is
--     kept beside the uuid, as support_actions does.
--
-- Written for the Supabase MCP tool: no DROP anywhere (it cannot run one).
-- Rollback: migrations/rollback-document-access-log.sql (revokes the RPC,
--           keeps the log). Full removal: migrations/cleanup-document-access-log.sql
--           (SQL editor only).
-- ============================================================

-- ── 1. Table ─────────────────────────────────────────────────
create table if not exists public.document_access_log (
  id               bigint      generated always as identity primary key,
  client_id        uuid        not null,          -- advisor_clients.id (no FK, see header)
  document_id      text        not null,          -- assessment.documents[].id
  document_name    text        not null,
  document_mime    text        null,
  action           text        not null check (action in ('view','download')),
  actor_id         uuid        not null,          -- auth.uid() (no FK, see header)
  actor_email      text        null,
  actor_advisor_id uuid        null,              -- current_advisor_id(), null for an admin with no advisors row
  created_at       timestamptz not null default now()
);

comment on table public.document_access_log is
  'Append-only record of advisor views and downloads of client documents (advisor portal Documents tab). Written only by log_document_access(). Page-reported: documents live in advisor_clients.assessment, so the database cannot refuse a read. See BUILD-NOTES 13 Oct 2026.';

create index if not exists document_access_log_client_idx
  on public.document_access_log (client_id, created_at desc);

alter table public.document_access_log enable row level security;

-- ── 2. RLS: read under the caseload test, nothing else ───────
do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'document_access_log'
                    and policyname = 'document_access_log_read') then
    create policy document_access_log_read on public.document_access_log
      for select to authenticated using (
        exists (select 1 from advisor_clients ac
                 where ac.id = document_access_log.client_id
                   and can_manage_advisor(ac.advisor_id))
      );
  end if;
end $$;

revoke insert, update, delete, truncate on public.document_access_log from public, anon, authenticated;
revoke all on public.document_access_log from anon;
grant select on public.document_access_log to authenticated;

-- ── 3. Append-only guard ─────────────────────────────────────
create or replace function public.document_access_log_immutable()
returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception 'document_access_log is append-only' using errcode = '42501';
end;
$$;
revoke execute on function public.document_access_log_immutable() from public, anon, authenticated;

create or replace trigger document_access_log_no_update_delete
  before update or delete on public.document_access_log
  for each row execute function public.document_access_log_immutable();
create or replace trigger document_access_log_no_truncate
  before truncate on public.document_access_log
  for each statement execute function public.document_access_log_immutable();

-- ── 4. The one write path ────────────────────────────────────
create or replace function public.log_document_access(
  p_client_id   uuid,
  p_document_id text,
  p_action      text
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_owner uuid;
  v_docs  jsonb;
  v_doc   jsonb;
begin
  if v_uid is null then
    raise exception 'please sign in' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('view','download') then
    raise exception 'action must be view or download';
  end if;

  select advisor_id, coalesce(assessment -> 'documents', '[]'::jsonb)
    into v_owner, v_docs
    from advisor_clients where id = p_client_id;
  if not found then
    raise exception 'client not found';
  end if;
  if v_owner is null or not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client' using errcode = '42501';
  end if;

  select d into v_doc
    from jsonb_array_elements(case when jsonb_typeof(v_docs) = 'array' then v_docs else '[]'::jsonb end) d
   where d ->> 'id' = p_document_id
   limit 1;
  if v_doc is null then
    raise exception 'document not found on that client';
  end if;

  insert into document_access_log
    (client_id, document_id, document_name, document_mime, action, actor_id, actor_email, actor_advisor_id)
  values
    (p_client_id, p_document_id, left(coalesce(v_doc ->> 'name', '(unnamed)'), 300),
     left(v_doc ->> 'mime', 200), p_action, v_uid,
     (select email from auth.users where id = v_uid), current_advisor_id());
end;
$$;
revoke execute on function public.log_document_access(uuid, text, text) from public, anon;
grant execute on function public.log_document_access(uuid, text, text) to authenticated;

-- ── 5. Verify (read-only) ────────────────────────────────────
-- select relrowsecurity from pg_class where oid = 'public.document_access_log'::regclass;  -- true
-- select has_function_privilege('anon','public.log_document_access(uuid,text,text)','EXECUTE');          -- false
-- select has_function_privilege('authenticated','public.log_document_access(uuid,text,text)','EXECUTE'); -- true
-- select has_table_privilege('authenticated','public.document_access_log','INSERT');                     -- false
-- select policyname, cmd from pg_policies where tablename = 'document_access_log';                       -- one SELECT
