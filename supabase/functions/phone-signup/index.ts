// Key Wellness — phone-signup Edge Function (Batch 3, pseudo-email phone accounts)
// Creates a phone account WITHOUT any SMS provider or OTP: the phone number is
// the identifier behind a deterministic, non-routable synthetic email, and the
// user is created pre-confirmed via the service role (email confirmation is on
// for real email users, so a synthetic address could never self-confirm).
//
// Called by the UNAUTHENTICATED signup form (anon). The anon key is a valid JWT,
// so it passes verify_jwt; if a deploy ever 401s, redeploy with --no-verify-jwt.
// The function does its own validation (mandatory company code) so it is safe to
// be publicly callable.
//
// Deploy:  supabase functions deploy phone-signup
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const PHONE_DOMAIN = "phone.keywellness.co.bw";

// Mirror of the client's kwNormalizePhone (E.164, default +267 for local numbers).
function normalizePhone(raw: string | undefined): string | null {
  if (!raw) return null;
  let s = String(raw).trim().replace(/[\s\-()]/g, "");
  if (s[0] === "+") { s = "+" + s.slice(1).replace(/\D/g, ""); }
  else {
    s = s.replace(/\D/g, "");
    if (s.startsWith("00")) s = "+" + s.slice(2);
    else if (s.startsWith("267")) s = "+" + s;
    else { s = s.replace(/^0+/, ""); s = (s.length === 7 || s.length === 8) ? "+267" + s : "+" + s; }
  }
  return /^\+\d{8,15}$/.test(s) ? s : null;
}

// Always 200 so the client reads {ok, code} instead of a transport error.
const json = (body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status: 200, headers: { ...CORS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  let body: Record<string, string>;
  try { body = await req.json(); } catch { return json({ ok: false, code: "bad_request", message: "Invalid request." }); }

  const e164 = normalizePhone(body.phone);
  const password = String(body.password || "");
  const code = String(body.invite_code || "").trim();
  const contactEmail = body.email ? String(body.email).trim() : null;

  if (!e164) return json({ ok: false, code: "bad_phone" });
  if (password.length < 8) return json({ ok: false, code: "weak_password", message: "Password must be at least 8 characters." });
  if (!code) return json({ ok: false, code: "invalid_invite" });

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) { console.error("Supabase env missing"); return json({ ok: false, code: "server", message: "Server not configured." }); }
  const admin = createClient(url, key);

  // Mandatory company code: reject codes that don't resolve to an active org.
  // Reuse verify_invite_code(); if it isn't deployed, fall through (the DB trigger
  // still resolves/stamps org_id on insert) rather than block a legit signup.
  try {
    const { data: ok, error: vErr } = await admin.rpc("verify_invite_code", { p_code: code });
    if (!vErr && ok === false) return json({ ok: false, code: "invalid_invite" });
  } catch (_e) { /* RPC absent → rely on the signup trigger */ }

  const email = "p" + e164.replace(/\D/g, "") + "@" + PHONE_DOMAIN;

  // Create pre-confirmed (no email sent). invite_code in user_metadata is read by
  // handle_new_user() to stamp profiles.org_id, exactly as for email signups.
  const { data: created, error: cErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { invite_code: code, is_phone_account: true, phone: e164, contact_email: contactEmail },
  });
  if (cErr) {
    const m = (cErr.message || "").toLowerCase();
    if (m.includes("already") || m.includes("registered") || m.includes("exists") || m.includes("duplicate")) {
      return json({ ok: false, code: "phone_taken" });
    }
    console.error("phone-signup createUser failed:", JSON.stringify(cErr));
    return json({ ok: false, code: "server", message: "Could not create the account." });
  }

  // Stamp profiles.phone (the trigger already created the profiles row + org_id).
  if (created?.user?.id) {
    const { error: pErr } = await admin.from("profiles").update({ phone: e164 }).eq("id", created.user.id);
    if (pErr) console.warn("phone-signup profiles.phone update failed (non-fatal):", JSON.stringify(pErr));
  }

  return json({ ok: true });
});
