-- ============================================================
-- ROLLBACK — Webinar Thumbnails (Batch 1)
-- Written BEFORE the forward migration, per project rule.
--
-- Forward file this reverses:
--   supabase_webinar_thumbnails.sql
--
-- Safe against a partially-applied or never-applied state
-- (drop column if exists). Dropping this column discards any stored
-- thumbnail URLs — harmless, since they are re-derivable from Vimeo
-- oEmbed or re-pastable via the admin edit modal.
-- ============================================================

alter table public.content_items
  drop column if exists thumbnail_url;
