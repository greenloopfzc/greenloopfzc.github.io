(() => {
  'use strict';
  const pageSize = 50;
  const can = capability => window.GREENLOOP_CAN?.(capability, 'reports') === true;
  const allowed = () => can('view') && can('report_technician_work');
  const dateAccess = () => can('report_technician_work_search');
  const number = new Intl.NumberFormat('en-GB');
  const dayFormatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Dubai', year: 'numeric', month: '2-digit', day: '2-digit'
  });
  const displayDay = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'UTC', year: 'numeric', month: 'short', day: 'numeric'
  });
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
  let host, root, range, visibleRows = [], offset = 0, total = 0, epoch = 0, busy = false, includeZero = false;
  const $ = selector => root.querySelector(selector);

  function todayUae() {
    const fields = Object.fromEntries(dayFormatter.formatToParts().map(part => [part.type, part.value]));
    return [fields.year, fields.month, fields.day].join('-');
  }

  function dateRange(preset) {
    const today = todayUae();
    if (preset === 'month') return [today.slice(0, 8) + '01', today];
    if (preset === 'week') {
      const first = new Date(today + 'T00:00:00Z');
      first.setUTCDate(first.getUTCDate() - 6);
      return [first.toISOString().slice(0, 10), today];
    }
    return [today, today];
  }

  function setRange(nextRange) {
    range = nextRange;
    offset = total = 0;
    $('#twr-from').value = range[0];
    $('#twr-to').value = range[1];
  }

  function showStatus(text, error = false) {
    const message = $('#twr-status');
    message.textContent = text;
    message.hidden = !text;
    message.classList.toggle('is-error', error);
  }

  function controls() {
    if (!root) return;
    $('#twr-dates').querySelectorAll('input,button').forEach(el => { el.disabled = busy || !dateAccess(); });
    $('#twr-prev').disabled = busy || offset === 0;
    $('#twr-next').disabled = busy || offset + pageSize >= total;
    $('#twr-include-zero').disabled = busy;
    $('#twr-range').textContent = total
      ? (offset + 1) + '–' + Math.min(offset + pageSize, total) + ' of ' + number.format(total) + ' technicians'
      : '0 technicians';
    root.setAttribute('aria-busy', String(busy));
  }

  function partTotals(parts) {
    const totals = { housing: 0, glass: 0, mic: 0 };
    for (const part of parts) {
      const name = part.name.toLowerCase().trim().replace(/[^a-z0-9]/g, '');
      if (/^housing(?:4g|5g|esim|withoutbackcover)?$/.test(name)) totals.housing += part.quantity;
      if (/^(?:glass|glassdamagedglass|glassglassdamage|frontglass|screenglass|frontglassreplacement|glassreplacement|glasschange|glassonly)$/.test(name)) totals.glass += part.quantity;
      if (/^(?:bottom|top|front|rear|main|secondary)?(?:mic|microphone)$/.test(name)) totals.mic += part.quantity;
    }
    return totals;
  }

  function detailTable(lines, label) {
    if (!lines.length) return '<p class="twr-no-items">No ' + label.toLowerCase() + ' recorded.</p>';
    return '<table class="twr-detail-table" aria-label="' + label + '"><thead><tr><th scope="col">Item</th><th scope="col">Qty</th></tr></thead><tbody>'
      + lines.map(line => '<tr><th scope="row">' + esc(line.name) + '</th><td>' + number.format(line.quantity) + '</td></tr>').join('')
      + '</tbody></table>';
  }

  function showWork(row) {
    if (!row || !allowed() || busy) return;
    $('#twr-work-title').textContent = row.name;
    $('#twr-work-range').textContent = [...new Set(range)].map(day => displayDay.format(new Date(day))).join(' – ');
    $('#twr-work-parts').innerHTML = detailTable(row.parts, 'Installed parts');
    $('#twr-work-services').innerHTML = detailTable(row.services, 'Completed services');
    $('#twr-work-dialog').showModal();
  }

  function render(rows) {
    visibleRows = rows;
    const count = value => '<td class="twr-count">' + number.format(value) + '</td>';
    $('#twr-rows').innerHTML = rows.map((row, index) => {
      const totals = partTotals(row.parts);
      return '<tr><td>' + (offset + index + 1) + '</td><th scope="row">' + esc(row.name) + '</th>'
        + count(row.completed_jobs) + count(totals.housing) + count(totals.glass) + count(totals.mic)
        + '<td><button type="button" class="secondary-button twr-open-work" data-twr-work="' + index
        + '" aria-label="View work for ' + esc(row.name) + '" data-capability="report_technician_work" data-capability-page="reports">View Work</button></td></tr>';
    }).join('') || '<tr><td class="report-empty" colspan="7">No technician work recorded for these dates.</td></tr>';
  }

  async function refresh() {
    if (!root || !allowed()) return;
    const token = ++epoch;
    const [from, to] = range;
    const dialog = $('#twr-work-dialog');
    if (dialog.open) dialog.close();
    visibleRows = [];
    busy = true;
    controls();
    $('#twr-results').hidden = true;
    showStatus('Loading technician work…');
    try {
      const client = window.GREENLOOP_GET_CLIENT();
      const { data, error } = await client.rpc('get_technician_work_report_v2', {
        p_from: from, p_to: to, p_offset: offset, p_include_zero: includeZero
      });
      if (token !== epoch || !root?.isConnected || !allowed()) return;
      if (error) throw error;
      if (!data || !Array.isArray(data.rows) || !Number.isSafeInteger(data.total) || data.offset !== offset
          || data.from !== from || data.to !== to || data.include_zero !== includeZero
          || data.rows.length !== Math.min(pageSize, Math.max(0, data.total - offset))) {
        throw Error('The technician work report could not be verified.');
      }
      if (offset >= data.total && offset > 0) {
        offset = data.total ? Math.floor((data.total - 1) / pageSize) * pageSize : 0;
        return refresh();
      }
      total = data.total;
      render(data.rows);
      $('#twr-results').hidden = false;
      showStatus('');
    } catch (error) {
      if (token === epoch && root?.isConnected) showStatus(error.message || 'Technician work could not be loaded.', true);
    } finally {
      if (token === epoch) {
        busy = false;
        controls();
      }
    }
  }

  function unmount() {
    epoch++;
    root?.remove();
    root = host = null;
    visibleRows = [];
    busy = includeZero = false;
    total = offset = 0;
  }

  function mount(target) {
    if (!allowed() || host === target && root?.isConnected) return;
    unmount();
    host = target;
    root = document.createElement('section');
    root.className = 'technician-work-report';
    root.innerHTML = '<form id="twr-dates" class="report-filters twr-dates" aria-label="Work dates" data-capability="report_technician_work_search" data-capability-page="reports">'
      + '<label>From <input type="date" id="twr-from" required></label>'
      + '<label>To <input type="date" id="twr-to" required></label>'
      + '<button class="primary-button" type="submit">View report</button>'
      + '<div class="twr-presets"><button class="secondary-button" type="button" data-twr-cut="today">Today</button>'
      + '<button class="secondary-button" type="button" data-twr-cut="week">Last 7 days</button>'
      + '<button class="secondary-button" type="button" data-twr-cut="month">This month</button></div></form>'
      + '<div class="twr-options"><label><input type="checkbox" id="twr-include-zero" data-capability="report_technician_work" data-capability-page="reports"> Show technicians with no work</label></div>'
      + '<p id="twr-status" role="status" hidden></p><div id="twr-results" hidden>'
      + '<div class="report-table-wrap"><table class="report-table twr-summary" data-preserve-table-layout>'
      + '<thead><tr><th scope="col">S.No</th><th scope="col">Technician</th><th scope="col">Completed jobs</th>'
      + '<th scope="col">Housing</th><th scope="col">Glass</th><th scope="col">Mic</th><th scope="col">Details</th></tr></thead><tbody id="twr-rows"></tbody></table></div>'
      + '<div class="twr-pager" data-capability="report_technician_work" data-capability-page="reports"><button id="twr-prev" class="secondary-button" type="button">Previous</button>'
      + '<span id="twr-range" role="status"></span><button id="twr-next" class="secondary-button" type="button">Next</button></div></div>'
      + '<dialog id="twr-work-dialog" class="twr-work-dialog" aria-labelledby="twr-work-title" data-capability="report_technician_work" data-capability-page="reports">'
      + '<header class="twr-work-header"><div><h3 id="twr-work-title"></h3><p id="twr-work-range"></p></div>'
      + '<button class="secondary-button" id="twr-work-close" type="button" autofocus>Close</button></header>'
      + '<div class="twr-work-columns"><section><h4>Installed parts</h4><div id="twr-work-parts"></div></section>'
      + '<section><h4>Completed services</h4><div id="twr-work-services"></div></section></div></dialog>';
    target.replaceChildren(root);
    setRange(dateRange('today'));
    $('#twr-from').max = $('#twr-to').max = range[1];
    $('#twr-dates').addEventListener('submit', event => {
      event.preventDefault();
      if (busy || !dateAccess()) return;
      const from = $('#twr-from').value, to = $('#twr-to').value;
      if (!from || !to || from > to) {
        showStatus('Choose a From date on or before the To date.', true);
        return;
      }
      setRange([from, to]);
      refresh();
    });
    root.querySelectorAll('[data-twr-cut]').forEach(button => button.addEventListener('click', () => {
      if (busy || !dateAccess()) return;
      setRange(dateRange(button.dataset.twrCut));
      refresh();
    }));
    $('#twr-prev').addEventListener('click', () => { offset -= pageSize; refresh(); });
    $('#twr-next').addEventListener('click', () => { offset += pageSize; refresh(); });
    $('#twr-include-zero').addEventListener('change', event => {
      includeZero = event.target.checked;
      offset = total = 0;
      refresh();
    });
    $('#twr-rows').addEventListener('click', event => {
      const button = event.target.closest('[data-twr-work]');
      if (button) showWork(visibleRows[Number(button.dataset.twrWork)]);
    });
    $('#twr-work-close').addEventListener('click', () => $('#twr-work-dialog').close());
    refresh();
  }

  for (const event of ['greenloop:office-locked', 'greenloop:signed-out', 'greenloop:permissions-changed']) {
    window.addEventListener(event, () => {
      if (event !== 'greenloop:permissions-changed' || !allowed()) unmount();
      else if (root && !dateAccess() && (range[0] !== todayUae() || range[1] !== todayUae())) {
        setRange(dateRange('today'));
        refresh();
      } else controls();
    });
  }
  window.GREENLOOP_TECHNICIAN_WORK_REPORT = { mount, unmount, refresh };
})();
