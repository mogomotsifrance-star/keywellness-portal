-- ============================================================
-- ROLLBACK — supabase_dsr_bands_batch1.sql (DSR bands, Batch 1)
--
-- Removes the indicator.dsr configuration row. Safe on its own only while
-- nothing reads it: once Batch 2 has pointed kw_dti_band() and the pages at
-- indicator.dsr, roll Batch 2 back FIRST (migrations/rollback-dsr-bands-batch2.sql),
-- or kw_dti_band() returns null for everyone and every band disappears.
--
-- indicator.dti is not touched by Batch 1, so there is nothing to restore.
-- ============================================================

delete from threshold_config where key = 'indicator.dsr';

-- Verify: expect 0
select count(*) from threshold_config where key = 'indicator.dsr';
