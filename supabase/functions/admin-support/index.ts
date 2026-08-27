// Key Wellness — admin-support Edge Function
// ============================================================
// Member support for Lone and Michelle, from ops.html: find a person, send
// them a password-reset link, resend a booking confirmation.
//
// Deploy:  supabase functions deploy admin-support
//
// REQUIRES supabase_support_audit.sql — run it BEFORE deploying, or every
// call returns ok:false because the RPCs it depends on do not exist.
//
// ── THE THREE RULES, AND THE ONE THIS BREAKS ────────────────
//
// send-booking-email's header lays down three rules, written after a real
// vulnerability. They hold here too, with one deliberate difference:
//
//   1. THE CALLER IS AUTHENTICATED. admin.auth.getUser(jwt) verifies a real
//      user. verify_jwt = true is NOT authentication — it proves only that
//      the caller holds a JWT signed with the project secret, and the anon
//      key, published in every page of view-source, is exactly that.
//
//   2. NOTHING ADDRESSABLE COMES FROM THE BODY. ← this is the rule a support
//      tool must break, because support means acting on someone else's
//      account. So it is replaced, not dropped: the body carries a USER ID
//      that came from support_lookup() — a gated query in the database — and
//      the address is resolved server-side from auth.users. An admin cannot
//      type an arbitrary address and have Key Wellness mail it. That is the
//      difference between a support tool and an open relay with a logo.
//
//   3. EVERYTHING INTERPOLATED IS ESCAPED. Nothing here builds HTML; the
//      reset mail is Supabase's own and the resend goes through the existing
//      template unchanged.
//
// ── WHAT THE SERVICE ROLE IS USED FOR ───────────────────────
//
// Only two things a database cannot do: verify a JWT, and call the Auth admin
// API. Every authorisation decision and every audit row goes through RPCs
// called AS THE SIGNED-IN USER, so is_ops_admin() is evaluated against the
// real caller and not against a key that can do anything.
//
// ── WHO MAY ─────────────────────────────────────────────────
//
// is_ops_admin(), never is_admin() directly. Today they are the same function.
// When M3 lands, France keeps his admin role and LOSES this capability, and
// nothing in this file changes.
// ============================================================
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const ALLOWED_ORIGINS = [
  "https://mogomotsifrance-star.github.io",
  "https://keywellness-portal.mogomotsifrance.workers.dev",
  "https://keywellness.co.bw",
  "https://portal.keywellness.co.bw",
];

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const ACTIONS = ["lookup", "send_password_reset", "resend_booking_confirmation", "list_recent"];

/** Where the reset link lands. The portal subdomain is not live yet — see the
 *  note on KW_PORTAL_URL in _shared/kw-email.ts. */
const REDIRECT_TO = "https://mogomotsifrance-star.github.io/keywellness-portal/index.html";

export interface Deps {
  /** service role — JWT verification and the Auth admin API, nothing else */
  admin: SupabaseClient;
  /** the caller's own client — every RPC below runs as THEM, not as us */
  asCaller: (jwt: string) => SupabaseClient;
}

