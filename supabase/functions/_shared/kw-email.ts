// Shared Key Wellness transactional email template module.
// Implements the master email shell defined in kw-prompt-email-templates.md
// (Batch 1). No design-preview HTML file exists in this repo — the shell
// below is built directly from the skeleton/spec embedded in that prompt.
// Deno-only module (imported by Supabase Edge Functions), no external deps.

export const KW_COLORS = {
  yellow: "#E8C018",
  green: "#387838",
  ink: "#1C2B21",
  field: "#F2F2EC",
  muted: "#6E7A70",
  hairline: "#E4E4DC",
  slate: "#3C463F",
  white: "#FFFFFF",
} as const;

export const KW_FROM = "Key Wellness <noreply@keywellness.co.bw>";
export const KW_REPLY_TO = "wellness@keywellness.co.bw";

// Portal production URL. `keywellness.co.bw` is a separate, unrelated
// WordPress marketing site (confirmed 404 on every portal path) — the
// planned home for the portal is the future subdomain
// `portal.keywellness.co.bw`, not yet live. Until that DNS is live, every
// absolute portal link in this file must point at the real deployed portal,
// GitHub Pages. Swap this one constant (and nothing else) once the
// subdomain goes live. See BATCH-0-FINDINGS.md and BUILD-NOTES.md.
export const KW_PORTAL_URL = "https://mogomotsifrance-star.github.io/keywellness-portal";

export const KW_LOGO_URL = `${KW_PORTAL_URL}/assets/img/kw-logo-horizontal.png`;

export interface LedgerRow {
  label: string;
  value: string;
}

