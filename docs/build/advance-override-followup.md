# Claude Code prompt: Advance override follow-up (verification, notes privacy, consent on amendment, dash fix)

Project: Key Wellness Financial Wellbeing Portal. Same rules as the previous prompt: shared live Supabase project, rollback written before every apply, rolled-back live trials only, no committed test data, `dev` first, merge to `main` once each batch's checklist passes.

Order matters. Batch 0 first, because it may reveal that production is wrong right now.

---

## Batch 0: Verify the live report generator (do this before anything else)

1. In the v7 vs repo diff from the last session, which copy contained the two stray backspace characters in `index.ts`: the deployed v7, or the local repo? Show the exact line before and after.
2. If the deployed v7 has them, the override check is broken in production. Fix the file, redeploy from the repo, verify the deployed files byte for byte against the repo, and record this in BUILD-NOTES as part of the same incident.
3. Run a rolled-back live trial that generates a report on an advisor figure and confirms the figure reaches every place the portal figure used to appear: the header, the reasoning text, the DSR before/after table, the ability-to-repay paragraph, the debt table, the risk tier and the decision. The portal figure must appear nowhere.
4. Deploy hygiene: say how Edge Function deploys will be done from now on so that file contents are never pasted by hand (the cause of v6). Use the Supabase CLI from the repo if it is available here. If it isn't, write a deploy check that compares the deployed files with the repo byte for byte and must pass before the deploy counts as done. Record the method in BUILD-NOTES.

Gate: if step 3 fails after the fix, stop and report. Do not continue to Batch 1.

---

## Batch 1: Advisor-only notes must be advisor-only (P1 decision: fix)

Decision (Tshenolo): advisor notes are visible to advisors, team leads and admins only. A member linked to a client record must not be able to read the advisor's consultation notes or any other advisor-authored content in that record.

Discovery first (read-only, report before changing anything):
- List every RLS policy that lets a linked member read `advisor_clients`, and what that member's pages actually use from the record.
- List every field in `advisor_clients` (including keys inside the `assessment` JSON) that is advisor-authored: consultation notes, observations, advisor scoring, report drafts, and so on.
- The member's own uploaded documents and the member's own submitted answers may stay member-readable. List them separately.

Change:
- The member must stop reading the raw `advisor_clients` row. Give member pages a SECURITY DEFINER RPC that returns only the member-safe fields from the discovery list, then remove member SELECT on the raw row.
- Changing an RLS policy is not purely additive. This is an approved, narrow exception for this one policy only. Write the rollback (restore the exact current policy text) before applying. If the Supabase tool here cannot run the policy change, stop and give Tshenolo the exact SQL and the rollback to run by hand, with a plain-language note on what each does.
- Switch member pages to the new RPC on `dev` first. The policy change must only be applied after the page switch is live, or members' pages will break in the meantime.

Checklist:
- [ ] Linked member: cannot read advisor notes by direct table query (rolled-back trial as that identity).
- [ ] Linked member: their pages still load and show what they showed before, minus advisor content.
- [ ] Advisor, team lead and admin: unchanged access.
- [ ] HR and anon: still refused.
- [ ] Rollback saved.

---

## Batch 2: No new consent when a report is amended

Decision (Tshenolo): an amended report for the same application does not need a new consent form. The original consent covers sharing an advance recommendation with HR; changing the amount does not change what the member agreed to.

Change:
- An amended version of a report whose application already has consent recorded can be marked final using that existing consent. No new consent entry is required.
- When this happens, write an automatic internal note: "Report amended after consent recorded on [date]. Existing consent applied."
- A genuinely new application (a new assessment) still requires its own consent. Do not loosen that.
- Keep the guard that blocks marking final when the report figures don't match the active override.

Checklist:
- [ ] Rolled-back trial: amended version marks final without new consent; the system note is written.
- [ ] Rolled-back trial: a new application without consent is still blocked.
- [ ] Stale-figure guard still blocks.
- [ ] Rollback saved.

---

## Batch 3: Team leads keep override rights (no change)

Decision (Tshenolo): team leads assist with some clients, so they keep the right to set and remove advisor figures. Do not narrow it. Confirm that internal notes record the author's name and role for every figure change, so it is always clear whether an advisor or a team lead made it. Add the role if it is missing.

---

## Batch 4: Dash fix in report headings

Replace "Debt Service Ratio — Before vs After" and any other dash in the report's headings and fixed labels with dash-free wording, for example "Debt Service Ratio: Before and After". Run the new strings through the dash-stripping utility. The rest of the existing report prose is out of scope for this prompt.

Checklist:
- [ ] Generated report (rolled-back trial, or render test) has no em dash, en dash or double hyphen in headings and labels.
- [ ] No-override report output unchanged apart from the heading wording.

---

## Release and report

- Merge `dev` into `main` after each batch's checklist passes.
- BUILD-NOTES: record each decision above with the date (13 Oct 2026), migrations, rollbacks, deploy method and Edge Function versions.
- Final report to Tshenolo in plain language: what changed, what stayed the same, how a problem would show up, how to undo each part. Flag anything that needed a manual step from him.