export function makeDeps(): Deps {
  const url = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  return {
    admin: createClient(url, service),
    asCaller: (jwt: string) =>
      createClient(url, anon, { global: { headers: { Authorization: `Bearer ${jwt}` } } }),
  };
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);

  // ── Rule 1 ──────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json({ ok: false, error: "not authorised" }, 401);

  const { data: userData, error: userErr } = await deps.admin.auth.getUser(jwt);
  if (userErr || !userData?.user) {
    // The anon key reaches here and stops here.
    return json({ ok: false, error: "not authorised" }, 401);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad request" }, 400); }

  const action = String(body.action || "");
  if (!ACTIONS.includes(action)) return json({ ok: false, error: "unknown action" }, 400);

  // ── Rule 2 ──────────────────────────────────────────────
  // An address in the body is refused outright rather than ignored. Ignoring
  // it would let a caller believe it had been honoured.
  if ("email" in body || "to" in body || "recipient" in body) {
    return json({
      ok: false,
      error: "this endpoint does not accept an address. Send a user_id from lookup.",
    }, 400);
  }

  const caller = deps.asCaller(jwt);

  try {
    // ── lookup ───────────────────────────────────────────
    if (action === "lookup") {
      const { data, error } = await caller.rpc("support_lookup", { p_q: String(body.q || "") });
      if (error) return json({ ok: false, error: error.message }, 403);
      await caller.rpc("support_log", {
        p_action: "lookup", p_outcome: "ok",
        p_detail: `q=${String(body.q || "").slice(0, 80)}`,
      });
      return json({ ok: true, results: data });
    }

    // ── list_recent ──────────────────────────────────────
    if (action === "list_recent") {
      const { data, error } = await caller.rpc("support_recent", { p_limit: 50 });
      if (error) return json({ ok: false, error: error.message }, 403);
      return json({ ok: true, results: data });
    }

    // ── send_password_reset ──────────────────────────────
    if (action === "send_password_reset") {
      const targetId = String(body.user_id || "");
      if (!targetId) return json({ ok: false, error: "user_id required" }, 400);

      const gate = await allowed(caller, "send_password_reset", targetId);
      if (!gate.allowed) {
        await caller.rpc("support_log", {
          p_action: "send_password_reset", p_outcome: "denied",
          p_target_user: targetId, p_detail: gate.reason,
        });
        return json({ ok: false, error: gate.reason }, 429);
      }

      // The address is resolved HERE, from the id — never taken from the body.
      const { data: target, error: tErr } = await deps.admin.auth.admin.getUserById(targetId);
      if (tErr || !target?.user?.email) {
        await caller.rpc("support_log", {
          p_action: "send_password_reset", p_outcome: "error",
          p_target_user: targetId, p_detail: "no account or no address",
        });
        return json({ ok: false, error: "that account has no email address" }, 404);
      }

      const email = target.user.email;
      const { error: rErr } = await deps.admin.auth.resetPasswordForEmail(email, {
        redirectTo: REDIRECT_TO,
      });
      if (rErr) {
        await caller.rpc("support_log", {
          p_action: "send_password_reset", p_outcome: "error",
          p_target_user: targetId, p_detail: rErr.message.slice(0, 200),
        });
        return json({ ok: false, error: "could not send the link" }, 502);
      }

      await caller.rpc("support_log", {
        p_action: "send_password_reset", p_outcome: "ok",
        p_target_user: targetId, p_detail: email,
      });
      await mirrorNotification(deps.admin, targetId,
        "Password reset link sent",
        "A member of the Key Wellness team sent you a link to set a new password. " +
        "If you did not ask for it, you can ignore this.");

      return json({ ok: true, sent_to: email });
    }

    // ── resend_booking_confirmation ──────────────────────
    // booking_notify_payload() is called AS THE CALLER, so its own
    // authorisation applies and the recipient comes from the payload. Rule 2
    // is intact for this action with nothing extra needed.
    if (action === "resend_booking_confirmation") {
      const bookingId = String(body.booking_id || "");
      if (!bookingId) return json({ ok: false, error: "booking_id required" }, 400);

      const gate = await allowed(caller, "resend_booking_confirmation", null);
      if (!gate.allowed) {
        await caller.rpc("support_log", {
          p_action: "resend_booking_confirmation", p_outcome: "denied",
          p_target_booking: bookingId, p_detail: gate.reason,
        });
        return json({ ok: false, error: gate.reason }, 429);
      }

      const { data: payload, error: pErr } = await caller.rpc("booking_notify_payload", {
        p_booking_id: bookingId,
      });
      if (pErr || !payload) {
        await caller.rpc("support_log", {
          p_action: "resend_booking_confirmation", p_outcome: "error",
          p_target_booking: bookingId, p_detail: (pErr?.message || "no payload").slice(0, 200),
        });
        return json({ ok: false, error: "could not read that booking" }, 403);
      }

      // The existing function, the existing template, unchanged. From the
      // member's side nothing unusual happened, so nothing says "resent".
      const { error: sErr } = await deps.admin.functions.invoke("send-booking-email", {
        body: { bookingId, kind: "received" },
        headers: { Authorization: `Bearer ${jwt}` },
      });
      if (sErr) {
        await caller.rpc("support_log", {
          p_action: "resend_booking_confirmation", p_outcome: "error",
          p_target_booking: bookingId, p_detail: sErr.message.slice(0, 200),
        });
        return json({ ok: false, error: "could not send the confirmation" }, 502);
      }

      await caller.rpc("support_log", {
        p_action: "resend_booking_confirmation", p_outcome: "ok",
        p_target_booking: bookingId,
        p_target_user: (payload as Record<string, unknown>).user_id ?? null,
        p_detail: String((payload as Record<string, unknown>).email ?? ""),
      });
      return json({ ok: true, sent_to: (payload as Record<string, unknown>).email ?? null });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: (e as Error).message.slice(0, 200) }, 500);
  }
}

async function allowed(caller: SupabaseClient, action: string, targetUser: string | null) {
  const { data, error } = await caller.rpc("support_can", {
    p_action: action, p_target_user: targetUser,
  });
  if (error) return { allowed: false, reason: "not authorised" };
  const d = data as { allowed: boolean; reason: string | null };
  return { allowed: !!d?.allowed, reason: d?.reason || "not authorised" };
}

/** Phone-only members have no routable address; the in-app notification is the
 *  only thing they will see. Same reasoning as send-booking-email. */
async function mirrorNotification(admin: SupabaseClient, userId: string, title: string, bodyText: string) {
  try {
    await admin.from("notifications").insert({
      user_id: userId, type: "support_password_reset", title, body: bodyText,
    });
  } catch { /* the mail is what matters; a failed mirror must not fail the call */ }
}

if (import.meta.main) {
  const deps = makeDeps();
  serve((req) => handle(req, deps));
}
