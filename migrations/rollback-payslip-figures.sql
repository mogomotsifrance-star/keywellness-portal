-- ============================================================
-- ROLLBACK — supabase_payslip_figures.sql (Phase C)
--
-- Drops the six columns the payslip block writes.
--
-- ══ THIS DESTROYS MEMBER DATA ══════════════════════════════
--
-- These are figures members typed off their own payslips. Unlike the B1
-- rollback, nothing recomputes them — there is no other source. Check what you
-- are about to delete before running this:
--
--   select count(*) filter (where payslip_paye            is not null) as paye,
--          count(*) filter (where payslip_pension         is not null) as pension,
--          count(*) filter (where payslip_medical         is not null) as medical,
--          count(*) filter (where payslip_loan_deductions is not null) as loans,
--          count(*) filter (where payslip_other           is not null) as other,
--          count(*) filter (where retirement_contribution is not null) as ret
--     from profiles;
--
-- If any of those is non-zero and you only need to stop the FRONT END writing
-- or reading them, revert the commit instead — the columns are inert on their
-- own. No reporting function reads them, so leaving them in place costs
-- nothing.
--
-- ══ ALSO REVERT ════════════════════════════════════════════
--
-- budget_planner.html (the payslip block and the renamed income line),
-- retirement_calculator.html (_RET_MAPPINGS), dti_calculator.html,
-- affordability_calculator.html and index.html. Left in place against dropped
-- columns, the budget's profile write fails as a whole and stops writing
-- monthly_income too.
--
-- gross_income is NOT dropped — it predates Phase C and 28 profiles hold a
-- value written by the pre-P0-3 assessment.
-- ============================================================

alter table profiles drop column if exists payslip_paye;
alter table profiles drop column if exists payslip_pension;
alter table profiles drop column if exists payslip_medical;
alter table profiles drop column if exists payslip_loan_deductions;
alter table profiles drop column if exists payslip_other;
alter table profiles drop column if exists retirement_contribution;
