/* Key Wellness — headless checks for the advisor Documents tab: View and
   Download (13 Oct 2026).

   Loads the real advisor.html in Chromium with a stubbed Supabase client.
   The client record carries three documents the way advisor_clients.assessment
   holds them (base64 data URLs): a PDF, a PNG and a Word file.

   Checks: who gets which button, the in-page viewer (blob: URL, never a
   third-party viewer), Escape and focus return, the original filename on
   download, one log call per action, and fail-closed when the log call fails.

   Usage:   node tests/smoke-docs.js
*/
const { chromium } = require('playwright');
const path = require('path');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const ADVISOR_HTML = 'file://' + path.resolve(__dirname, '..', 'advisor.html');
const ME = '11111111-1111-4111-8111-111111111111';
const CLIENT_ID = 'f460e2df-bd48-42aa-9976-f481a955b2c2';

// A real one-page PDF and a real 1x1 PNG, so the browser can decode both.
const PDF = '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n';
const PDF_URL = 'data:application/pdf;base64,' + Buffer.from(PDF).toString('base64');
const PNG_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const DOCX_URL = 'data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,' + Buffer.from('PK\u0003\u0004 not really a docx').toString('base64');

const CLIENT = {
  id: CLIENT_ID, first_name: 'Tumelo', last_name: 'Kgamayane', email: '', phone: '',
  org_id: null, org_name: null, org_unit_id: null, unit_label: null, no_org: true, offers_advances: false,
  advisor_id: 'adv-france', is_mine: true, created_at: '2026-08-28T08:00:00Z', updated_at: '2026-08-28T09:00:00Z',
  assessment: {
    personal: { name: 'Tumelo', surname: 'Kgamayane' }, kids: [], income: {}, liabilities: [], budget: {},
    documents: [
      { id: 'id_pdf', name: 'Payslip Sept 2026.pdf', mime: 'application/pdf', size: PDF.length, uploadedAt: '2026-10-01T08:00:00Z', dataUrl: PDF_URL },
      { id: 'id_png', name: 'ID copy.png', mime: 'image/png', size: 68, uploadedAt: '2026-10-01T08:01:00Z', dataUrl: PNG_URL },
      { id: 'id_docx', name: 'Statement.docx', mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', size: 30, uploadedAt: '2026-10-01T08:02:00Z', dataUrl: DOCX_URL },
    ],
  },
};

function stub(page) {
  return page.addInitScript(({ CLIENT, ME }) => {
    window.__rpc = [];
    window.__logFail = false;
    const chain = {
      eq: () => chain, is: () => chain, in: () => chain, or: () => chain, order: () => chain, limit: () => chain,
      maybeSingle: async () => ({ data: { id: ME }, error: null }),
      single: async () => ({ data: null, error: null }),
      update: () => chain,
      then: (res) => res({ data: [], error: null })
    };
    const fake = {
      from: () => ({ select: () => chain, insert: () => chain, update: () => chain, delete: () => chain }),
      rpc: async (fn, args) => {
        window.__rpc.push({ fn, args: JSON.parse(JSON.stringify(args || null)) });
        if (fn === 'advisor_me') return { data: { id: 'adv-france', full_name: 'France Mogomotsi', email: 'france@keywealth.co.bw', is_team_lead: false }, error: null };
        if (fn === 'advisor_clients_list') return { data: [CLIENT], error: null };
        if (fn === 'log_document_access') {
          if (window.__logFail) return { data: null, error: { message: 'not authorised for that client' } };
          return { data: null, error: null };
        }
        return { data: [], error: null };
      },
      functions: { invoke: async () => ({ data: null, error: { message: 'n/a' } }) },
      auth: {
        getSession: async () => ({ data: { session: { user: { id: ME, email: 'france@keywealth.co.bw' } } } }),
        getUser: async () => ({ data: { user: { id: ME, email: 'france@keywealth.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
  }, { CLIENT, ME });
}

(async () => {
  const browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  await page.setViewportSize({ width: 1280, height: 900 });
  const errors = [];
  const requests = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('request', r => requests.push(r.url()));
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await page.route('**fonts.googleapis.com/**', r => r.abort());
  await stub(page);
  await page.goto(ADVISOR_HTML);
  await page.waitForTimeout(1200);

  await page.evaluate((id) => { openClient(id); switchTab('documents'); }, CLIENT_ID);
  await page.waitForTimeout(300);

  const rows = await page.evaluate(() => Array.from(document.querySelectorAll('td.doc-acts')).map(td => ({
    btns: Array.from(td.querySelectorAll('button.btn')).map(b => b.textContent.trim()),
    note: (td.querySelector('.doc-nopreview') || {}).textContent || '' })));
  check('1  PDF row: View and Download', JSON.stringify(rows[0] && rows[0].btns) === '["View","Download"]' && !rows[0].note, JSON.stringify(rows[0]));
  check('2  image row: View and Download', JSON.stringify(rows[1] && rows[1].btns) === '["View","Download"]' && !rows[1].note, JSON.stringify(rows[1]));
  check('3  Word row: Download only, with the preview note',
    JSON.stringify(rows[2] && rows[2].btns) === '["Download"]' && rows[2].note === 'Preview available for PDF and image files', JSON.stringify(rows[2]));
  check('4  no data: URL is left as a bare link on the tab',
    await page.evaluate(() => !document.querySelector('a[href^="data:"]')));

  /* View the PDF */
  await page.evaluate(() => { window.__rpc = []; });
  await page.click('#docView_0');
  await page.waitForSelector('#docViewer', { timeout: 3000 }).catch(() => {});
  const v = await page.evaluate(async () => {
    const f = document.querySelector('#docViewer iframe');
    const blobType = f ? (await (await fetch(f.src)).blob()).type : null;
    return {
      open: !!document.getElementById('docViewer'), src: f ? f.src : null, blobType,
      name: (document.getElementById('docViewerName') || {}).textContent,
      dialog: document.getElementById('docViewer') && document.getElementById('docViewer').getAttribute('role'),
      focus: document.activeElement && document.activeElement.id,
      logs: window.__rpc.filter(r => r.fn === 'log_document_access'),
    };
  });
  check('5  View opens the in-page viewer with the file name', v.open && v.name === 'Payslip Sept 2026.pdf' && v.dialog === 'dialog', JSON.stringify(v));
  check('6  the PDF is a blob: URL of type application/pdf (the browser\'s own viewer)', /^blob:/.test(v.src || '') && v.blobType === 'application/pdf', v.src + ' ' + v.blobType);
  check('7  exactly one log row requested: view, right client, right document',
    v.logs.length === 1 && v.logs[0].args.p_action === 'view' && v.logs[0].args.p_client_id === 'f460e2df-bd48-42aa-9976-f481a955b2c2' && v.logs[0].args.p_document_id === 'id_pdf', JSON.stringify(v.logs));
  check('8  focus moves into the viewer (Close)', v.focus === 'docViewerClose', v.focus);

  /* Download from inside the viewer */
  await page.evaluate(() => { window.__rpc = []; });
  const [dl1] = await Promise.all([
    page.waitForEvent('download', { timeout: 5000 }).catch(() => null),
    page.click('#docViewer button:has-text("Download")'),
  ]);
  check('9  Download in the viewer keeps the original filename', dl1 && dl1.suggestedFilename() === 'Payslip Sept 2026.pdf', dl1 && dl1.suggestedFilename());
  const l9 = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'log_document_access'));
  check('10 ...and logs exactly one download', l9.length === 1 && l9[0].args.p_action === 'download', JSON.stringify(l9));

  /* Escape closes, focus returns */
  await page.keyboard.press('Escape');
  await page.waitForTimeout(100);
  const esc = await page.evaluate(() => ({ open: !!document.getElementById('docViewer'), focus: document.activeElement && document.activeElement.id,
    locked: document.body.classList.contains('doc-viewer-open') }));
  check('11 Escape closes the viewer and focus returns to the View button', !esc.open && esc.focus === 'docView_0' && !esc.locked, JSON.stringify(esc));

  /* Image */
  await page.click('#docView_1');
  await page.waitForSelector('#docViewer img', { timeout: 3000 }).catch(() => {});
  await page.waitForTimeout(200);
  const img = await page.evaluate(() => { const i = document.querySelector('#docViewer img'); return i ? { src: i.src, w: i.naturalWidth } : null; });
  check('12 an image renders in an <img> from a blob: URL', img && /^blob:/.test(img.src) && img.w === 1, JSON.stringify(img));
  await page.click('#docViewerClose');
  await page.waitForTimeout(100);
  check('13 Close closes it and returns focus', await page.evaluate(() => !document.getElementById('docViewer') && document.activeElement.id === 'docView_1'));

  /* Download a non-previewable file from the row */
  await page.evaluate(() => { window.__rpc = []; });
  const [dl2] = await Promise.all([
    page.waitForEvent('download', { timeout: 5000 }).catch(() => null),
    page.click('tr:has-text("Statement.docx") button:has-text("Download")'),
  ]);
  check('14 Word file downloads with its original name', dl2 && dl2.suggestedFilename() === 'Statement.docx', dl2 && dl2.suggestedFilename());
  const l14 = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'log_document_access'));
  check('15 ...logged once as a download of that document', l14.length === 1 && l14[0].args.p_document_id === 'id_docx' && l14[0].args.p_action === 'download', JSON.stringify(l14));

  /* Fail closed */
  await page.evaluate(() => { window.__logFail = true; window.__rpc = []; });
  await page.click('#docView_0');
  await page.waitForTimeout(300);
  const fc = await page.evaluate(() => ({ open: !!document.getElementById('docViewer'),
    banner: (document.getElementById('kwBanner') || {}).textContent || '' }));
  check('16 when the log call fails, View does not open the file and says why',
    !fc.open && /Could not record access/.test(fc.banner), JSON.stringify(fc));
  const [dl3] = await Promise.all([
    page.waitForEvent('download', { timeout: 1500 }).catch(() => null),
    page.click('tr:has-text("Payslip") button:has-text("Download")'),
  ]);
  check('17 when the log call fails, Download does not download', dl3 === null);
  await page.evaluate(() => { window.__logFail = false; });

  /* No third-party viewer, no fetch of the document from anywhere */
  const outside = requests.filter(u => !/^(file:|blob:|data:)/.test(u)
    && !/cdn\.jsdelivr\.net\/npm\/@supabase|fonts\.googleapis\.com/.test(u));
  const viewers = requests.filter(u => /docs\.google|officeapps|view\.office|pdfjs|drive\.google/i.test(u));
  check('18 no third-party viewer domain in network requests', viewers.length === 0, viewers.join(', '));
  check('19 opening documents made no network request beyond the page\'s own assets', outside.every(u => !/Payslip|ID%20copy|Statement/i.test(u)), outside.join(', '));

  check('20 zero JS errors', errors.length === 0, errors.join(' | '));

  if (process.env.SCREENSHOTS) {
    await page.click('#docView_0'); await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(process.env.SCREENSHOTS, 'docs-viewer.png') });
    await page.keyboard.press('Escape');
    await page.screenshot({ path: path.join(process.env.SCREENSHOTS, 'docs-tab.png'), fullPage: true });
  }

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
