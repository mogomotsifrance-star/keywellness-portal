// Key Wellness: verify a deployed Edge Function against the repo (13 Oct 2026)
// ============================================================
// Written after the advance-recommendation v6 incident (BUILD-NOTES 13 Oct):
// a deploy payload assembled by hand shipped placeholder text, and a script
// edit put literal backspace bytes into index.ts. Two checks, both must pass
// before a deploy is called done:
//
//   1. The repo is clean: no control characters (other than tab, LF, CR) in
//      any file under supabase/functions/. Catches a "\b" that became 0x08.
//   2. The deployed function is the repo: every file Supabase serves for the
//      function is byte-identical (line endings normalised) to the same file
//      at a git ref, and no repo file the function imports is missing.
//
// Usage:
//   node tests/verify-edge-deploy.mjs --scan
//   node tests/verify-edge-deploy.mjs <saved get_edge_function JSON> [git ref, default HEAD]
// The JSON is what the Supabase MCP get_edge_function call returns (or
// `supabase functions download` output converted to the same shape).
// Exit code 0 = clean / identical; 1 = anything else.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const BAD = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/;
let failed = false;

function scan(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { scan(p); continue; }
    if (!/\.(ts|js|mjs|json)$/.test(name)) continue;
    const lines = readFileSync(p, "utf8").split("\n");
    lines.forEach((l, i) => {
      if (BAD.test(l)) {
        failed = true;
        console.log(`CONTROL CHAR  ${p}:${i + 1}  ${JSON.stringify(l.trim()).slice(0, 120)}`);
      }
    });
  }
}

const args = process.argv.slice(2);
scan("supabase/functions");
if (args[0] === "--scan" || !args.length) {
  console.log(failed ? "\nFAIL: control characters in supabase/functions" : "OK: no control characters in supabase/functions");
  process.exit(failed ? 1 : 0);
}

const ref = args[1] || "HEAD";
const d = JSON.parse(readFileSync(args[0], "utf8"));
console.log(`deployed ${d.slug} v${d.version} ezbr ${d.ezbr_sha256}  vs  git ${ref}`);
for (const f of d.files) {
  const rel = "supabase/functions/" + f.name.split("functions/").pop();
  let repo;
  try { repo = execFileSync("git", ["show", `${ref}:${rel}`], { encoding: "utf8" }).replace(/\r\n/g, "\n"); }
  catch { console.log(`MISSING IN REPO  ${rel}`); failed = true; continue; }
  const dep = String(f.content).replace(/\r\n/g, "\n");
  if (dep === repo) console.log(`IDENTICAL  ${rel}`);
  else {
    failed = true;
    const a = repo.split("\n"), b = dep.split("\n");
    const i = a.findIndex((l, k) => l !== b[k]);
    console.log(`DIFF       ${rel}  first difference at line ${i + 1}`);
    console.log(`  repo:     ${JSON.stringify(a[i])}`);
    console.log(`  deployed: ${JSON.stringify(b[i])}`);
  }
  if (BAD.test(dep)) { failed = true; console.log(`CONTROL CHAR in deployed ${rel}`); }
}
console.log(failed ? "\nFAIL: the deployed function is not the repo" : "\nOK: deployed function is byte-identical to the repo");
process.exit(failed ? 1 : 0);
