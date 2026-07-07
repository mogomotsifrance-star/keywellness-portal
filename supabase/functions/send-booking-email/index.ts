import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { renderEmail, KW_FROM, KW_REPLY_TO } from "../_shared/kw-email.ts";

// To restrict to specific origins instead of *, replace "*" with the origin
// from the incoming request if it matches one of these:
//   const ALLOWED = [
//     "https://mogomotsifrance-star.github.io",
//     "https://keywellness-portal.mogomotsifrance.workers.dev",
//     "https://keywellness.co.bw",
//   ];
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("RESEND_API_KEY secret is not set");
    return new Response(
      JSON.stringify({ error: "Email service is not configured" }),
      { status: 500, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  let body: Record<string, string>;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  async function sendEmail(payload: object): Promise<{ ok: boolean; id?: string; error?: string }> {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const json = await res.json();
    if (!res.ok) {
      console.error("Resend error:", JSON.stringify(json));
      return { ok: false, error: json?.message ?? "Resend API error" };
    }
    return { ok: true, id: json.id };
  }

  const type = body.type || "new";

  // ── type "confirmed": client-facing notice that an admin confirmed the booking. ──
  // Same trigger as before (admin sets status to 'confirmed' in admin.html) — only the
  // transport changed, from a FormSubmit autoresponse to Resend via the shared template.
  if (type === "confirmed") {
    const { firstName, email, service, dateStr } = body;
    if (!email) {
      return new Response(
        JSON.stringify({ error: "Missing required field: email" }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }
    const svc = service || "coaching";
    const when = dateStr ? ` on ${dateStr}` : "";
    const html = renderEmail({
      subject: "Your Key Wellness booking is confirmed",
      preheader: `Your ${svc} session${when} has been confirmed.`,
      eyebrow: "Coaching",
      heading: `Good news, ${firstName || "there"} — you're confirmed`,
      bodyHtml: `<p style="margin:0 0 14px;">Your ${svc} session${when} has been confirmed by Key Wellness. We look forward to seeing you.</p>`,
      asideHtml: "Need to reschedule? Reply to this email or write to wellness@keywellness.co.bw.",
      variant: "member",
    });
    const result = await sendEmail({
      from: KW_FROM,
      to: [email],
      reply_to: KW_REPLY_TO,
      subject: "Your Key Wellness booking is confirmed",
      html,
    });
    if (!result.ok) {
      return new Response(
        JSON.stringify({ error: `Failed to send confirmation email: ${result.error}` }),
        { status: 502, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }
    return new Response(
      JSON.stringify({ ok: true, id: result.id }),
      { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  // ── type "new" (default): booking request received. ──
  const { firstName, lastName, email, phone, service, sessionType, dateStr, time, message } = body;

  if (!email || !service || !dateStr || !time) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: email, service, dateStr, time" }),
      { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  const TEAM = KW_REPLY_TO;

  const clientLedger = [
    { label: "Service", value: service },
    ...(sessionType ? [{ label: "Session type", value: sessionType }] : []),
    { label: "Date", value: dateStr },
    { label: "Time", value: time },
  ];

  const clientHtml = renderEmail({
    subject: `Booking received — ${service}`,
    preheader: "We've received your booking and will confirm within 24 hours.",
    eyebrow: "Coaching",
    heading: `We've received your booking, ${firstName || "there"}`,
    bodyHtml: `<p style="margin:0 0 14px;">Thank you for booking with Key Wellness. We have received your request and will confirm your appointment within <strong>24 hours</strong>.</p>`,
    ledger: clientLedger,
    asideHtml: "Need to change something? Reply to this email or write to wellness@keywellness.co.bw.",
    variant: "member",
  });

  const teamLedger = [
    { label: "Client", value: `${firstName || ""} ${lastName || ""}`.trim() || "—" },
    { label: "Service", value: service },
    ...(sessionType ? [{ label: "Session type", value: sessionType }] : []),
    { label: "Requested", value: `${dateStr}, ${time}` },
    { label: "Phone", value: phone || "—" },
    { label: "Message", value: message || "—" },
  ];

  const teamHtml = renderEmail({
    subject: `[KW] New booking request — ${firstName || ""} ${lastName || ""}`.trim(),
    preheader: "New booking request received.",
    eyebrow: "Bookings",
    heading: "New booking request",
    bodyHtml: `<p style="margin:0 0 14px;">A new booking request has come in via the portal.</p>`,
    ledger: teamLedger,
    button: { label: "Open in admin", url: "https://keywellness.co.bw/admin.html" },
    variant: "internal",
  });

  // Send client confirmation — this is the gating send.
  const clientResult = await sendEmail({
    from: KW_FROM,
    to: [email],
    reply_to: TEAM,
    subject: `Booking received — ${service}`,
    html: clientHtml,
  });
  if (!clientResult.ok) {
    return new Response(
      JSON.stringify({ error: `Failed to send client confirmation: ${clientResult.error}` }),
      { status: 502, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  // Send team notification — best-effort; failure is logged (above, inside sendEmail)
  // and reported back in the response, but never blocks or unwinds the client send.
  const teamResult = await sendEmail({
    from: KW_FROM,
    to: [TEAM],
    reply_to: email,
    subject: `New booking: ${service} — ${firstName || ""} ${lastName || ""}`,
    html: teamHtml,
  });
  if (!teamResult.ok) {
    return new Response(
      JSON.stringify({ error: `Client email sent but team notification failed: ${teamResult.error}` }),
      { status: 502, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  return new Response(
    JSON.stringify({ ok: true, id: clientResult.id }),
    { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
  );
});
