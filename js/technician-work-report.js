(() => {
  'use strict';
  const pageSize = 50;
  const sortCap = 'report_technician_work_sort';
  const downloadCap = 'report_technician_work_download';
  const can = capability => window.GREENLOOP_CAN?.(capability, 'reports') === true;
  const allowed = () => can('view') && can('report_technician_work');
  const dateAccess = () => can('report_technician_work_search');
  const defaultSort = { kind: 'jobs', key: null, desc: true };
  const baseColumns = [{kind: 'name', key: null, label: 'Technician'},
    {kind: 'jobs', key: null, label: 'Completed Jobs'}];
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
  let host, root, range, report, offset = 0, epoch = 0, busy = false, exporting = false;
  let includeZero = false, sort = defaultSort;
  const $ = selector => root.querySelector(selector);
  const columnsFor = data => [...baseColumns, ...data.columns];
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const columnId = (kind, key) => JSON.stringify([kind, key]);

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
    if (!range || range.join() !== nextRange.join()) sort = defaultSort;
    range = nextRange;
    offset = 0;
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
    const working = busy || exporting;
    const total = report?.total || 0;
    $('#twr-dates').querySelectorAll('input,button').forEach(el => { el.disabled = working || !dateAccess(); });
    $('#twr-prev').disabled = working || !report || offset === 0;
    $('#twr-next').disabled = working || offset + pageSize >= total;
    $('#twr-include-zero').disabled = working;
    root.querySelectorAll('[data-twr-sort]').forEach(el => { el.disabled = working || !can(sortCap); });
    root.querySelectorAll('[data-twr-export]').forEach(el => {
      el.hidden = !can(downloadCap);
      el.disabled = working || !total || !can(downloadCap);
    });
    $('#twr-range').textContent = total
      ? (offset + 1) + '–' + Math.min(offset + pageSize, total) + ' of ' + number.format(total) + ' technicians'
      : '0 technicians';
    root.setAttribute('aria-busy', String(working));
  }

  function values(row, columns, position) {
    const quantities = new Map();
    for (const [kind, entries] of [['part', row.parts], ['service', row.services]]) {
      for (const entry of entries) quantities.set(columnId(kind, entry.key), entry.quantity);
    }
    return [position, row.name, row.completed_jobs,
      ...columns.map(col => quantities.get(columnId(col.kind, col.key)) ?? 0)];
  }

  function render(data) {
    const columns = columnsFor(data);
    const parts = data.columns.filter(col => col.kind === 'part').length;
    const services = data.columns.length - parts;
    const grouped = data.columns.length > 0;
    const table = $('#twr-table');
    table.classList.toggle('twr-has-items', grouped);
    table.style.setProperty('--twr-items', data.columns.length);
    table.querySelectorAll('colgroup').forEach(group => group.remove());
    const colgroup = document.createElement('colgroup');
    colgroup.innerHTML = '<col class="twr-col-number"><col class="twr-col-name"><col class="twr-col-jobs">';
    table.insertBefore(colgroup, table.tHead);
    for (const length of [parts, services].filter(Boolean)) {
      const group = document.createElement('colgroup');
      group.span = length;
      table.insertBefore(group, table.tHead);
    }
    const head = (col, index) => {
      const active = sort.kind === col.kind && sort.key === col.key;
      const direction = active ? (sort.desc ? 'descending' : 'ascending') : 'none';
      const arrow = active ? (sort.desc ? '↓' : '↑') : '↕';
      const fixed = index < 2;
      return '<th scope="col" aria-sort="' + direction + '"' + (fixed ? ' class="twr-fixed twr-fixed-' + (index + 2)
        + '"' + (grouped ? ' rowspan="2"' : '') : '') + '>'
        + '<button type="button" class="twr-sort" data-twr-sort="' + index + '" data-capability="' + sortCap
        + '" data-capability-page="reports">' + esc(col.label) + ' <span aria-hidden="true">' + arrow
        + '</span></button><span data-twr-label>' + esc(col.label) + '</span></th>';
    };
    const groups = (parts ? '<th scope="colgroup" colspan="' + parts + '">Installed Parts</th>' : '')
      + (services ? '<th scope="colgroup" colspan="' + services + '">Completed Services</th>' : '');
    table.tHead.innerHTML = '<tr' + (grouped ? ' class="twr-groups"' : '') + '><th scope="col" class="twr-fixed twr-fixed-1"'
      + (grouped ? ' rowspan="2"' : '') + '>S.No</th>' + head(columns[0], 0) + head(columns[1], 1)
      + groups + '</tr>' + (grouped ? '<tr>' + data.columns.map((col, index) => head(col, index + 2)).join('') + '</tr>' : '');
    const rowHtml = data.rows.map((row, index) => {
      const [serial, name, jobs, ...items] = values(row, data.columns, offset + index + 1);
      return '<tr><td class="twr-fixed twr-fixed-1">' + serial + '</td><th scope="row" class="twr-fixed twr-fixed-2">'
        + esc(name) + '</th><td class="twr-count twr-fixed twr-fixed-3">' + number.format(jobs) + '</td>'
        + items.map(qty => '<td class="twr-count' + (qty === 0 ? ' twr-zero' : '') + '">' + number.format(qty) + '</td>').join('') + '</tr>';
    });
    $('#twr-rows').innerHTML = rowHtml.join('') || '<tr><td class="report-empty" colspan="3">No technician work recorded for these dates.</td></tr>';
    applySortVisibility();
  }

  function applySortVisibility() {
    root.querySelectorAll('[data-twr-sort]').forEach(el => {
      el.hidden = !can(sortCap);
      el.nextElementSibling.hidden = can(sortCap);
    });
  }

  async function read(start, full = false, expected = null) {
    const [from, to] = range;
    const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc('get_technician_work_report_v3', {
      p_from: from, p_to: to, p_offset: start, p_include_zero: includeZero,
      p_sort: sort.kind, p_item: sort.key, p_desc: sort.desc, p_export: full, p_expected: expected
    });
    if (error) throw error;
    if (!data || !count(data.total) || !Array.isArray(data.columns) || !Array.isArray(data.rows)
        || !/^[a-f0-9]{32}$/.test(data.snapshot) || (expected && data.snapshot !== expected)
        || data.from !== from || data.to !== to || data.offset !== start || data.include_zero !== includeZero
        || data.sort !== sort.kind || data.item !== sort.key || data.desc !== sort.desc || data.export !== full
        || data.rows.length !== (full ? data.total : Math.min(pageSize, Math.max(0, data.total - start)))) {
      throw Error('The technician work report could not be verified.');
    }
    const keys = new Set();
    for (const col of data.columns) {
      const id = columnId(col.kind, col.key);
      if (!['part','service'].includes(col.kind) || typeof col.key !== 'string' || !col.key
          || typeof col.label !== 'string' || !col.label || keys.has(id)) {
        throw Error('The technician work columns could not be verified.');
      }
      keys.add(id);
    }
    const employees = new Set();
    for (const row of data.rows) {
      if (typeof row.employee_key !== 'string' || !row.employee_key || employees.has(row.employee_key)
          || typeof row.name !== 'string' || !row.name || !count(row.completed_jobs)
          || ![['part',row.parts],['service',row.services]].every(([kind, lines]) =>
            Array.isArray(lines) && lines.every(line => count(line.quantity) && keys.has(columnId(kind, line.key)))
            && new Set(lines.map(line => line.key)).size === lines.length)) {
        throw Error('The technician work quantities could not be verified.');
      }
      employees.add(row.employee_key);
    }
    return data;
  }

  async function refresh(focusIndex) {
    if (!root || !allowed()) return;
    const canRestoreSortFocus = typeof focusIndex === 'number';
    const scroll = $('#twr-table-wrap').scrollLeft;
    const token = ++epoch;
    report = null;
    exporting = false;
    window.GREENLOOP_REPORT_DOWNLOADS?.close();
    busy = true;
    controls();
    $('#twr-results').hidden = true;
    showStatus('Loading technician work…');
    try {
      const data = await read(offset);
      if (token !== epoch || !root?.isConnected || !allowed()) return;
      if (offset >= data.total && offset > 0) {
        offset = data.total ? Math.floor((data.total - 1) / pageSize) * pageSize : 0;
        return refresh();
      }
      if (sort.key && !data.columns.some(col => col.kind === sort.kind && col.key === sort.key)) {
        sort = defaultSort;
        offset = 0;
        return refresh();
      }
      report = data;
      render(data);
      $('#twr-results').hidden = false;
      $('#twr-table-wrap').scrollLeft = scroll;
      showStatus('');
    } catch (error) {
      if (token === epoch && root?.isConnected) showStatus(error.message || 'Technician work could not be loaded.', true);
    } finally {
      if (token === epoch) {
        busy = false;
        controls();
        if (canRestoreSortFocus && report && can(sortCap)) {
          $(`[data-twr-sort="${focusIndex}"]`)?.focus({preventScroll: true});
        }
      }
    }
  }

  async function output(kind) {
    if (busy || exporting || !report?.total || !allowed() || !can(downloadCap)) return;
    const token = epoch, snapshot = report.snapshot;
    const permitted = () => token === epoch && !!root?.isConnected && allowed() && can(downloadCap);
    exporting = true;
    controls();
    showStatus(kind === 'excel' ? 'Preparing Excel…' : 'Preparing PDF…');
    try {
      const data = await read(0, true, snapshot);
      if (!permitted()) return;
      const partIndices = [], serviceIndices = [];
      data.columns.forEach((col, index) => (col.kind === 'part' ? partIndices : serviceIndices).push(index + 3));
      const headers = ['S.No', ...columnsFor(data).map(col => col.label)];
      const sameLabel = new Set(data.columns.filter(col => col.kind === 'part').map(col => col.label));
      data.columns.forEach((col, i) => {
        if (col.kind === 'service' && sameLabel.has(col.label)) headers[i + 3] += ' (Service)';
      });
      const subtitle = [...new Set([data.from, data.to])].map(day => displayDay.format(new Date(day))).join(' – ') + ' · UAE';
      await window.GREENLOOP_REPORT_DOWNLOADS.output(kind, {
        title: 'Technician Work Report', subtitle, headers,
        rows: data.rows.map((row, i) => values(row, data.columns, i + 1)),
        numericColumns: headers.map((_, i) => i).filter(i => i !== 1),
        wrapWords: true,
        pdfColumnGroups: [
          {label: 'Installed Parts', columns: partIndices},
          {label: 'Completed Services', columns: serviceIndices}
        ]
      }, permitted, 'reports', downloadCap);
      if (permitted()) showStatus('');
    } catch (error) {
      if (permitted()) showStatus(error.message || 'The report could not be downloaded.', true);
    } finally {
      if (token === epoch) {
        exporting = false;
        controls();
      }
    }
  }

  function unmount() {
    epoch++;
    if (root) window.GREENLOOP_REPORT_DOWNLOADS?.close();
    root?.remove();
    root = host = report = range = null;
    busy = exporting = includeZero = false;
    offset = 0;
    sort = defaultSort;
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
      + '<div class="twr-options"><label><input type="checkbox" id="twr-include-zero" data-capability="report_technician_work" data-capability-page="reports"> Show technicians with no work</label>'
      + '<div class="twr-exports">' + ['view','pdf','excel'].map((kind,i) =>
        '<button type="button" class="secondary-button" data-twr-export="' + kind + '" data-capability="' + downloadCap
        + '" data-capability-page="reports" hidden>' + ['PDF View','Download PDF','Download Excel'][i] + '</button>').join('') + '</div></div>'
      + '<p id="twr-status" role="status" hidden></p><div id="twr-results" hidden>'
      + '<div class="report-table-wrap" id="twr-table-wrap" tabindex="0" role="region" aria-label="Technician work table">'
      + '<table class="report-table twr-matrix" id="twr-table" data-preserve-table-layout><thead></thead><tbody id="twr-rows"></tbody></table></div>'
      + '<div class="twr-pager" data-capability="report_technician_work" data-capability-page="reports"><button id="twr-prev" class="secondary-button" type="button">Previous</button>'
      + '<span id="twr-range" role="status"></span><button id="twr-next" class="secondary-button" type="button">Next</button></div></div>';
    target.replaceChildren(root);
    setRange(dateRange('today'));
    $('#twr-from').max = $('#twr-to').max = range[1];
    $('#twr-dates').addEventListener('submit', event => {
      event.preventDefault();
      if (busy || exporting || !dateAccess()) return;
      const from = $('#twr-from').value, to = $('#twr-to').value;
      if (!from || !to || from > to) {
        showStatus('Choose a From date on or before the To date.', true);
        return;
      }
      setRange([from, to]);
      refresh();
    });
    root.querySelectorAll('[data-twr-cut]').forEach(button => button.addEventListener('click', () => {
      if (busy || exporting || !dateAccess()) return;
      setRange(dateRange(button.dataset.twrCut));
      refresh();
    }));
    $('#twr-prev').addEventListener('click', () => { offset -= pageSize; refresh(); });
    $('#twr-next').addEventListener('click', () => { offset += pageSize; refresh(); });
    $('#twr-include-zero').addEventListener('change', event => {
      includeZero = event.target.checked;
      offset = 0;
      refresh();
    });
    $('#twr-table').tHead.addEventListener('click', event => {
      const button = event.target.closest('[data-twr-sort]');
      if (!button || !report || busy || exporting || !can(sortCap)) return;
      const index = Number(button.dataset.twrSort);
      const {kind, key} = columnsFor(report)[index];
      const desc = sort.kind === kind && sort.key === key ? !sort.desc : kind !== 'name';
      sort = {kind, key, desc};
      offset = 0;
      refresh(index);
    });
    root.querySelectorAll('[data-twr-export]').forEach(button => {
      button.addEventListener('click', () => output(button.dataset.twrExport));
    });
    refresh();
  }

  for (const event of ['greenloop:office-locked', 'greenloop:signed-out', 'greenloop:permissions-changed']) {
    window.addEventListener(event, () => {
      if (event !== 'greenloop:permissions-changed' || !allowed()) {
        unmount();
      } else if (root) {
        if (!dateAccess() && (range[0] !== todayUae() || range[1] !== todayUae())) {
          setRange(dateRange('today'));
          refresh();
        } else if (!can(sortCap) && sort !== defaultSort) {
          sort = defaultSort;
          offset = 0;
          refresh();
        } else {
          if (!can(downloadCap)) {
            window.GREENLOOP_REPORT_DOWNLOADS?.close();
            if (exporting) refresh();
          }
          applySortVisibility();
          controls();
        }
      }
    });
  }
  window.GREENLOOP_TECHNICIAN_WORK_REPORT = { mount, unmount, refresh };
})();