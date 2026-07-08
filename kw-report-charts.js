// Key Wellness — shared org utilisation report chart module.
// Used by admin.html's report builder AND employer.html's HR report view so
// the two can never visually drift (per BUILD-NOTES.md, Batch 3 requirement).
// Depends on Chart.js (loaded separately by each page) — this file only
// defines rendering helpers, no page-specific DOM assumptions beyond a
// canvas id.
(function (global) {
  const COLORS = {
    green: '#397e2b',
    greenDeep: '#2a5f20',
    greenTint: 'rgba(57,126,43,.15)',
    yellow: '#f0c90a',
    yellowInk: '#93790a',
    red: '#c0392b',
    orange: '#d97706',
    grey: '#808185',
    line: '#e7e9e3',
  };

  const registry = {}; // canvasId -> Chart instance, so re-render destroys the old one first

  function destroyExisting(canvasId) {
    if (registry[canvasId]) {
      registry[canvasId].destroy();
      delete registry[canvasId];
    }
  }

  // Unwrap a { value, suppressed } cell. Returns null for suppressed/missing
  // cells so callers can decide how to render the gap (never fabricate 0).
  function cellValue(cell) {
    if (cell === null || cell === undefined) return null;
    if (typeof cell === 'object' && 'suppressed' in cell) {
      return cell.suppressed ? null : cell.value;
    }
    return cell; // already a plain number (e.g. totals that are never suppressed)
  }

  function cellDisplay(cell) {
    const v = cellValue(cell);
    return v === null ? '—' : String(v); // em dash for suppressed
  }

  // True if any cell in the list is a suppressed { value:null, suppressed:true } object.
  function anySuppressed(cells) {
    return (cells || []).some(c => c && typeof c === 'object' && c.suppressed === true);
  }

  function baseOptions(extra) {
    return Object.assign({
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
      },
    }, extra || {});
  }

  // ── Engagement funnel — horizontal bar ───────────────────────
  function renderFunnel(canvasId, funnel) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !funnel) return null;
    destroyExisting(canvasId);
    const steps = [
      ['Registered', funnel.registered],
      ['Completed assessment', funnel.completed_assessment],
      ['Used a tool', funnel.used_tool],
      ['Booked a session', funnel.booked_session],
      ['Attended a session', funnel.attended_session],
    ];
    const chart = new global.Chart(el, {
      type: 'bar',
      data: {
        labels: steps.map(s => s[0]),
        datasets: [{
          // Suppressed cells are left as null (Chart.js draws no bar for that
          // category) rather than 0 — a withheld value must never be
          // rendered as a confirmed zero.
          data: steps.map(s => cellValue(s[1])),
          backgroundColor: COLORS.green,
          borderRadius: 4,
        }],
      },
      options: baseOptions({
        indexAxis: 'y',
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: (ctx) => {
                const raw = steps[ctx.dataIndex][1];
                return cellValue(raw) === null ? 'Suppressed (< 3)' : `${ctx.parsed.x} people`;
              },
            },
          },
        },
        scales: { x: { beginAtZero: true, grid: { color: COLORS.line } }, y: { grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Session mode split — doughnut ────────────────────────────
  function renderModeSplit(canvasId, modeSplit) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !modeSplit) return null;
    destroyExisting(canvasId);
    const labels = Object.keys(modeSplit);
    if (!labels.length) return null;
    const values = labels.map(k => cellValue(modeSplit[k]) ?? 0);
    const chart = new global.Chart(el, {
      type: 'doughnut',
      data: {
        labels: labels.map(l => l.charAt(0).toUpperCase() + l.slice(1)),
        datasets: [{
          data: values,
          backgroundColor: [COLORS.green, COLORS.yellow, COLORS.orange, COLORS.grey],
          borderWidth: 0,
        }],
      },
      options: baseOptions({
        plugins: {
          legend: { display: true, position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } },
        },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Monthly bookings/attendance trend — grouped bar ──────────
  function renderMonthlyTrend(canvasId, monthlyTrend) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !Array.isArray(monthlyTrend) || !monthlyTrend.length) return null;
    destroyExisting(canvasId);
    const chart = new global.Chart(el, {
      type: 'bar',
      data: {
        labels: monthlyTrend.map(m => m.month),
        datasets: [
          // Suppressed cells stay null — Chart.js skips the bar rather than
          // drawing a confirmed zero for a withheld value.
          { label: 'Booked', data: monthlyTrend.map(m => cellValue(m.booked)), backgroundColor: COLORS.green },
          { label: 'Attended', data: monthlyTrend.map(m => cellValue(m.attended)), backgroundColor: COLORS.yellow },
        ],
      },
      options: baseOptions({
        plugins: { legend: { display: true, position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } } },
        scales: { y: { beginAtZero: true, grid: { color: COLORS.line } }, x: { grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Combined monthly touchpoint trend — portal sessions + off-platform
  // activity attendees, merged client-side by month — line chart. ──────
  function renderTouchpointsTrend(canvasId, sessionsMonthlyTrend, activitiesList) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart) return null;
    const byMonth = {};
    (sessionsMonthlyTrend || []).forEach(m => {
      byMonth[m.month] = byMonth[m.month] || { sessions: null, activities: 0 };
      byMonth[m.month].sessions = cellValue(m.attended);
    });
    (activitiesList || []).forEach(a => {
      const month = String(a.activity_date || '').slice(0, 7);
      if (!month) return;
      byMonth[month] = byMonth[month] || { sessions: null, activities: 0 };
      byMonth[month].activities += a.attendee_count || 0;
    });
    const months = Object.keys(byMonth).sort();
    if (!months.length) return null;
    destroyExisting(canvasId);
    const chart = new global.Chart(el, {
      type: 'line',
      data: {
        labels: months,
        datasets: [{
          label: 'Total touchpoints',
          data: months.map(m => (byMonth[m].sessions ?? 0) + (byMonth[m].activities ?? 0)),
          borderColor: COLORS.green,
          backgroundColor: COLORS.greenTint,
          borderWidth: 2.5,
          pointBackgroundColor: COLORS.green,
          pointRadius: 4,
          tension: 0.3,
          fill: true,
        }],
      },
      options: baseOptions({
        scales: { y: { beginAtZero: true, grid: { color: COLORS.line } }, x: { grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Assessment category band distribution — grouped bar ─────
  function renderCategoryBands(canvasId, categories, labelMap) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !categories) return null;
    destroyExisting(canvasId);
    const keys = Object.keys(categories);
    if (!keys.length) return null;
    const labels = keys.map(k => (labelMap && labelMap[k]) || k);
    const chart = new global.Chart(el, {
      type: 'bar',
      data: {
        labels,
        datasets: [
          // Suppressed cells stay null so a stacked segment is simply
          // omitted rather than drawn as a confirmed zero contribution.
          { label: 'Under 50', data: keys.map(k => cellValue(categories[k].band_under_50)), backgroundColor: COLORS.red },
          { label: '50–69', data: keys.map(k => cellValue(categories[k].band_50_69)), backgroundColor: COLORS.yellow },
          { label: '70+', data: keys.map(k => cellValue(categories[k].band_70_plus)), backgroundColor: COLORS.green },
        ],
      },
      options: baseOptions({
        plugins: { legend: { display: true, position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } } },
        scales: { y: { beginAtZero: true, stacked: true, grid: { color: COLORS.line } }, x: { stacked: true, grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Demographics: age bands — bar ────────────────────────────
  function renderAgeBands(canvasId, ageBands) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !ageBands) return null;
    destroyExisting(canvasId);
    const order = ['18_29', '30_39', '40_49', '50_plus'];
    const labelFor = { '18_29': '18–29', '30_39': '30–39', '40_49': '40–49', '50_plus': '50+' };
    const chart = new global.Chart(el, {
      type: 'bar',
      data: {
        labels: order.map(k => labelFor[k]),
        datasets: [{ data: order.map(k => cellValue(ageBands[k])), backgroundColor: COLORS.green, borderRadius: 4 }],
      },
      options: baseOptions({
        scales: { y: { beginAtZero: true, grid: { color: COLORS.line } }, x: { grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Session intensity — bar (aggregate replacement for a per-client table) ──
  function renderSessionIntensity(canvasId, intensity) {
    const el = document.getElementById(canvasId);
    if (!el || !global.Chart || !intensity) return null;
    destroyExisting(canvasId);
    const order = ['1', '2', '3_plus'];
    const labelFor = { '1': '1 session', '2': '2 sessions', '3_plus': '3+ sessions' };
    const chart = new global.Chart(el, {
      type: 'bar',
      data: {
        labels: order.map(k => labelFor[k]),
        datasets: [{ data: order.map(k => cellValue(intensity[k])), backgroundColor: COLORS.green, borderRadius: 4 }],
      },
      options: baseOptions({
        scales: { y: { beginAtZero: true, grid: { color: COLORS.line } }, x: { grid: { display: false } } },
      }),
    });
    registry[canvasId] = chart;
    return chart;
  }

  // ── Demographics cross (age band × session-intensity tier) — table, not
  // a chart: a suppression-aware matrix reads far more clearly as text
  // ("—" per cell/total) than as a chart would. Returns an HTML string.
  function renderDemographicsCrossTable(cross) {
    if (!cross || !cross.rows) return '<p style="color:' + COLORS.grey + ';font-size:13px">No data available.</p>';
    const tiers = ['1', '2', '3_plus'];
    const tierLabel = { '1': '1 session', '2': '2 sessions', '3_plus': '3+ sessions' };
    const ageOrder = ['18_29', '30_39', '40_49', '50_plus'];
    const ageLabel = { '18_29': '18–29', '30_39': '30–39', '40_49': '40–49', '50_plus': '50+' };
    const rows = cross.rows || {};
    const colTotals = cross.column_totals || {};

    let html = '<table style="width:100%;border-collapse:collapse;font-size:12px">';
    html += '<thead><tr><th style="text-align:left;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Age band</th>'
      + tiers.map(t => '<th style="text-align:center;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">' + tierLabel[t] + '</th>').join('')
      + '<th style="text-align:center;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Row total</th></tr></thead><tbody>';

    ageOrder.forEach(ab => {
      const row = rows[ab];
      if (!row) return;
      html += '<tr><td style="padding:6px 8px;border-bottom:1px solid ' + COLORS.line + ';font-weight:600">' + ageLabel[ab] + '</td>';
      tiers.forEach(t => {
        html += '<td style="text-align:center;padding:6px 8px;border-bottom:1px solid ' + COLORS.line + '">' + cellDisplay((row.cells || {})[t]) + '</td>';
      });
      html += '<td style="text-align:center;padding:6px 8px;border-bottom:1px solid ' + COLORS.line + ';font-weight:700">' + cellDisplay(row.row_total) + '</td></tr>';
    });

    html += '<tr><td style="padding:6px 8px;font-weight:700">Column total</td>'
      + tiers.map(t => '<td style="text-align:center;padding:6px 8px;font-weight:700">' + cellDisplay(colTotals[t]) + '</td>').join('')
      + '<td></td></tr>';
    html += '</tbody></table>';
    return html;
  }

  // ── Programme activities list — table of events, not people; safe to
  // list individually per the spec (they describe events, never members).
  function renderActivitiesListTable(activitiesList) {
    if (!activitiesList || !activitiesList.length) {
      return '<p style="color:' + COLORS.grey + ';font-size:13px">No off-platform activities logged for this period.</p>';
    }
    const modeLabel = { physical: 'Physical', virtual: 'Virtual', hybrid: 'Hybrid' };
    let html = '<table style="width:100%;border-collapse:collapse;font-size:12px">';
    html += '<thead><tr>'
      + '<th style="text-align:left;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Activity</th>'
      + '<th style="text-align:left;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Date</th>'
      + '<th style="text-align:left;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Mode</th>'
      + '<th style="text-align:right;padding:6px 8px;border-bottom:2px solid ' + COLORS.line + '">Attendees</th>'
      + '</tr></thead><tbody>';
    activitiesList.forEach(a => {
      html += '<tr>'
        + '<td style="padding:6px 8px;border-bottom:1px solid ' + COLORS.line + '">' + String(a.title || '').replace(/</g, '&lt;') + '</td>'
        + '<td style="padding:6px 8px;border-bottom:1px solid ' + COLORS.line + '">' + a.activity_date + '</td>'
        + '<td style="padding:6px 8px;border-bottom:1px solid ' + COLORS.line + '">' + (modeLabel[a.delivery_mode] || '—') + '</td>'
        + '<td style="text-align:right;padding:6px 8px;border-bottom:1px solid ' + COLORS.line + '">' + a.attendee_count + '</td>'
        + '</tr>';
    });
    html += '</tbody></table>';
    return html;
  }

  // ── QoQ comparison badge — accessible colour + text, never colour alone ──
  // current/previous are raw numbers (already unwrapped by the caller) or null.
  function qoqBadge(current, previous, opts) {
    opts = opts || {};
    const suffix = opts.suffix || '';
    if (current === null || previous === null || previous === undefined || current === undefined) {
      return '<span style="color:' + COLORS.grey + ';font-size:12px">No comparable prior-period data</span>';
    }
    const delta = current - previous;
    if (delta === 0) {
      return '<span style="color:' + COLORS.grey + ';font-size:12px">&#8226; No change vs. prior period</span>';
    }
    const up = delta > 0;
    const color = up ? COLORS.green : COLORS.red;
    const arrow = up ? '↑' : '↓';
    const word = up ? 'increase' : 'decrease';
    return '<span style="color:' + color + ';font-size:12px;font-weight:700">' + arrow + ' ' +
      Math.abs(delta).toFixed(1) + suffix + ' ' + word + '</span>' +
      ' <span style="color:' + COLORS.grey + ';font-size:12px">vs. prior period</span>';
  }

  global.KWReportCharts = {
    cellValue,
    cellDisplay,
    anySuppressed,
    renderFunnel,
    renderModeSplit,
    renderMonthlyTrend,
    renderTouchpointsTrend,
    renderCategoryBands,
    renderAgeBands,
    renderSessionIntensity,
    renderDemographicsCrossTable,
    renderActivitiesListTable,
    qoqBadge,
    COLORS,
  };
})(window);
