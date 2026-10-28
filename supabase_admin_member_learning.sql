-- ============================================================
-- Key Wellness: admins who are also members can complete Learn (28 Oct 2026)
-- ============================================================
-- Bug: an admin who also uses the member portal could not finish the welcome
-- video or any pathway lesson. complete_video() and submit_quiz() raised
-- "admin accounts cannot ..." for every is_admin() caller, and
-- record_video_progress() recorded nothing for them. The guard was written for
-- admin PREVIEW sessions (an admin looking at the Learn tab, not a member), but
-- roles are table membership: france@keywealth.co.bw holds member + admin, and
-- every one of the four admins has a profiles row, three of them onboarded.
--
-- Rule now: the preview guard applies only to an admin WITHOUT an onboarded
-- member profile. An onboarded profile is what "member" means everywhere else
-- in the portal (route() sends anyone not onboarded to the wizard), so an admin
-- who has finished onboarding learns, completes and earns exactly like any
-- other member. An admin who has not cannot reach Learn anyway.
--
-- Method: substitution on the LIVE bodies, asserted (exactly one occurrence
-- each), after backing them up under kw_fn_backup tag 'admin-member-learning'.
-- MCP-safe (no DROP).
-- Rollback: migrations/rollback-admin-member-learning.sql
-- ============================================================

insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'admin-member-learning', p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('complete_video', 'record_video_progress', 'submit_quiz')
   and p.prosrc like '%if is_admin() then%'
   and not exists (select 1 from kw_fn_backup b where b.tag = 'admin-member-learning' and b.proname = p.proname);

do $$
declare
  v_fn   text;
  v_def  text;
  v_from text := 'if is_admin() then';
  v_to   text := 'if is_admin() and not exists (select 1 from profiles where id = auth.uid() and onboarded) then';
  n int;
begin
  foreach v_fn in array array['complete_video', 'record_video_progress', 'submit_quiz'] loop
    if not exists (select 1 from kw_fn_backup where tag = 'admin-member-learning' and proname = v_fn) then
      raise exception 'no backup of % under admin-member-learning', v_fn;
    end if;
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = v_fn;
    n := (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from);
    if n <> 1 then raise exception '%: expected the admin guard once, found %', v_fn, n; end if;
    -- CREATE OR REPLACE keeps the existing ACL (granted to authenticated).
    execute replace(v_def, v_from, v_to);
  end loop;
end $$;

do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('complete_video', 'record_video_progress', 'submit_quiz')
         and p.prosrc like '%if is_admin() and not exists (select 1 from profiles where id = auth.uid() and onboarded) then%') <> 3 then
    raise exception 'admin guard not narrowed in all three functions';
  end if;
end $$;
