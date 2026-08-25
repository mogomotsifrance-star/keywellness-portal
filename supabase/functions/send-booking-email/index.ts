// Key Wellness — send-booking-email Edge Function
// ============================================================
// Transactional mail for bookings: a "received" pair (member + team) when a
// booking is made, and a "confirmed" notice when an admin confirms it. Every
// send is mirrored as an in-app notification so phone-only members, who have
// no routable address, see the same things email members do.
//
// Deploy:  supabase functions deploy send-booking-email
//
// REQUIRES public.booking_notify_payload() — run
// supabase_booking_notify_payload.sql BEFORE deploying this, or every send
// returns ok:false and no mail goes out.
//
// ── WHY THIS WAS REWRITTEN ──────────────────────────────────────
//
// The previous version never validated the caller's JWT and took its
// recipient straight from the request body:
//
//     to: [body.email]
//
// verify_jwt = true looks like authentication but is not. It proves only
// that the caller holds a JWT signed with the project secret — and the anon
// key, published in every page of the frontend, is exactly that. So anyone
// who copied it out of view-source could send arbitrary mail From
// "Key Wellness <noreply@keywellness.co.bw>", carrying the real logo and
// footer and passing SPF/DKIM. The "confirmed" branch also interpolated
// body.service and body.dateStr into bodyHtml, which renderEmail inserts
// raw — so the HTML was attacker-controlled too. And writeNotification()
// wrote to whatever user_id the body named, using the service role, past
// the deliberate absence of a client INSERT policy on notifications.
//
// Three rules now hold, and the rest of this file is just their consequences:
//
//   1. THE CALLER IS AUTHENTICATED. admin.auth.getUser(jwt) verifies a real
//      user. The anon key alone fails it.
//
//   2. NOTHING ADDRESSABLE COMES FROM THE BODY. The caller sends a booking
//      id. booking_notify_payload() decides — as that caller, so its own
//      authorisation applies — whether they may act on that booking, and
//      returns the recipient resolved from identity. Recipient, name,
//      service, date, time and user_id all come from that payload.
//
//   3. EVERYTHING INTERPOLATED IS ESCAPED. Values reaching bodyHtml go
//      through esc(); everything else is in the ledger, which renderEmail
//      already escapes.
//
// The ONE field still taken from the body is `message`, the member's own
// free-text note, because index.html does not persist it. It is capped,
// escaped, and only ever appears in the internal mail to the team address —
// never in anything sent to a member, and never in an address. If that note
// is ever stored on the booking row, take it from the payload and delete
// the exception.
// ============================================================
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { renderEmail, escapeHtml as esc, KW_FROM, KW_REPLY_TO, KW_PORTAL_URL } from "../_shared/kw-email.ts";

// ── CORS ─────────────────────────────────────────────────────────
// Narrowed from "*". This endpoint sends mail on a member's behalf, so
// there is no reason for an arbitrary origin to reach it from a browser.
// Add the portal subdomain here when portal.keywellness.co.bw goes live.
const ALLOWED_ORIGINS = [
  "https://mogomotsifrance-star.github.io",
  "https://keywellness-portal.mogomotsifrance.workers.dev",
  "https://keywellness.co.bw",
  "https://portal.keywellness.co.bw",
];

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") || "";
  const allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const MAX_MESSAGE_CHARS = 2000;

