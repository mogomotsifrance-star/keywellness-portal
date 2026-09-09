-- Key Wellness — member invites: did it land? Plain SQL, read-only.
-- Paste into the Supabase SQL editor after supabase_member_invites.sql.
select 'member_invites table'      as check_, exists (select 1 from pg_tables where schemaname='public' and tablename='member_invites') as pass
union all select 'RLS on member_invites',   (select relrowsecurity from pg_class where oid='public.member_invites'::regclass)
union all select 'exactly one policy',      (select count(*)=1 from pg_policies where tablename='member_invites')
union all select 'invite_stage()',          exists (select 1 from pg_proc where proname='invite_stage')
union all select 'invite_to_send()',        exists (select 1 from pg_proc where proname='invite_to_send')
union all select 'invite_mark()',           exists (select 1 from pg_proc where proname='invite_mark')
union all select 'invite_list()',           exists (select 1 from pg_proc where proname='invite_list')
union all select 'send_invite in audit check', exists (select 1 from pg_constraint where conname='support_actions_action_check' and pg_get_constraintdef(oid) like '%send_invite%')
union all select 'handle_new_user reads invites', (pg_get_functiondef('public.handle_new_user'::regproc) like '%member_invites%')
union all select 'support_can excludes invites', (pg_get_functiondef('public.support_can'::regproc) like '%send_invite%');
