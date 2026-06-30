import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

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

  const { firstName, lastName, email, phone, service, sessionType, dateStr, time, message } = body;

  if (!email || !service || !dateStr || !time) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: email, service, dateStr, time" }),
      { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  const FROM = "Key Wellness <noreply@keywellness.co.bw>";
  const TEAM = "wellness@keywellness.co.bw";

  // ── Email 1: client confirmation ──
  const clientHtml = `
<div style="font-family:Inter,sans-serif;max-width:560px;margin:0 auto;color:#1a2744">
  <div style="background:#1a2744;padding:28px 32px;border-radius:12px 12px 0 0">
    <h1 style="margin:0;font-size:1.3rem;color:#c8973a">Key Wellness</h1>
    <p style="margin:4px 0 0;color:#9badc8;font-size:.85rem">Financial Wellness Portal</p>
  </div>
  <div style="background:#ffffff;padding:32px;border:1px solid #ddd6c8;border-top:none;border-radius:0 0 12px 12px">
    <h2 style="margin:0 0 8px;font-size:1.1rem">Booking Received ✓</h2>
    <p style="color:#4b5563;line-height:1.65">Hi ${firstName || "there"},</p>
    <p style="color:#4b5563;line-height:1.65">Thank you for booking with Key Wellness. We have received your request and will confirm your appointment within <strong>24 hours</strong>.</p>
    <div style="background:#f5f0e8;border-radius:8px;padding:20px;margin:20px 0">
      <table style="width:100%;border-collapse:collapse;font-size:.9rem">
        <tr><td style="padding:6px 0;color:#6b7280;width:40%">Service</td><td style="padding:6px 0;font-weight:600">${service}</td></tr>
        ${sessionType ? `<tr><td style="padding:6px 0;color:#6b7280">Session type</td><td style="padding:6px 0;font-weight:600">${sessionType}</td></tr>` : ""}
        <tr><td style="padding:6px 0;color:#6b7280">Date</td><td style="padding:6px 0;font-weight:600">${dateStr}</td></tr>
        <tr><td style="padding:6px 0;color:#6b7280">Time</td><td style="padding:6px 0;font-weight:600">${time}</td></tr>
      </table>
    </div>
    <p style="color:#4b5563;line-height:1.65">Have questions before your session? Reply to this email or contact us directly at <a href="mailto:${TEAM}" style="color:#c8973a">${TEAM}</a>.</p>
    <p style="color:#4b5563;line-height:1.65;margin-bottom:0">Warm regards,<br><strong>Key Wellness Team</strong></p>
  </div>
  <p style="font-size:.75rem;color:#9badc8;text-align:center;margin-top:16px">Your details are processed securely and used only to manage your booking.</p>
</div>`;

  // ── Email 2: team notification ──
  const teamHtml = `
<div style="font-family:Inter,sans-serif;max-width:560px;margin:0 auto;color:#1a2744">
  <div style="background:#1a2744;padding:20px 28px;border-radius:12px 12px 0 0">
    <h1 style="margin:0;font-size:1.1rem;color:#c8973a">New Booking Received</h1>
  </div>
  <div style="background:#ffffff;padding:28px;border:1px solid #ddd6c8;border-top:none;border-radius:0 0 12px 12px">
    <table style="width:100%;border-collapse:collapse;font-size:.9rem">
      <tr><td style="padding:8px 0;color:#6b7280;width:40%;border-bottom:1px solid #f0ebe0">Client name</td><td style="padding:8px 0;font-weight:600;border-bottom:1px solid #f0ebe0">${firstName || ""} ${lastName || ""}</td></tr>
      <tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Email</td><td style="padding:8px 0;border-bottom:1px solid #f0ebe0"><a href="mailto:${email}" style="color:#c8973a">${email}</a></td></tr>
      <tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Phone</td><td style="padding:8px 0;border-bottom:1px solid #f0ebe0">${phone || "—"}</td></tr>
      <tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Service</td><td style="padding:8px 0;font-weight:600;border-bottom:1px solid #f0ebe0">${service}</td></tr>
      ${sessionType ? `<tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Session type</td><td style="padding:8px 0;border-bottom:1px solid #f0ebe0">${sessionType}</td></tr>` : ""}
      <tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Date</td><td style="padding:8px 0;font-weight:600;border-bottom:1px solid #f0ebe0">${dateStr}</td></tr>
      <tr><td style="padding:8px 0;color:#6b7280;border-bottom:1px solid #f0ebe0">Time</td><td style="padding:8px 0;font-weight:600;border-bottom:1px solid #f0ebe0">${time}</td></tr>
      <tr><td style="padding:8px 0;color:#6b7280;vertical-align:top">Message</td><td style="padding:8px 0">${message || "<em style='color:#9badc8'>No message provided</em>"}</td></tr>
    </table>
  </div>
</div>`;

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

  // Send client confirmation
  const clientResult = await sendEmail({
    from: FROM,
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

  // Send team notification
  const teamResult = await sendEmail({
    from: FROM,
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
