// Browser bundle entry for tests/smoke-rehab.js — exposes the real
// compute-rehab + report-rehab modules as window.__DRP. Built by tests/run-rehab.sh.
export { computeRehab, suggestAction } from "../supabase/functions/debt-rehab-plan/compute-rehab.ts";
export { buildContent, checkableActions, fallbackNarrative, PRINT_HEADER } from "../supabase/functions/debt-rehab-plan/report-rehab.ts";
export { liveLiabilities } from "../supabase/functions/_shared/kw-finance.ts";
