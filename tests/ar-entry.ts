// Browser bundle entry for tests/smoke-advance.js — exposes the real
// compute + report modules as window.__AR. Built by tests/run-advance.sh.
export { compute, liveLiabilities, suggestClassification } from "../supabase/functions/advance-recommendation/compute.ts";
export { buildContent, fallbackNarrative } from "../supabase/functions/advance-recommendation/report.ts";
