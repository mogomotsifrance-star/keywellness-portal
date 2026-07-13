/* Key Wellness — ProLearn certificate renderer (Learning Pathways).
   Fetches the official blank SVG template, substitutes tokens, and
   provides PNG download (3× resolution) with window.print() fallback.
   Fonts: Shelley Script LT Std (name), Sitka Heading Bold (course),
   Sitka Small (date) — self-hosted in assets/fonts/. Google Fonts
   (Pinyon Script + EB Garamond) remain as fallbacks when a licensed
   font file is missing. */
(function (global) {
  'use strict';

  const TEMPLATE_PATH = 'assets/certificates/prolearn-certificate-template.svg';
  const FONT_DIR = 'assets/fonts/';

  // Licensed certificate fonts, self-hosted. Candidates are tried in
  // order; the first file that exists is used. `weight` must match the
  // font-weight the SVG template requests so browsers don't synthesize
  // a faux bold on top of an already-bold face.
  const LOCAL_FONTS = [
    { family: 'Shelley Script LT Std', weight: '400', files: ['ShelleyScriptLTStd.woff2', 'ShelleyScriptLTStd.woff', 'ShelleyScriptLTStd.otf', 'ShelleyScriptLTStd.ttf'] },
    { family: 'Sitka Heading Bold',    weight: '600', files: ['SitkaHeadingBold.woff2',   'SitkaHeadingBold.woff',   'SitkaHeadingBold.otf',   'SitkaHeadingBold.ttf'] },
    { family: 'Sitka Small',           weight: '400', files: ['SitkaSmall.woff2',         'SitkaSmall.woff',         'SitkaSmall.otf',         'SitkaSmall.ttf'] },
  ];

  const FONT_FORMATS = { woff2: 'woff2', woff: 'woff', otf: 'opentype', ttf: 'truetype' };
  function fontFormat(file) { return FONT_FORMATS[file.split('.').pop()] || 'opentype'; }
  const VIEWBOX_W = 841.89;
  const VIEWBOX_H = 595.28;
  const PNG_SCALE = 3; // ~2526 × 1786 px

  const LEVEL_MAP = {
    foundations:  'FOUNDATIONS LEVEL',
    intermediate: 'INTERMEDIATE LEVEL',
    advanced:     'ADVANCED LEVEL',
  };

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  // One-time fetch with in-memory cache; rejects on HTTP error.
  let _templateCache = null;
  async function fetchTemplate() {
    if (_templateCache) return _templateCache;
    const res = await fetch(TEMPLATE_PATH);
    if (!res.ok) throw new Error(`Certificate template fetch failed (${res.status})`);
    _templateCache = await res.text();
    return _templateCache;
  }

  // Build the final SVG string from the template + data.
  function buildSvg(templateSrc, { name, date, level }) {
    const levelKey = (level || 'foundations').toLowerCase();
    const levelLabel = LEVEL_MAP[levelKey] || (esc(level || 'FOUNDATIONS').toUpperCase() + ' LEVEL');

    return templateSrc
      .replace('{{NAME}}',         esc(name || 'Member'))
      .replace('{{COURSE_LINE_1}}', 'FINANCIAL WELLNESS')
      .replace('{{COURSE_LINE_2}}', levelLabel)
      .replace('{{DATE}}',         esc(date || ''));
  }

  // After the SVG is inserted into the DOM, shrink the name text until it fits.
  function autoShrinkName(svgEl) {
    const nameEl = svgEl.querySelector('#kw-name');
    if (!nameEl) return;
    let size = 46;
    while (nameEl.getComputedTextLength() > 500 && size > 24) {
      size -= 2;
      nameEl.setAttribute('font-size', size);
    }
  }

  // Render the certificate into a container element and return the SVG element.
  // Shows an error banner with a Retry button on failure.
  async function render(container, data, { onRetry } = {}) {
    container.innerHTML = '<p style="text-align:center;color:#6b7280;padding:24px">Loading certificate…</p>';
    try {
      ensurePageFonts();
      const tmpl = await fetchTemplate();
      const svgStr = buildSvg(tmpl, data);
      container.innerHTML = svgStr;
      const svgEl = container.querySelector('svg');
      if (svgEl) autoShrinkName(svgEl);
      return svgEl;
    } catch (err) {
      console.error('[Certificate]', err);
      const retryBtn = onRetry
        ? `<button onclick="(${onRetry.toString()})()" style="margin-top:12px;padding:8px 20px;background:#224568;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:14px">Retry</button>`
        : '';
      container.innerHTML = `
        <div style="text-align:center;padding:32px;background:#fff3f3;border:1px solid #f5c6cb;border-radius:8px;color:#721c24">
          <p style="margin:0 0 4px;font-weight:600">Could not load certificate template.</p>
          <p style="margin:0;font-size:13px;color:#856404">${esc(err.message)}</p>
          ${retryBtn}
        </div>`;
      return null;
    }
  }

  // Inline all Google Font URLs in a CSS string as base64 data URIs.
  async function inlineGoogleFont(family, weights) {
    const q = weights ? `${encodeURIComponent(family)}:wght@${weights}` : encodeURIComponent(family);
    const cssUrl = `https://fonts.googleapis.com/css2?family=${q}&display=swap`;
    const css = await (await fetch(cssUrl)).text();
    const urls = Array.from(css.matchAll(/url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/g), m => m[1]);
    const dataUris = await Promise.all(urls.map(async url => {
      const buf = await (await fetch(url)).arrayBuffer();
      let bin = '';
      const bytes = new Uint8Array(buf);
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      const b64 = btoa(bin);
      const mime = url.endsWith('.woff2') ? 'font/woff2' : 'font/woff';
      return `data:${mime};base64,${b64}`;
    }));
    let i = 0;
    return css.replace(/url\(https:\/\/fonts\.gstatic\.com\/[^)]+\)/g, () => `url(${dataUris[i++]})`);
  }

  // Inline one local licensed font as a base64 @font-face rule.
  // Returns '' if none of the candidate files exist.
  async function inlineLocalFont(font) {
    for (const file of font.files) {
      try {
        const res = await fetch(FONT_DIR + file);
        if (!res.ok) continue;
        const buf = await res.arrayBuffer();
        let bin = '';
        const bytes = new Uint8Array(buf);
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        const fmt = fontFormat(file);
        const mime = fmt === 'woff2' ? 'font/woff2' : fmt === 'woff' ? 'font/woff' : 'font/otf';
        return `@font-face{font-family:'${font.family}';font-weight:${font.weight};src:url(data:${mime};base64,${btoa(bin)}) format('${fmt}');font-display:swap;}`;
      } catch (_) { /* try next candidate */ }
    }
    console.warn(`[Certificate] Font file for "${font.family}" not found in ${FONT_DIR} — using fallback font.`);
    return '';
  }

  // Non-inlined @font-face rules (absolute URLs) for on-screen display
  // and the print window. Each src lists every candidate file; the
  // browser skips missing ones.
  function localFontFaceCss() {
    return LOCAL_FONTS.map(f => {
      const srcs = f.files
        .map(file => `url('${new URL(FONT_DIR + file, global.location.href).href}') format('${fontFormat(file)}')`)
        .join(',');
      return `@font-face{font-family:'${f.family}';font-weight:${f.weight};src:${srcs};font-display:swap;}`;
    }).join('\n');
  }

  // Make the certificate fonts available to the current page (for the
  // inline SVG preview). Safe to call repeatedly.
  let _pageFontsInjected = false;
  function ensurePageFonts() {
    if (_pageFontsInjected) return;
    _pageFontsInjected = true;
    const style = document.createElement('style');
    style.id = 'kw-cert-fonts';
    style.textContent = localFontFaceCss();
    document.head.appendChild(style);
    if (!document.querySelector('link[href*="Pinyon+Script"]')) {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = 'https://fonts.googleapis.com/css2?family=EB+Garamond:wght@400;700&family=Pinyon+Script&display=swap';
      document.head.appendChild(link);
    }
  }

  let _fontCssCache = null;
  async function getInlinedFontCss() {
    if (_fontCssCache) return _fontCssCache;
    const warn = e => { console.warn('[Certificate] Font inlining failed; PNG may use fallback fonts:', e); return ''; };
    const parts = await Promise.all([
      inlineGoogleFont('EB+Garamond', '400;700').catch(warn),
      inlineGoogleFont('Pinyon+Script').catch(warn),
      ...LOCAL_FONTS.map(inlineLocalFont),
    ]);
    _fontCssCache = parts.filter(Boolean).join('\n');
    return _fontCssCache;
  }

  // Download the certificate as a PNG (~2526 × 1786 at 3×).
  async function downloadPNG(data, filenamePrefix) {
    let templateSrc;
    try {
      templateSrc = await fetchTemplate();
    } catch (err) {
      alert('Could not load certificate template. Please check your connection and try again.');
      return;
    }

    const fontCss = await getInlinedFontCss();
    const svgStr = buildSvg(templateSrc, data);

    // Inject inlined font CSS + name auto-shrink script into the SVG.
    const withFonts = svgStr.replace(
      /(<svg[^>]*>)/,
      `$1<style>${fontCss}</style>`
    );

    if (document.fonts?.ready) {
      try {
        await Promise.all([
          document.fonts.load("46px 'Shelley Script LT Std'"),
          document.fonts.load("600 16px 'Sitka Heading Bold'"),
          document.fonts.load("14px 'Sitka Small'"),
          document.fonts.load("46px 'Pinyon Script'"),
        ]);
      } catch (_) {}
      await document.fonts.ready;
    }

    const W = Math.round(VIEWBOX_W * PNG_SCALE);
    const H = Math.round(VIEWBOX_H * PNG_SCALE);
    const blob = new Blob([withFonts], { type: 'image/svg+xml;charset=utf-8' });
    const url = URL.createObjectURL(blob);

    try {
      const img = await new Promise((resolve, reject) => {
        const im = new Image();
        im.onload = () => resolve(im);
        im.onerror = reject;
        im.src = url;
      });
      const canvas = document.createElement('canvas');
      canvas.width = W; canvas.height = H;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, W, H);
      ctx.drawImage(img, 0, 0, W, H);
      const pngUrl = canvas.toDataURL('image/png');
      const a = document.createElement('a');
      a.href = pngUrl;
      a.download = `${filenamePrefix || 'key-wellness-certificate'}.png`;
      document.body.appendChild(a);
      a.click();
      a.remove();
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  // Print fallback — opens the certificate in a dedicated print view.
  async function printCertificate(data) {
    let templateSrc;
    try { templateSrc = await fetchTemplate(); }
    catch (err) { alert('Could not load certificate template.'); return false; }

    const svgStr = buildSvg(templateSrc, data);
    const w = window.open('', '_blank', 'width=1060,height=750');
    if (!w) return false;
    w.document.write(`<!DOCTYPE html><html><head><title>Certificate</title>
      <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=EB+Garamond:wght@400;700&family=Pinyon+Script&display=swap">
      <style>${localFontFaceCss()}</style>
      <style>@page{size:landscape}body{margin:0;display:flex;align-items:center;justify-content:center;background:#fff}svg{width:100%;height:auto}</style>
      </head><body>${svgStr}</body></html>`);
    w.document.close();
    w.onload = () => { w.focus(); w.print(); };
    return true;
  }

  global.KWCertificate = { render, downloadPNG, printCertificate };
})(window);