serve(async (req) => {
  const CORS = corsHeaders(req);
  const json = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const ANON_KEY     = Deno.env.get("SUPABASE_ANON_KEY");
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!SUPABASE_URL || !SERVICE_KEY || !ANON_KEY) {
    console.error("Supabase env missing");
    return json({ error: "Not configured" }, 500);
  }
  if (!RESEND_API_KEY) {
    console.error("RESEND_API_KEY secret is not set");
    return json({ error: "Email service is not configured" }, 500);
  }
  // Bound after the guard so sendEmail() below closes over a plain string
  // rather than `string | undefined`.
  const resendKey: string = RESEND_API_KEY;

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // ── 1. Authenticate the caller ─────────────────────────────────
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json({ error: "Sign in required." }, 401);
  const { data: userData, error: uErr } = await admin.auth.getUser(jwt);
  if (uErr || !userData?.user) return json({ error: "Session expired. Please sign in again." }, 401);

  // ── 2. Body: a booking id, a type, and the member's own note ───
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }

  const bookingId = typeof body.booking_id === "string" ? body.booking_id.trim() : "";
  if (!bookingId) return json({ error: "booking_id is required" }, 400);
  const type = body.type === "confirmed" ? "confirmed" : "new";
  const message = typeof body.message === "string"
    ? body.message.slice(0, MAX_MESSAGE_CHARS).trim()
    : "";

  // ── 3. Resolve the booking AS THE CALLER ───────────────────────
  // Run through the anon key with the caller's JWT attached, so
  // booking_notify_payload() sees them and applies its own gate. Using the
  // service role here would defeat the point.
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data: p, error: pErr } = await asCaller.rpc("booking_notify_payload", {
    p_booking_id: bookingId,
  });
  if (pErr || !p) {
    const msg = (pErr?.message || "").toLowerCase();
    if (msg.includes("not authorised")) return json({ error: "Not authorised for that booking." }, 403);
    if (msg.includes("not found"))      return json({ error: "Booking not found." }, 404);
    console.error("booking_notify_payload failed:", JSON.stringify(pErr));
    return json({ error: "Could not load the booking." }, 500);
  }

  const to          = (p.notify_email as string | null) || null;
  const userId      = (p.user_id as string | null) || undefined;
  const firstName   = (p.first_name as string) || "there";
  const fullName    = (p.full_name as string) || "";
  const phone       = (p.phone as string | null) || "";
  const service     = (p.service as string) || "coaching";
  const sessionType = (p.session_type as string | null) || "";
  const dateStr     = (p.date as string | null) || "";
  const time        = (p.time as string | null) || "";
  const when        = dateStr ? ` on ${esc(dateStr)}` : "";

  // ── helpers ────────────────────────────────────────────────────
  async function sendEmail(payload: object): Promise<{ ok: boolean; error?: string }> {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const out = await res.json();
    if (!res.ok) {
      console.error("Resend error:", JSON.stringify(out));
      return { ok: false, error: out?.message ?? "Resend API error" };
    }
    return { ok: true };
  }

  // Best-effort in-app mirror. user_id comes from the resolved payload, not
  // the body, so a caller cannot write into someone else's feed. Failure is
  // logged, never fatal — the booking is already saved by every caller.
  async function notify(kind: string, title: string, text: string) {
    if (!userId) return;
    try {
      const { error } = await admin.from("notifications")
        .insert({ user_id: userId, type: kind, title, body: text });
      if (error) console.error("notification insert failed:", JSON.stringify(error));
    } catch (e) {
      console.error("notification insert threw:", String(e));
    }
  }

  // ── 4a. type "confirmed" ───────────────────────────────────────
  if (type === "confirmed") {
    if (to) {
      const html = renderEmail({
        subject: "Your Key Wellness booking is confirmed",
        preheader: `Your ${service} session${dateStr ? ` on ${dateStr}` : ""} has been confirmed.`,
        eyebrow: "Coaching",
        heading: `Good news, ${firstName} — you're confirmed`,
        bodyHtml: `<p style="margin:0 0 14px;">Your ${esc(service)} session${when} has been confirmed by Key Wellness. We look forward to seeing you.</p>`,
        ledger: [
          { label: "Service", value: service },
          ...(dateStr ? [{ label: "Date", value: dateStr }] : []),
          ...(time ? [{ label: "Time", value: time }] : []),
        ],
        asideHtml: "Need to reschedule? Reply to this email or write to wellness@keywellness.co.bw.",
        variant: "member",
      });
      const r = await sendEmail({
        from: KW_FROM, to: [to], reply_to: KW_REPLY_TO,
        subject: "Your Key Wellness booking is confirmed", html,
      });
      if (!r.ok) return json({ error: `Failed to send confirmation email: ${r.error}` }, 502);
    }
    await notify(
      "booking_confirmed",
      "Booking confirmed",
      `Your ${service} session${dateStr ? ` on ${dateStr}` : ""} has been confirmed. We look forward to seeing you.`,
    );
    return json({ ok: true, emailed: !!to });
  }

  // ── 4b. type "new" ─────────────────────────────────────────────
  if (!service || !dateStr || !time) {
    // Should not happen: these come off the booking row, which cannot be
    // created without them. Guard anyway so a half-written row is visible.
    console.error("booking missing service/date/time:", bookingId);
    return json({ error: "That booking is incomplete." }, 400);
  }

  const clientLedger = [
    { label: "Service", value: service },
    ...(sessionType ? [{ label: "Session type", value: sessionType }] : []),
    { label: "Date", value: dateStr },
    { label: "Time", value: time },
  ];

  if (to) {
    const clientHtml = renderEmail({
      subject: `Booking received — ${service}`,
      preheader: "We've received your booking and will confirm within 24 hours.",
      eyebrow: "Coaching",
      heading: `We've received your booking, ${firstName}`,
      bodyHtml: `<p style="margin:0 0 14px;">Thank you for booking with Key Wellness. We have received your request and will confirm your appointment within <strong>24 hours</strong>.</p>`,
      ledger: clientLedger,
      asideHtml: "Need to change something? Reply to this email or write to wellness@keywellness.co.bw.",
      variant: "member",
    });
    const r = await sendEmail({
      from: KW_FROM, to: [to], reply_to: KW_REPLY_TO,
      subject: `Booking received — ${service}`, html: clientHtml,
    });
    if (!r.ok) return json({ error: `Failed to send client confirmation: ${r.error}` }, 502);
  }

  await notify(
    "booking_received",
    "Booking received",
    `We've received your ${service} booking for ${dateStr} at ${time}. We'll confirm within 24 hours.`,
  );

  // Internal notification. `message` is the only body-supplied value left;
  // it is capped and escaped, sits in the ledger, and this mail only ever
  // goes to the team address.
  const teamHtml = renderEmail({
    subject: `[KW] New booking request — ${fullName}`.trim(),
    preheader: "New booking request received.",
    eyebrow: "Bookings",
    heading: "New booking request",
    bodyHtml: `<p style="margin:0 0 14px;">A new booking request has come in via the portal.</p>`,
    ledger: [
      { label: "Client", value: fullName || "—" },
      { label: "Service", value: service },
      ...(sessionType ? [{ label: "Session type", value: sessionType }] : []),
      { label: "Requested", value: `${dateStr}, ${time}` },
      { label: "Phone", value: phone || "—" },
      { label: "Message", value: message || "—" },
    ],
    button: { label: "Open in admin", url: `${KW_PORTAL_URL}/admin.html` },
    variant: "internal",
  });

  // reply_to is the resolved recipient, never a body value — so a reply
  // from the team cannot be redirected by the caller.
  const teamResult = await sendEmail({
    from: KW_FROM, to: [KW_REPLY_TO], reply_to: to || KW_REPLY_TO,
    subject: `New booking: ${service} — ${fullName}`.trim(), html: teamHtml,
  });
  if (!teamResult.ok) return json({ error: `Team notification failed: ${teamResult.error}` }, 502);

  return json({ ok: true, emailed: !!to });
});
