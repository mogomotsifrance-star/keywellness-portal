-- Full removal: supabase_advance_override.sql (13 Oct 2026)
-- ============================================================
-- SQL EDITOR ONLY (the MCP tool cannot run DROP). Run
-- rollback-advance-override.sql first, in the order it gives.
--
-- REFUSES while any override or internal note exists: those are the
-- permanent track record advisors were told cannot be deleted. Export and
-- get Tshenolo's written decision before removing that guard.
-- ============================================================
do $$
begin
  if exists (select 1 from public.advance_overrides) or exists (select 1 from public.advance_internal_notes) then
    raise exception 'advance overrides or internal notes exist; this cleanup will not delete the track record';
  end if;
end $$;

drop trigger if exists advance_override_finalise_guard on public.advance_recommendations;
drop function if exists public.advance_override_finalise_guard();
drop function if exists public.advance_override_get(uuid);
drop function if exists public.advance_override_save(uuid, uuid, numeric, text, jsonb);
drop function if exists public.advance_override_remove(uuid, text);
drop function if exists public.advance_internal_note_add(uuid, text, uuid);
drop function if exists public.advance_override_effective(uuid);
drop table if exists public.advance_override_allocations;
drop table if exists public.advance_internal_notes;
drop table if exists public.advance_overrides;
drop function if exists public.advance_overrides_guard();
drop function if exists public.advance_override_append_only();
drop function if exists public.kw_pf(text);
