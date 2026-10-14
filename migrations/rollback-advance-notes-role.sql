-- Rollback: supabase_advance_notes_role.sql (14 Oct 2026)
-- ============================================================
-- Written BEFORE the migration was applied. MCP-safe (no DROP).
--
-- Restores the five bodies from kw_fn_backup tag 'advance-notes-role'
-- (advance_override_save, advance_override_remove, advance_internal_note_add,
-- advance_override_get, advance_recommendation_finalise), as they were just
-- before the role was added. Notes written in between keep their actor_role
-- and their "(role)" text: notes are append-only, by design.
--
-- KEPT: the actor_role column (nullable) and _advance_actor_role (revoked from
-- everyone). Revert the advisor.html commit for Batch 3 too (it only shows the
-- role when one is returned, so it is harmless if left).
-- ============================================================
do $$
declare r record; v_n int := 0;
begin
  for r in
    select distinct on (b.proname) b.definition
      from kw_fn_backup b
     where b.tag = 'advance-notes-role'
     order by b.proname, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
  end loop;
  if v_n <> 5 then
    raise exception 'expected 5 backed-up bodies under advance-notes-role, found %', v_n;
  end if;
end $$;

-- Verify:
-- select proname from pg_proc where prosrc like '%_advance_actor_role%';   -- none
