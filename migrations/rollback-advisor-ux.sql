-- ============================================================
-- ROLLBACK — Advisor Portal UX pass
-- Reverses supabase_advisor_ux.sql.
--
-- ⚠ The note migration is NOT automatically reversed. Notes moved out of
--   advisor_clients.assessment into advisor_notes stay in advisor_notes.
--   They are not lost — but the Notes tab in an older advisor.html reads
--   the assessment array, so it would show nothing until you either
--   redeploy the newer HTML or move them back with the block at the
--   bottom of this file.
-- ============================================================

drop function if exists advisor_note_counts(text, uuid);
drop function if exists advisor_mark_response_seen(uuid);
drop function if exists advisor_pending_responses();
drop function if exists advisor_reassign_client(uuid, uuid, text);
drop function if exists advisor_note_delete(uuid);
drop function if exists advisor_note_update(uuid, text);
drop function if exists advisor_note_add(uuid, text);
drop function if exists advisor_client_notes(uuid);

-- The origin column is kept: dropping it loses the record of which notes
-- were migrated and which were written in the portal.
-- alter table advisor_notes drop column if exists origin;


-- ── Optional: move migrated notes back into the assessment blob ──
-- Only needed if you are also rolling the HTML back to a version whose
-- Notes tab reads advisor_clients.assessment->'consultationNotes'.
--
-- do $$
-- declare r record;
-- begin
--   for r in
--     select client_id,
--            jsonb_agg(jsonb_build_object(
--              'id', 'id_' || id::text,
--              'text', body,
--              'createdAt', created_at,
--              'updatedAt', updated_at) order by created_at) as arr
--     from advisor_notes
--     where origin in ('migrated','advisor')
--     group by client_id
--   loop
--     update advisor_clients
--        set assessment = jsonb_set(assessment, '{consultationNotes}', r.arr)
--      where id = r.client_id;
--   end loop;
--   delete from advisor_notes where origin in ('migrated','advisor');
-- end $$;
