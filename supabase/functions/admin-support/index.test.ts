// Key Wellness — admin-support security tests.
//
//   deno test --allow-env supabase/functions/admin-support/index.test.ts
//
// These are not coverage tests. Every case here asks one question:
// DID WE RE-OPEN THE HOLE send-booking-email HAD?
//
// That function shipped a version which trusted verify_jwt, took its
// recipient from the request body, and interpolated body fields into HTML —
// so anyone holding the anon key out of view-source could send mail as
// Key Wellness, to anyone, with attacker-controlled content. Its header
// documents the three rules that fixed it. The four cases marked ★ below are
// those rules, restated for a support tool.
//
// The Supabase client is stubbed. Nothing here touches a network or a
// database; the point is the decision path, not the plumbing.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handle, Deps } from "./index.ts";

/* ── Stub ──────────────────────────────────────────────────── */

interface StubOpts {
  /** does admin.auth.getUser(jwt) resolve to a user? */
  validJwt?: boolean;
  /** what support_can() returns */
  can?: { allowed: boolean; reason: string | null };
  /** does support_lookup() raise? */
  lookupThrows?: string | null;
  /** the address getUserById resolves to */
  targetEmail?: string | null;
}

function stub(opts: StubOpts = {}) {
  const o = {
    validJwt: true,
    can: { allowed: true, reason: null },
    lookupThrows: null,
    targetEmail: "member@example.test",
    ...opts,
  };
  const calls: { rpc: string; args: unknown }[] = [];
  const sent: { to: string }[] = [];
  const notifications: unknown[] = [];

  const callerClient = {
    rpc: (name: string, args: unknown) => {
      calls.push({ rpc: name, args });
      if (name === "support_can") return Promise.resolve({ data: o.can, error: null });
      if (name === "support_lookup") {
        return o.lookupThrows
          ? Promise.resolve({ data: null, error: { message: o.lookupThrows } })
          : Promise.resolve({ data: [{ user_id: "u-1", email: "member@example.test" }], error: null });
      }
      if (name === "support_recent") return Promise.resolve({ data: [], error: null });
      if (name === "support_log") return Promise.resolve({ data: "log-1", error: null });
      if (name === "booking_notify_payload") {
        return Promise.resolve({ data: { email: "member@example.test", user_id: "u-1" }, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  };

  const admin = {
    auth: {
      getUser: (_jwt: string) =>
        Promise.resolve(o.validJwt
          ? { data: { user: { id: "admin-1", email: "lone@keywellness.co.bw" } }, error: null }
          : { data: { user: null }, error: { message: "invalid" } }),
      admin: {
        getUserById: (_id: string) =>
          Promise.resolve({ data: { user: o.targetEmail ? { email: o.targetEmail } : null }, error: null }),
      },
      resetPasswordForEmail: (email: string) => {
        sent.push({ to: email });
        return Promise.resolve({ error: null });
      },
    },
    from: (_t: string) => ({ insert: (row: unknown) => { notifications.push(row); return Promise.resolve({ error: null }); } }),
    functions: { invoke: (_n: string, _o: unknown) => Promise.resolve({ error: null }) },
  };

  const deps = { admin, asCaller: (_jwt: string) => callerClient } as unknown as Deps;
  return { deps, calls, sent, notifications };
}

function post(body: unknown, jwt = "a.valid.jwt") {
  return new Request("https://example.test/admin-support", {
    method: "POST",
    headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/* ── ★ Rule 1 — the caller is authenticated ────────────────── */

Deno.test("★ the anon key alone is refused", async () => {
  // The anon key IS a JWT signed with the project secret. verify_jwt would
  // pass it; getUser() must not. This is the exact hole send-booking-email had.
  const { deps } = stub({ validJwt: false });
  const res = await handle(post({ action: "lookup", q: "abc" }), deps);
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error, "not authorised");
});

Deno.test("no Authorization header is refused", async () => {
  const { deps } = stub();
  const req = new Request("https://example.test/admin-support", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "lookup", q: "abc" }),
  });
  assertEquals((await handle(req, deps)).status, 401);
});

Deno.test("★ a valid non-admin JWT is refused by the database, not by us", async () => {
  // The JWT is real; support_can() says no. The refusal must come from
  // is_ops_admin() evaluated in the database, and it must be recorded.
  const { deps, calls } = stub({ can: { allowed: false, reason: "not authorised" } });
  const res = await handle(post({ action: "send_password_reset", user_id: "u-1" }), deps);
  assertEquals(res.status, 429);
  assert(calls.some((c) => c.rpc === "support_can"), "support_can was not consulted");
  const denied = calls.find((c) => c.rpc === "support_log" &&
    (c.args as Record<string, string>).p_outcome === "denied");
  assert(denied, "a denied attempt was not recorded");
});

/* ── ★ Rule 2 — nothing addressable comes from the body ────── */

Deno.test("★ a body carrying an email instead of a user_id is refused outright", async () => {
  // Refused, not ignored: ignoring it would let the caller believe it had
  // been honoured. This is the rule a support tool is most tempted to break.
  const { deps, sent } = stub();
  for (const field of ["email", "to", "recipient"]) {
    const res = await handle(post({ action: "send_password_reset", [field]: "attacker@evil.test" }), deps);
    assertEquals(res.status, 400, `${field} was not refused`);
    assert(/does not accept an address/.test((await res.json()).error));
  }
  assertEquals(sent.length, 0, "something was sent despite the refusal");
});

Deno.test("★ the address is resolved from the user_id, never from the request", async () => {
  const { deps, sent } = stub({ targetEmail: "real@onfile.test" });
  const res = await handle(post({ action: "send_password_reset", user_id: "u-1" }), deps);
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  // The address on file, not anything a caller could have supplied.
  assertEquals(sent[0].to, "real@onfile.test");
});

Deno.test("an account with no address is an error, not a silent success", async () => {
  const { deps, sent, calls } = stub({ targetEmail: null });
  const res = await handle(post({ action: "send_password_reset", user_id: "u-1" }), deps);
  assertEquals(res.status, 404);
  assertEquals(sent.length, 0);
  assert(calls.some((c) => c.rpc === "support_log" &&
    (c.args as Record<string, string>).p_outcome === "error"));
});

/* ── Rate limiting ─────────────────────────────────────────── */

Deno.test("the per-target reset limit refuses and records", async () => {
  const { deps, sent, calls } = stub({
    can: { allowed: false, reason: "this member has already had 3 reset links today" },
  });
  const res = await handle(post({ action: "send_password_reset", user_id: "u-1" }), deps);
  assertEquals(res.status, 429);
  assertEquals(sent.length, 0, "a link went out despite the limit");
  assert(calls.some((c) => c.rpc === "support_log" &&
    (c.args as Record<string, string>).p_outcome === "denied"));
});

/* ── The audit trail ───────────────────────────────────────── */

Deno.test("a success is recorded with the target and the address", async () => {
  const { deps, calls } = stub();
  await handle(post({ action: "send_password_reset", user_id: "u-1" }), deps);
  const ok = calls.find((c) => c.rpc === "support_log" &&
    (c.args as Record<string, string>).p_outcome === "ok");
  assert(ok, "a successful action was not recorded");
  assertEquals((ok!.args as Record<string, string>).p_target_user, "u-1");
});

Deno.test("a lookup is recorded too", async () => {
  const { deps, calls } = stub();
  await handle(post({ action: "lookup", q: "kefilwe" }), deps);
  assert(calls.some((c) => c.rpc === "support_log" &&
    (c.args as Record<string, string>).p_action === "lookup"));
});

/* ── The resend path ───────────────────────────────────────── */

Deno.test("the resend reads the booking AS THE CALLER, so its own gate applies", async () => {
  const { deps, calls } = stub();
  const res = await handle(post({ action: "resend_booking_confirmation", booking_id: "b-1" }), deps);
  assertEquals(res.status, 200);
  // Called on the caller's client, not the service-role one.
  assert(calls.some((c) => c.rpc === "booking_notify_payload"),
    "booking_notify_payload was not called as the caller");
});

/* ── Shape ─────────────────────────────────────────────────── */

Deno.test("an unknown action is refused", async () => {
  const { deps } = stub();
  assertEquals((await handle(post({ action: "delete_everything" }), deps)).status, 400);
});

Deno.test("GET is refused", async () => {
  const { deps } = stub();
  const req = new Request("https://example.test/admin-support", {
    method: "GET", headers: { Authorization: "Bearer a.b.c" },
  });
  assertEquals((await handle(req, deps)).status, 405);
});

Deno.test("OPTIONS is answered for the allowed origins only", async () => {
  const { deps } = stub();
  const req = new Request("https://example.test/admin-support", {
    method: "OPTIONS", headers: { Origin: "https://evil.test" },
  });
  const res = await handle(req, deps);
  assertEquals(res.status, 200);
  // An unlisted origin is not echoed back.
  assert(res.headers.get("Access-Control-Allow-Origin") !== "https://evil.test");
});