export function renderLedger(rows: LedgerRow[]): string {
  const rowsHtml = rows
    .map((row, i) => {
      const borderStyle = i < rows.length - 1 ? `border-bottom:1px dotted #CFCFC3;` : "";
      return `
        <tr>
          <td style="padding:9px 0;${borderStyle}font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12.5px;color:${KW_COLORS.muted};vertical-align:top;">${escapeHtml(row.label)}</td>
          <td align="right" style="padding:9px 0;${borderStyle}font-family:'DM Mono','Courier New',monospace;font-size:13px;color:${KW_COLORS.ink};text-align:right;vertical-align:top;">${escapeHtml(row.value)}</td>
        </tr>`;
    })
    .join("");
  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${KW_COLORS.field};border-radius:8px;margin:20px 0;">
      <tr><td style="padding:6px 20px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${rowsHtml}</table>
      </td></tr>
    </table>`;
}

function escapeHtml(s: string): string {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderButton(label: string, url: string, variant: "member" | "internal"): string {
  const fill = variant === "internal" ? KW_COLORS.slate : KW_COLORS.green;
  return `
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:26px 0 6px;">
      <tr>
        <td style="border-radius:8px;background:${fill};">
          <!--[if mso]>
          <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" href="${url}" style="height:44px;v-text-anchor:middle;width:220px;" arcsize="18%" fillcolor="${fill}" stroke="f">
          <center style="color:#ffffff;font-family:sans-serif;font-size:14px;font-weight:600;">${escapeHtml(label)}</center>
          </v:roundrect>
          <![endif]-->
          <!--[if !mso]><!-->
          <a href="${url}" target="_blank" style="display:inline-block;padding:12px 26px;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:14px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(label)}</a>
          <!--<![endif]-->
        </td>
      </tr>
    </table>`;
}

function renderFooter(variant: "member" | "internal"): string {
  if (variant === "internal") {
    return `
      <p style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;color:${KW_COLORS.muted};line-height:1.6;">
        Automated notification from the Key Wellness portal.
      </p>`;
  }
  return `
    <p style="margin:0 0 10px;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12.5px;font-weight:500;color:${KW_COLORS.green};line-height:1.6;">
      Your individual data is never shared with your employer.
    </p>
    <p style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;color:${KW_COLORS.muted};line-height:1.6;">
      Key Wellness &middot; Botswana<br>
      <a href="${KW_PORTAL_URL}" style="color:${KW_COLORS.muted};text-decoration:underline;">Key Wellness Portal</a>
      &middot; <a href="mailto:${KW_REPLY_TO}" style="color:${KW_COLORS.muted};text-decoration:underline;">Help</a>
    </p>`;
}

export interface RenderEmailOpts {
  subject: string;
  preheader: string;
  eyebrow: string;
  heading: string;
  /** Pre-built paragraph HTML (caller supplies <p> tags), already escaped where needed. */
  bodyHtml: string;
  ledger?: LedgerRow[];
  button?: { label: string; url: string };
  /** Aside note using the yellow keyline rule as a left accent — never yellow text. */
  asideHtml?: string;
  /** "If the button doesn't work" fallback line with the raw URL. */
  altLink?: { label: string; url: string };
  variant: "member" | "internal";
  /** Extra footer line appended after the standard footer (e.g. reward opt-in copy). */
  footerExtraHtml?: string;
}

export function renderEmail(opts: RenderEmailOpts): string {
  const keyline = opts.variant === "internal" ? KW_COLORS.slate : KW_COLORS.yellow;

  const internalChip =
    opts.variant === "internal"
      ? `<div style="display:inline-block;margin-bottom:14px;padding:3px 8px;border-radius:4px;background:${KW_COLORS.slate};font-family:'DM Mono','Courier New',monospace;font-size:10px;font-weight:500;letter-spacing:.08em;color:#ffffff;text-transform:uppercase;">Internal</div>`
      : "";

  const aside = opts.asideHtml
    ? `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:20px 0;">
      <tr>
        <td style="border-left:3px solid ${KW_COLORS.yellow};padding:2px 0 2px 14px;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;color:${KW_COLORS.muted};line-height:1.6;">
          ${opts.asideHtml}
        </td>
      </tr>
    </table>`
    : "";

  const ledgerHtml = opts.ledger?.length ? renderLedger(opts.ledger) : "";
  const buttonHtml = opts.button ? renderButton(opts.button.label, opts.button.url, opts.variant) : "";
  const altLinkHtml = opts.altLink
    ? `
    <p style="margin:18px 0 0;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;color:${KW_COLORS.muted};line-height:1.6;word-break:break-all;">
      ${escapeHtml(opts.altLink.label)}<br>
      <a href="${opts.altLink.url}" style="color:${KW_COLORS.green};">${opts.altLink.url}</a>
    </p>`
    : "";

  return `<!DOCTYPE html>
<html lang="en" xmlns:v="urn:schemas-microsoft-com:vml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>${escapeHtml(opts.subject)}</title>
</head>
<body style="margin:0;padding:0;background:${KW_COLORS.field};">
<div style="display:none;max-height:0;overflow:hidden;">${escapeHtml(opts.preheader)}&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${KW_COLORS.field};">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:${KW_COLORS.white};border-radius:12px;overflow:hidden;">
<tr><td style="height:3px;background:${keyline};font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td style="padding:36px 40px 8px;">
<img src="${KW_LOGO_URL}" width="210" alt="Key Wellness" style="display:block;margin-bottom:30px;border:0;outline:none;">
${internalChip}
<div style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:10.5px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;color:${KW_COLORS.green};margin-bottom:12px;">${escapeHtml(opts.eyebrow)}</div>
<h1 style="margin:0 0 16px;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:22px;font-weight:600;color:${KW_COLORS.ink};line-height:1.3;">${escapeHtml(opts.heading)}</h1>
<div style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:14.5px;line-height:1.65;color:${KW_COLORS.slate};">${opts.bodyHtml}</div>
${ledgerHtml}
${aside}
${buttonHtml}
${altLinkHtml}
</td></tr>
<tr><td style="border-top:1px solid ${KW_COLORS.hairline};padding:20px 40px 26px;">
${renderFooter(opts.variant)}
${opts.footerExtraHtml ?? ""}
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

// ── Batch 3: certificate reward renderer (template only — no send path) ──

export interface CertificateReadyEmailOpts {
  firstName: string;
  level: "Foundations" | "Intermediate" | "Advanced";
  issuedDate: string;
  downloadUrl: string;
}

export function certificateReadyEmail(opts: CertificateReadyEmailOpts): { subject: string; html: string } {
  const subject = `Your certificate is ready, ${opts.firstName}`;
  const html = renderEmail({
    subject,
    preheader: `Your ${opts.level} level certificate is ready to download.`,
    eyebrow: "Learning reward",
    heading: `Well done, ${opts.firstName} — your certificate is ready`,
    bodyHtml: `<p style="margin:0 0 14px;">You've completed the ${escapeHtml(opts.level)} level of your learning journey. Your certificate, awarded by Prolearn, is ready to download.</p>`,
    ledger: [
      { label: "Level", value: opts.level },
      { label: "Awarded by", value: "Prolearn" },
      { label: "Issued", value: opts.issuedDate },
    ],
    button: { label: "Download certificate", url: opts.downloadUrl },
    altLink: { label: "You can also find this any time under Rewards in your portal.", url: opts.downloadUrl },
    variant: "member",
    footerExtraHtml: `
      <p style="margin:14px 0 0;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11.5px;color:${KW_COLORS.muted};line-height:1.6;">
        You're receiving reward emails because you opted in. <a href="${KW_PORTAL_URL}/#profile" style="color:${KW_COLORS.muted};text-decoration:underline;">Manage preferences</a>
      </p>`,
  });
  return { subject, html };
}
