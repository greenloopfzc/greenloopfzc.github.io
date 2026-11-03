(() => {
  'use strict';
  if (location.hash.toLowerCase() === '#frame') return;
  const card = document.querySelector('#lab-total-pending');
  if (!card) return;
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const list = value => Array.isArray(value) ? value : [];
  const can = capability => window.GREENLOOP_CAN?.(capability, 'lab_glass') === true;
  let ticket = 0, rows = [], serverNow = NaN, loadedAt = 0, completing = false;
  const pendingTransfers = new Map();
  const context = () => window.GREENLOOP_LAB_PENDING_CONTEXT;
  const canComplete = () => can('entry') && window.GREENLOOP_PAGE_ACCESS?.pageKey === 'lab_glass' && window.GREENLOOP_PAGE_ACCESS.canEdit === true && !!context();
  const dialog = document.createElement('dialog');
  dialog.id = 'lab-pending-overview';
  dialog.setAttribute('aria-labelledby', 'lpo-title');
  dialog.innerHTML = `<header class="lpo-head"><div><p>LAB &amp; GLASS</p><h2 id="lpo-title">All pending phones</h2></div><div><button type="button" data-lpo-refresh data-capability="view" data-capability-page="lab_glass">Refresh</button><button type="button" data-lpo-close data-capability="view" data-capability-page="lab_glass" autofocus>Close</button></div></header>
    <div class="lpo-filters"><label>Scan IMEI / Find phone or part<input type="search" data-lpo-search data-imei-scan data-capability="search" data-capability-page="lab_glass" placeholder="Scan IMEI, model, color, supplier code or part" autocomplete="off"></label><label>Technician<select data-lpo-tech data-capability="search" data-capability-page="lab_glass"><option value="">All technicians</option></select></label><label>Status<select data-lpo-status data-capability="search" data-capability-page="lab_glass"><option value="">All statuses</option></select></label><button type="button" data-lpo-clear data-capability="search" data-capability-page="lab_glass">Show all</button></div>
    <p class="lpo-message" data-lpo-message role="status" aria-live="polite"></p>
    <div class="lpo-scroll" tabindex="0" role="region" aria-label="Pending phone details"><table><thead><tr><th>Technician</th><th>IMEI / Department</th><th>Model / GB / Color / BH</th><th>Supplier code / Stock</th><th>Required parts</th><th>Lab &amp; Glass services</th><th>Status</th><th>Time pending</th><th>Final QC</th></tr></thead><tbody data-lpo-rows></tbody></table></div>
    <footer data-lpo-totals aria-live="polite"></footer>`;
  document.body.append(dialog);
  const el = selector => dialog.querySelector(selector);
  const search = el('[data-lpo-search]'), tech = el('[data-lpo-tech]'), status = el('[data-lpo-status]');
  const body = el('[data-lpo-rows]'), message = el('[data-lpo-message]'), totals = el('[data-lpo-totals]');
  const refresh = el('[data-lpo-refresh]');
  const phoneKey = row => row.device_id || row.imei || row.job_id || row.step_id;
  const uniquePhones = values => new Set(values.map(phoneKey)).size;
  const quantity = n => Math.max(0, Number(n) || 0);
  function collapsePhones(input) {
    const groups = new Map();
    for (const row of input) { const key = phoneKey(row); if (!groups.has(key)) groups.set(key, []); groups.get(key).push(row); }
    return [...groups.values()].map(group => {
      const first = group[0], plans = group.map(r => r.pf_plan);
      const unique = (items, key) => [...new Map(items.map(item => [key(item), item])).values()];
      const employees = [...new Map(group.map(r => [r.overview_employee_id, {id:r.overview_employee_id, name:r.employee_name}])).values()];
      return {...first,
        employee_name: employees.map(t => t.name).join(' / '), overview_employees: employees,
        overview_employee_ids: employees.map(t => t.id), overview_step_ids: group.map(r => String(r.step_id)),
        department: new Set(group.map(r => r.department)).size > 1 ? 'both' : first.department,
        lab_entered_at: group.map(r => r.lab_entered_at).filter(d => Number.isFinite(Date.parse(d))).sort((a,b) => Date.parse(a)-Date.parse(b))[0],
        pf_plan: plans.every(Boolean) ? {...plans[0],
          submitted: plans.every(p => p.submitted || !list(p.parts).length),
          services_saved: plans.every(p => p.services_saved || !list(p.services).length),
          parts: unique(plans.flatMap(p => list(p.parts)), p => p.request_id || JSON.stringify([p.name,p.quantity,p.issued])),
          services: unique(plans.flatMap(p => list(p.services)), p => p.name),
          returns: unique(plans.flatMap(p => list(p.returns)), p => p.id || p.return_id || JSON.stringify(p))
        } : null
      };
    });
  }
  function state(row) {
    const p = row.pf_plan;
    if (row.unassigned) return 'Awaiting employee assignment';
    if (!p) return 'Status unavailable';
    if (list(p.returns).some(r => r.status === 'pending')) return 'Return pending';
    if (list(p.parts).length && !p.submitted) return 'Preparing parts list';
    if (list(p.parts).some(r => quantity(r.issued) < quantity(r.quantity))) return 'Waiting for Parts';
    if (!p.services_saved && list(p.services).length) return 'Services not saved';
    if (!p.submitted && !list(p.parts).length) return 'No parts required';
    return 'Ready to complete';
  }
  function age(row) {
    const now = serverNow + Math.max(0, performance.now() - loadedAt);
    const start = [row.lab_entered_at, row.technician_assigned_at, row.line_created_at]
      .map(Date.parse).find(n => Number.isFinite(n) && n <= now);
    if (!Number.isFinite(start) || !Number.isFinite(now)) return 'Time not recorded';
    const min = Math.floor((now - start) / 60000);
    return min < 1 ? 'Less than 1 min' : [Math.floor(min / 1440) ? `${Math.floor(min / 1440)}d` : '', Math.floor(min % 1440 / 60) ? `${Math.floor(min % 1440 / 60)}h` : '', min % 60 ? `${min % 60}m` : ''].filter(Boolean).join(' ');
  }
  function parts(row) {
    if (!row.pf_plan) return '<span>Parts data unavailable</span>';
    return list(row.pf_plan.parts).map(p => `<span>${esc(p.name)} × ${esc(p.quantity)}<small>${quantity(p.issued) >= quantity(p.quantity) ? 'Issued' : `${Math.max(0, quantity(p.quantity) - quantity(p.issued))} awaiting issue`}</small></span>`).join('') || '<span>No active parts</span>';
  }
  function services(row) {
    if (!row.pf_plan) return '<span>Services data unavailable</span>';
    return list(row.pf_plan.services).filter(s => s.required !== false).map(s => `<span>${esc(s.name)}</span>`).join('') || '<span>None</span>';
  }
  function render() {
    const query = can('search') ? search.value.trim().toLowerCase() : '';
    const visible = rows.filter(r => (!can('search') || (!tech.value || r.overview_employee_ids.includes(tech.value)) && (!status.value || state(r) === status.value)) && (!query || [r.imei, r.employee_name, r.model, r.storage_gb, r.color, r.supplier_code, r.invoice_number, r.batch_number, ...list(r.pf_plan?.parts).map(p => p.name)].join(' ').toLowerCase().includes(query)));
    body.innerHTML = visible.length ? visible.map(r => `<tr data-lpo-step="${esc(r.step_id)}"><td><strong>${esc(r.employee_name)}</strong></td><td><bdi>${esc(r.imei || '—')}</bdi><small>${r.department === 'both' ? 'Lab &amp; Glass' : r.department === 'glass' ? 'Glass' : 'Laboratory'}</small></td><td><strong>${esc(r.model || '—')}</strong><small>${esc(r.storage_gb == null ? '—' : `${r.storage_gb} GB`)} · ${esc(r.color || '—')} · BH ${esc(r.battery_health == null ? '—' : `${r.battery_health}%`)}</small></td><td>${esc(r.supplier_code || '—')}<small>${esc(r.invoice_number || '—')}<br>${esc(r.batch_number || '—')}</small></td><td class="lpo-list">${parts(r)}</td><td class="lpo-list">${services(r)}</td><td>${esc(state(r))}</td><td>${esc(age(r))}</td><td><button type="button" data-lpo-complete="${esc(r.step_id)}" data-capability="entry" data-capability-page="lab_glass" ${!canComplete() || completing || (!pendingTransfers.has(String(r.step_id)) && state(r) !== 'Ready to complete' && state(r) !== 'No parts required') ? 'disabled' : ''}>${pendingTransfers.has(String(r.step_id)) ? 'Confirm transfer' : 'Complete → Final QC'}</button></td></tr>`).join('') : '<tr><td colspan="9" class="lpo-empty">No pending phones match these filters.</td></tr>';
    totals.textContent = `${uniquePhones(visible)} of ${uniquePhones(rows)} pending phones · ${visible.length} work lines · ${new Set(visible.flatMap(r => r.overview_employee_ids)).size} technicians`;
  }
  function options(select, values, placeholder) {
    const previous = select.value;
    select.innerHTML = `<option value="">${placeholder}</option>` + [...values].map(([key, label]) => `<option value="${esc(key)}">${esc(label)}</option>`).join('');
    if ([...select.options].some(o => o.value === previous)) select.value = previous;
  }
  async function read(name, args = {}) {
    let timer;
    try {
      const result = await Promise.race([window.GREENLOOP_GET_CLIENT().rpc(name, args), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Pending phones took too long to load. Check the connection and refresh.')), 12000); })]);
      if (result.error) throw result.error;
      return result.data;
    } finally { clearTimeout(timer); }
  }
  async function load() {
    if (completing) return;
    const request = ++ticket;
    rows = []; body.replaceChildren(); totals.textContent = '';
    message.textContent = 'Loading all technicians’ pending phones…';
    dialog.setAttribute('aria-busy', 'true'); refresh.disabled = true;
    try {
      if (!can('view')) throw new Error('Lab & Glass access is required.');
      const board = await read('get_lab_employee_board_v1');
      if (!Array.isArray(board)) throw new Error('The technician list could not be verified.');
      const employees = board.filter(t => quantity(t.pending_count) > 0), batches = new Array(employees.length);
      let next = 0;
      // Bound simultaneous reads; existing permission-checked APIs include unassigned phones.
      const worker = async () => {
        while (request === ticket && next < employees.length) {
          const i = next++, employee = employees[i];
          const data = await read('get_ranked_lab_workbench_v1', {p_employee_id: employee.unassigned ? null : employee.id, p_imei: null});
          if (!data || !Array.isArray(data.rows) || !Number.isFinite(Date.parse(data.server_now))) throw new Error('Pending phone details could not be verified.');
          batches[i] = {now: Date.parse(data.server_now), rows: data.rows.filter(r => ['laboratory', 'glass'].includes(r.department)).map(r => ({...r, overview_employee_id: String(employee.id), employee_name: employee.full_name || 'Unassigned', unassigned: !!employee.unassigned}))};
        }
      };
      const outcomes = await Promise.allSettled(Array.from({length: Math.min(3, employees.length)}, worker));
      const failure = outcomes.find(r => r.status === 'rejected');
      if (failure) throw failure.reason;
      if (request !== ticket || !dialog.open) return;
      const seen = new Set();
      rows = collapsePhones(batches.flatMap(b => b.rows).filter(r => r.step_id && !seen.has(String(r.step_id)) && seen.add(String(r.step_id))));
      serverNow = batches.length ? Math.max(...batches.map(b => b.now)) : NaN; loadedAt = performance.now();
      options(tech, new Map(rows.flatMap(r => r.overview_employees.map(t => [t.id, t.name]))), 'All technicians');
      options(status, new Map([...new Set(rows.map(state))].sort().map(s => [s, s])), 'All statuses');
      const boardCount = employees.reduce((sum, t) => sum + quantity(t.pending_count), 0);
      message.textContent = boardCount !== uniquePhones(rows) ? 'Assignments changed during loading. Refresh to check the latest pending count.' : 'Scan an IMEI to find its line. Complete sends that phone to Final QC after checking its parts and services.';
      render();
    } catch (error) {
      if (request !== ticket || !dialog.open) return;
      rows = []; body.replaceChildren(); totals.textContent = '';
      message.textContent = error.message || 'Pending phones could not be loaded. Refresh to try again.';
    } finally {
      if (request === ticket) { dialog.removeAttribute('aria-busy'); refresh.disabled = !can('view'); }
    }
  }
  async function complete(stepId) {
    const row = rows.find(r => String(r.step_id) === stepId);
    if (completing || !row || !canComplete()) return;
    if (context().hasDrafts()) { message.textContent = 'Save or discard unsaved workbench changes before completing a phone.'; return; }
    completing = true; refresh.disabled = true; el('[data-lpo-close]').disabled = true;
    render(); message.textContent = `Checking ${row.imei} before transfer…`;
    try {
      let command = pendingTransfers.get(stepId);
      if (!command) {
        const phone = await read('lookup_lab_bulk_phone_v1', {p_imei: row.imei});
        if (!phone || !Array.isArray(phone.reasons) || typeof phone.ready !== 'boolean' || phone.imei !== row.imei) throw new Error('Phone details could not be confirmed. Refresh and try again.');
        if (!phone.ready) throw new Error(phone.reasons.join(' ') || 'This phone is not ready for Final QC.');
        if (!row.overview_step_ids.includes(String(phone.step_id)) || typeof phone.selection_token !== 'string') throw new Error('This phone’s assignment changed. Refresh before completing it.');
        command = {p_request_id: crypto.randomUUID(), p_items: [{imei: row.imei, step_id: phone.step_id, selection_token: phone.selection_token}]};
        pendingTransfers.set(stepId, command);
      }
      message.textContent = `Sending ${row.imei} to Final QC…`;
      // Use the installed idempotent handover API for one phone; never create a new key on a lost reply.
      const response = await window.GREENLOOP_GET_CLIENT().rpc('transfer_lab_bulk_to_final_qc_v1', command);
      if (response.error) {
        if (/^[0-9A-Z]{5}$/.test(response.error.code || '') && !/^PGRST/.test(response.error.code) && !['55P03','57014','40003'].includes(response.error.code)) pendingTransfers.delete(stepId);
        throw response.error;
      }
      const result = response.data;
      if (!result || result.transfer_id !== command.p_request_id || result.status !== 'final_qc_pending' || result.transferred_count !== 1 || !Array.isArray(result.imeis) || result.imeis.length !== 1 || result.imeis[0] !== row.imei) throw new Error('Transfer result could not be verified. Use Confirm transfer to check the same request.');
      pendingTransfers.delete(stepId);
      rows = rows.filter(r => phoneKey(r) !== phoneKey(row));
      document.dispatchEvent(new CustomEvent('greenloop:notifications-changed'));
      try { await context().onTransferred(); message.textContent = `${row.imei} completed and sent to Final QC.`; }
      catch { message.textContent = `${row.imei} was sent to Final QC. Refresh the workbench to update its cards.`; }
    } catch (error) {
      message.textContent = (error.message || 'The phone could not be transferred.') + (pendingTransfers.has(stepId) ? ' Use Confirm transfer to check the same request.' : ' Refresh to check its current status.');
    } finally { completing = false; refresh.disabled = !can('view'); el('[data-lpo-close]').disabled = false; render(); }
  }
  function open() {
    if (!can('view') || dialog.open) return;
    search.value = ''; tech.value = ''; status.value = '';
    dialog.showModal(); void load();
  }
  card.setAttribute('role', 'button'); card.tabIndex = 0;
  card.removeAttribute('aria-live'); card.removeAttribute('aria-atomic');
  card.setAttribute('aria-haspopup', 'dialog'); card.setAttribute('aria-controls', dialog.id);
  card.dataset.capability = 'view'; card.dataset.capabilityPage = 'lab_glass';
  document.querySelector('#lab-total-pending-count')?.setAttribute('aria-live', 'polite');
  card.addEventListener('click', open);
  card.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  el('[data-lpo-close]').addEventListener('click', () => { if (!completing) dialog.close(); });
  dialog.addEventListener('cancel', event => { if (completing) event.preventDefault(); });
  refresh.addEventListener('click', () => { if (can('view')) void load(); });
  dialog.addEventListener('close', () => { ticket++; rows = []; body.replaceChildren(); totals.textContent = ''; dialog.removeAttribute('aria-busy'); card.focus(); });
  for (const control of [search, tech, status]) control.addEventListener(control === search ? 'input' : 'change', render);
  body.addEventListener('click', event => { const button = event.target.closest('[data-lpo-complete]'); if (button && !button.disabled) void complete(button.dataset.lpoComplete); });
  el('[data-lpo-clear]').addEventListener('click', () => { if (!can('search')) return; search.value = ''; tech.value = ''; status.value = ''; render(); search.focus(); });
  search.addEventListener('greenloop:imei-input-scan', event => { if (!can('search')) return; search.value = event.detail.imei; tech.value = ''; status.value = ''; render(); });
  search.addEventListener('keydown', event => { if (event.key !== 'Enter') return; event.preventDefault(); if (/^\d{15}$/.test(search.value.trim())) { tech.value = ''; status.value = ''; render(); search.select(); } });
})();
