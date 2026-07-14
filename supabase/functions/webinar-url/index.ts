import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// webinar-url — mints a short-lived signed URL for a private `webinars`
// bucket object, after verifying the caller may see the content_items row.
//
// Security model (see BATCH-0-WEBINARS-THRESHOLDS-FINDINGS.md):
//   • The row is loaded through the CALLER'S RLS context (anon key + the
//     caller's JWT), so the org check is the same RLS policy that gates the
//     Learn page list — not a re-implementation that could drift.
//   • The service-role client is used ONLY to (a) distinguish 403 from 404
//     after RLS returns nothing, and (b) sign the storage URL. It never
//     returns row data to the caller.
//   • Explicit JSON errors — never a silent empty 200.
//
// Input:  POST { content_item_id: "<uuid>" }
// Output: 200 { url, expires_in }  |  401/403/404/500 { error }

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SIGNED_URL_TTL_SECONDS = 7200; // ≤ 2 hours: hour-long content + pause headroom

function jsonResponse(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    console.error("webinar-url: missing Supabase env configuration");
    return jsonResponse(500, { error: "Service is not configured" });
  }

  let body: { content_item_id?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "Invalid JSON body" });
  }
  const contentItemId = (body.content_item_id || "").trim();
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!UUID_RE.test(contentItemId)) {
    return jsonResponse(400, { error: "content_item_id must be a UUID" });
  }

  // ── 1. Verify the caller's JWT ────────────────────────────────
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) {
    return jsonResponse(401, { error: "Not authenticated" });
  }
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) {
    return jsonResponse(401, { error: "Not authenticated" });
  }

  // ── 2. Load the row through the caller's RLS context ─────────
  // RLS hides unpublished webinars and other orgs' webinars, so a visible
  // row here IS the authorisation decision.
  const { data: item, error: itemErr } = await callerClient
    .from("content_items")
    .select("id, kind, video_path")
    .eq("id", contentItemId)
    .eq("kind", "webinar")
    .maybeSingle();

  if (itemErr) {
    console.error("webinar-url: RLS-context lookup failed:", itemErr.message);
    return jsonResponse(500, { error: "Could not load webinar" });
  }

  const serviceClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  if (!item) {
    // Distinguish "not yours" (403) from "missing/unpublished" (404) so
    // failures are debuggable. The row itself is never returned.
    const { data: shadow } = await serviceClient
      .from("content_items")
      .select("id, published, org_id")
      .eq("id", contentItemId)
      .eq("kind", "webinar")
      .maybeSingle();
    if (shadow && shadow.published) {
      return jsonResponse(403, { error: "This webinar is not available for your organisation" });
    }
    return jsonResponse(404, { error: "Webinar not found or not published" });
  }

  if (!item.video_path) {
    return jsonResponse(404, { error: "Webinar has no video file attached yet" });
  }

  // ── 3. Sign the storage URL (service role) ───────────────────
  const { data: signed, error: signErr } = await serviceClient.storage
    .from("webinars")
    .createSignedUrl(item.video_path, SIGNED_URL_TTL_SECONDS);

  if (signErr || !signed?.signedUrl) {
    console.error("webinar-url: signing failed:", signErr?.message);
    return jsonResponse(500, { error: "Could not create a playback link. The video file may be missing from storage." });
  }

  return jsonResponse(200, { url: signed.signedUrl, expires_in: SIGNED_URL_TTL_SECONDS });
});
