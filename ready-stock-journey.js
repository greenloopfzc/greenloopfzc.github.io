(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#journey-app");
  const permissionMessage = document.querySelector("#permission-message");
  const total = document.querySelector("#journey-total");
  const body = document.querySelector("#journey-body");
  const rangeFrom = document.querySelector("#journey-from");
  const rangeTo = document.querySelector("#journey-to");
  const rangeLabel = document.querySelector("#journey-range-label");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const cableStatus = document.querySelector("#journey-cable-status");
  const cableImei = document.querySelector("#journey-cable-imei");
  const cableSerial = document.querySelector("#journey-cable-serial");
  const cableRegion = document.querySelector("#journey-cable-region");
  const saveCableDetails = document.querySelector("#save-journey-cable-details");
  let client;
  let toastTimer;
  let connectedDevice = null;
  let savingCableDetails = false;
  let journeyGeneration = 0;
  let offset = 0, rowCount = 0, loading = false, selectedDevice = null, detailGeneration = 0, refreshTimer;
  const pageSize = 50;
  const search = document.querySelector('#journey-search');
  const liveStatus = document.querySelector('#journey-live-status');
  const previous = document.querySelector('#journey-prev'), next = document.querySelector('#journey-next');
  const pageLabel = document.querySelector('#journey-page-label');
  const detail = document.querySelector('#journey-detail'), detailBody = document.querySelector('#journey-detail-body');
  let loadedRows = [];
  const pending = '<span class="journey-pending">Not yet</span>';
  const dateCell = value => value ? escapeHtml(formatDateTime(value)) : pending;

  function getClient() { if (!client) client = window.GREENLOOP_GET_CLIENT(); return client; }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function formatDateTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "—";
    return date.toLocaleString("en-GB", { timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
  }
  function formatMoney(value) {
    const amount = Number(value || 0);
    return Number.isFinite(amount)
      ? amount.toLocaleString("en-AE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
      : "0.00";
  }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200); }


  function render(rows) {
    loadedRows = rows;
    total.textContent = String(rowCount);
    rangeLabel.textContent = rangeFrom.value && rangeTo.value
      ? `IMEI entered from ${rangeFrom.value} to ${rangeTo.value}. All stages included.`
      : "All saved phones, at every stage. Latest IMEI entry first.";
    body.innerHTML = rows.length
      ? rows.map((row) => `<tr><td class="journey-imei">${escapeHtml(row.imei || row.device_number)}<small>${escapeHtml(row.device_number || "")}</small><button type="button" class="secondary-button journey-open" data-device-id="${escapeHtml(row.device_id)}">View journey</button></td><td><span class="journey-current-stage">${escapeHtml(row.current_stage || "Not recorded")}</span></td><td>${dateCell(row.date_entered)}</td><td>${escapeHtml(row.device_details || "—")}</td><td>${escapeHtml(formatDateTime(row.date_received))}</td><td>${dateCell(row.date_completed)}</td><td>${escapeHtml(row.stock_channel)}</td><td>${escapeHtml(row.invoice_number)}</td><td>${escapeHtml(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? row.supplier_company : "Confidential supplier")}</td><td>${escapeHtml(row.quantity_received)}</td><td>${escapeHtml(row.supplier_code)}</td><td>${escapeHtml(row.battery_health || "—")}</td><td>${escapeHtml(row.supplier_grade)}</td><td>${escapeHtml(row.company_initial_grade)}</td><td>${escapeHtml(row.company_final_grade)}</td><td class="journey-parts">${escapeHtml(row.parts_issued)}</td><td class="journey-money">${escapeHtml(formatMoney(row.parts_cost))}</td><td>${escapeHtml(row.service_done)}</td><td>${escapeHtml(row.technician_name)}</td><td>${escapeHtml(row.box_number)}</td><td>${dateCell(row.export_date)}</td><td>${escapeHtml(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? row.customer_name : "Confidential customer")}</td></tr>`).join("")
      : '<tr><td class="journey-empty" colspan="22">No saved phone matches these filters.</td></tr>';
  }

  function applyConnectedDevice(device = {}) {
    const imei = String(device.imei || "").replace(/\D/g, "").slice(0, 15);
    if (!/^\d{15}$/.test(imei)) return;
    connectedDevice = { imei, serialNumber: String(device.serialNumber || "").trim(), phoneRegion: String(device.phoneRegion || "").trim() };
    cableImei.textContent = imei;
    cableSerial.textContent = connectedDevice.serialNumber || "Not read";
    cableRegion.textContent = connectedDevice.phoneRegion || "Not read";
    saveCableDetails.disabled = savingCableDetails || !window.GREENLOOP_PAGE_ACCESS?.canEdit || (!connectedDevice.serialNumber && !connectedDevice.phoneRegion);
    cableStatus.textContent = saveCableDetails.disabled ? "Phone connected, but Serial Number and Region were not provided by the phone." : "Connected phone ready. Save only this phone's Serial Number and Region.";
  }

  function clearConnectedDevice() {
    connectedDevice = null;
    cableImei.textContent = cableSerial.textContent = cableRegion.textContent = "Not read";
    saveCableDetails.disabled = true;
    cableStatus.textContent = "Connect one unlocked phone to read its details.";
  }

  async function saveConnectedDeviceDetails() {
    if (savingCableDetails || !window.GREENLOOP_PAGE_ACCESS?.canEdit) return;
    const live = window.GREENLOOP_GET_CONNECTED_DEVICE?.();
    if (!connectedDevice?.imei || !live || String(live.imei) !== connectedDevice.imei) {
      clearConnectedDevice(); showToast("Connect the phone again before saving."); return;
    }
    const device = { ...connectedDevice };
    savingCableDetails = true;
    saveCableDetails.disabled = true;
    saveCableDetails.textContent = "Saving...";
    try {
      const { error } = await getClient().rpc("save_stock_device_cable_details", {
        p_imei_1: device.imei, p_serial_number: device.serialNumber || null,
        p_specification_region: device.phoneRegion || null
      });
      if (error) throw error;
      if (connectedDevice?.imei === device.imei) cableStatus.textContent = "Saved Serial Number and Region for IMEI " + device.imei + ".";
      showToast("Connected phone details saved for " + device.imei + ".");
      try { await loadJourney(); } catch (_) { showToast("Phone details saved. Refresh the journey table to see the update."); }
    } finally {
      savingCableDetails = false;
      saveCableDetails.textContent = "Save to this IMEI";
      saveCableDetails.disabled = !window.GREENLOOP_PAGE_ACCESS?.canEdit || !connectedDevice || (!connectedDevice.serialNumber && !connectedDevice.phoneRegion);
    }
  }

  function updatePager() {
    previous.disabled = loading || offset === 0;
    next.disabled = loading || offset + loadedRows.length >= rowCount;
    pageLabel.textContent = rowCount ? `${offset + 1}–${offset + loadedRows.length} of ${rowCount} phones` : '0 phones';
  }

  async function loadJourney(quiet = false) {
    const refresh = document.querySelector('#refresh-journey');
    const from = rangeFrom.value || null, to = rangeTo.value || null;
    if ((from && !to) || (!from && to) || (from && to && from > to)) throw new Error('Select a valid From date and To date, or clear both dates.');
    const generation = ++journeyGeneration;
    loading = true;
    refresh.disabled = true;
    if (!quiet) refresh.textContent = 'Loading...';
    updatePager();
    try {
      const {data, error} = await getClient().rpc('get_stock_journey_v1', {p_date_from: from, p_date_to: to, p_query: search.value.trim(), p_offset: offset, p_limit: pageSize});
      if (generation !== journeyGeneration) return;
      if (error) throw error;
      if (!data || !Array.isArray(data.rows) || !Number.isSafeInteger(Number(data.total)) || Number(data.total) < 0) throw new Error('Stock Journey returned an invalid response.');
      rowCount = Number(data.total);
      if (offset && offset >= rowCount) { offset = Math.max(0, Math.floor((rowCount - 1) / pageSize) * pageSize); return await loadJourney(quiet); }
      render(data.rows);
      liveStatus.textContent = `Updated ${formatDateTime(new Date())} · Refreshes every 30 seconds.`;
      liveStatus.removeAttribute('data-error');
      if (detail.open && selectedDevice) await loadDetail(selectedDevice);
    } catch (error) {
      if (generation !== journeyGeneration) return;
      liveStatus.textContent = 'Could not refresh Stock Journey. ' + (error.message || 'Try Refresh table.');
      liveStatus.dataset.error = 'true';
      if (error.code === '42501' || error.code === 'PGRST301') { rowCount = 0; offset = 0; render([]); detail.close(); }
      throw error;
    } finally {
      if (generation === journeyGeneration) { loading = false; refresh.disabled = false; refresh.textContent = 'Refresh table'; updatePager(); }
    }
  }

  function displayValue(value) {
    if (value === null || value === undefined || value === '') return 'Not recorded';
    if (typeof value === 'boolean') return value ? 'Yes' : 'No';
    return typeof value === 'object' ? 'Not recorded' : String(value);
  }

  function renderDetail(data) {
    const device = data.device || {};
    document.querySelector('#journey-detail-title').textContent = device.imei_1 || device.device_number || 'Device history';
    const row = loadedRows.find(item => item.device_id === selectedDevice);
    const current = row?.current_stage || displayValue(device.current_status).replace(/_/g, ' ');
    document.querySelector('#journey-detail-stage').textContent = [device.model, device.storage_gb ? `${device.storage_gb} GB` : '', device.color, `Current stage: ${current}`].filter(Boolean).join(' · ');
    const records = Array.isArray(data.rows) ? data.rows : [];
    detailBody.innerHTML = records.length ? '<ol class="stock-journey-steps">' + records.map(item => {
      const details = (Array.isArray(item.details) ? item.details : []).map(value => `<li><strong>${escapeHtml(value.label)}:</strong> ${escapeHtml(displayValue(value.value))}</li>`);
      details.unshift(`<li><strong>Date & time:</strong> ${escapeHtml(formatDateTime(item.occurred_at))}</li>`);
      details.push(`<li><strong>${item.stage === 'assignment' ? 'Assigned technician' : 'By'}:</strong> ${escapeHtml(item.actor || 'Not recorded')}</li>`);
      if (item.job_number) details.push(`<li><strong>Job:</strong> ${escapeHtml(item.job_number)}</li>`);
      if (item.status) details.push(`<li><strong>Status:</strong> ${escapeHtml(displayValue(item.status).replace(/_/g, ' '))}</li>`);
      for (const part of Array.isArray(item.parts) ? item.parts : []) details.push(`<li><strong>Part:</strong> ${escapeHtml(part.name || 'Not recorded')} · Qty ${escapeHtml(displayValue(part.quantity))}${part.unit_cost != null ? ' · Unit price AED ' + escapeHtml(formatMoney(part.unit_cost)) : ' · Price not recorded'}</li>`);
      if (item.cost != null) details.push(`<li><strong>Recorded cost:</strong> AED ${escapeHtml(formatMoney(item.cost))}</li>`);
      if (item.duration_seconds != null && Number.isFinite(Number(item.duration_seconds))) {
        const seconds = Math.max(0, Math.round(Number(item.duration_seconds)));
        details.push(`<li><strong>${escapeHtml(item.duration_label || 'Duration')}:</strong> ${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m ${seconds % 60}s</li>`);
      }
      return `<li class="stock-journey-step"><h3>${escapeHtml(item.title || 'Recorded step')}</h3><ul>${details.join('')}</ul></li>`;
    }).join('') + '</ol>' : '<p>No recorded steps are available for this phone yet.</p>';
  }

  async function loadDetail(deviceId) {
    const generation = ++detailGeneration;
    try {
      const {data, error} = await getClient().rpc('get_stock_journey_details_v1', {p_device_id: deviceId});
      if (generation !== detailGeneration || selectedDevice !== deviceId || !detail.open) return;
      if (error) throw error;
      if (!data?.found) { detailBody.textContent = 'This phone is no longer available in Stock Journey.'; return; }
      renderDetail(data);
    } catch (error) {
      if (generation === detailGeneration && selectedDevice === deviceId && detail.open) detailBody.textContent = 'Could not load this journey. ' + (error.message || 'Close and try again.');
    }
  }

  function openJourney(deviceId) {
    selectedDevice = deviceId;
    document.querySelector('#journey-detail-title').textContent = 'Device history';
    document.querySelector('#journey-detail-stage').textContent = '';
    detailBody.textContent = 'Loading recorded steps...';
    if (!detail.open) detail.showModal();
    loadDetail(deviceId);
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "ready_stock_journey" || !["view", "edit"].includes(window.GREENLOOP_PAGE_ACCESS?.accessLevel)) return;
    app.hidden = false;
    rangeFrom.value = "";
    rangeTo.value = "";
    await loadJourney();
    refreshTimer = window.setInterval(() => { if (!document.hidden && !loading) loadJourney(true).catch(() => {}); }, 30000);
    const currentDevice = window.GREENLOOP_GET_CONNECTED_DEVICE?.();
    if (currentDevice) applyConnectedDevice(currentDevice);
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-journey").addEventListener("click", () => loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")));
  document.querySelector("#apply-journey-range").addEventListener("click", () => { offset = 0; loadJourney().catch((error) => showToast(error.message)); });
  document.querySelector("#clear-journey-range").addEventListener("click", () => { rangeFrom.value = ""; rangeTo.value = ""; offset = 0; loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")); });
  window.addEventListener("greenloop:device-reader-status", (event) => { if (["offline", "waiting"].includes(event.detail?.state)) clearConnectedDevice(); });
  window.addEventListener("greenloop:device", (event) => applyConnectedDevice(event.detail));
  saveCableDetails.addEventListener("click", () => saveConnectedDeviceDetails().catch((error) => showToast(error.message || "Connected phone details could not be saved.")));
  document.querySelector('#journey-search-form').addEventListener('submit', event => { event.preventDefault(); offset = 0; loadJourney().catch(error => showToast(error.message)); });
  previous.addEventListener('click', () => { offset = Math.max(0, offset - pageSize); loadJourney().catch(error => showToast(error.message)); });
  next.addEventListener('click', () => { offset += pageSize; loadJourney().catch(error => showToast(error.message)); });
  body.addEventListener('click', event => { const button = event.target.closest('[data-device-id]'); if (button) openJourney(button.dataset.deviceId); });
  document.querySelector('#journey-detail-close').addEventListener('click', () => detail.close());
  detail.addEventListener('close', () => { selectedDevice = null; detailGeneration++; detailBody.replaceChildren(); });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && !app.hidden && !loading) loadJourney(true).catch(() => {}); });
  window.addEventListener('pagehide', () => window.clearInterval(refreshTimer));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Device journey could not be loaded."; permissionMessage.hidden = false; });
})();
