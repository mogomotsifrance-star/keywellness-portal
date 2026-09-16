-- ============================================================
-- Key Wellness — Phase C: the figures that come off pay before it arrives
--
-- Rollback: migrations/rollback-payslip-figures.sql
--
-- ══ WHY ════════════════════════════════════════════════════
--
-- The budget is the one place a member enters their whole financial month, and
-- it asked only for what lands in their account. Everything deducted at source
-- was invisible: their pension contribution, their medical aid share, and —
-- the one that actually distorts a figure we report — loans repaid straight
-- off the salary.
--
-- Consequences before this:
--
--   · monthly_debt was the budget's `debt_min` line alone, so a member whose
--     loan is deducted at source read as having no debt. Their DTI was wrong
--     in the direction that looks healthy.
--   · Retirement prefilled its contribution field from monthly_savings — EVERY
--     savings category — so a member's emergency fund and goal savings were
--     offered back to them as their retirement contribution.
--   · gross_income had no writer but "type it into the tool that needs it",
--     so the lender view was unreachable for anyone who came through the
--     budget (see the 2026-09-15 vault entry).
--
-- ══ WHAT IS ADDED ══════════════════════════════════════════
--
--   payslip_paye, payslip_pension, payslip_medical,
--   payslip_loan_deductions, payslip_other
--     Written by the budget's optional "From your payslip" block. NONE are
--     required, and nothing in that block is added to the budget's income or
--     expense totals — it describes money the member never had the chance to
--     allocate.
--
--   retirement_contribution
--     The VOLUNTARY retirement allocation, from the budget's `retirement`
--     category. Deliberately separate from payslip_pension: one is a choice
--     the member makes each month, the other is taken before they see it, and
--     Phase E needs them apart. Retirement reads the sum.
--
-- gross_income already existed; this gives it its first real writer.
--
-- ══ NULL IS NOT ZERO ═══════════════════════════════════════
--
-- Every column is nullable with NO default. Null means "not told", which is a
-- different fact from 0 ("told, and it is nothing"). Consumers must test for
-- null, not truthiness — the P0 rule that a figure we were never given is
-- UNKNOWN. `null < 10` is `true` in JavaScript, and that is how this class of
-- bug gets shipped.
--
-- ══ WHAT DOES NOT CHANGE ═══════════════════════════════════
--
--   No reporting function reads these columns. The HR aggregates, the
--   suppression floors and the B1 habits-only gate are all untouched.
--
--   monthly_savings keeps its meaning (budget savings categories) but stops
--   counting `debt_extra`, which is a debt figure. That is a front-end change;
--   no column moves.
--
-- Applied live 16 Sep 2026.
-- ============================================================

alter table profiles add column if not exists payslip_paye             numeric;
alter table profiles add column if not exists payslip_pension          numeric;
alter table profiles add column if not exists payslip_medical          numeric;
alter table profiles add column if not exists payslip_loan_deductions  numeric;
alter table profiles add column if not exists payslip_other            numeric;
alter table profiles add column if not exists retirement_contribution  numeric;

comment on column profiles.payslip_paye            is 'Phase C: PAYE deducted from salary. Null = not told.';
comment on column profiles.payslip_pension         is 'Phase C: member pension contribution deducted from salary. Null = not told. NOT part of monthly_savings.';
comment on column profiles.payslip_medical         is 'Phase C: medical aid share deducted from salary. Null = not told. Unions into the cover set; never adds to the cover COUNT.';
comment on column profiles.payslip_loan_deductions is 'Phase C: loan repayments deducted from salary. Null = not told. monthly_debt = budget debt_min + this.';
comment on column profiles.payslip_other           is 'Phase C: other salary deductions. Null = not told.';
comment on column profiles.retirement_contribution is 'Phase C: voluntary retirement allocation from the budget''s retirement category. Null = not told. Separate from payslip_pension.';
