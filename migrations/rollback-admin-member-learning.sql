-- Rollback: supabase_admin_member_learning.sql (28 Oct 2026)
-- Written BEFORE the change was applied. MCP-safe (no DROP).
-- Restores complete_video, record_video_progress and submit_quiz from
-- kw_fn_backup tag 'admin-member-learning' (every admin blocked from Learn
-- again). Completions, progress and quiz attempts recorded in the meantime are
-- kept.
do $$
declare r record; v_n int := 0;
begin
  for r in select distinct on (b.proname) b.definition from kw_fn_backup b
            where b.tag = 'admin-member-learning'
              and b.proname in ('complete_video', 'record_video_progress', 'submit_quiz')
            order by b.proname, b.taken_at asc, b.id asc
  loop
    execute r.definition; v_n := v_n + 1;
  end loop;
  if v_n <> 3 then raise exception 'expected 3 backups under admin-member-learning, found %', v_n; end if;
end $$;
-- Verify: select proname, prosrc like '%if is_admin() then%' from pg_proc
--          where proname in ('complete_video','record_video_progress','submit_quiz');  -- all true
