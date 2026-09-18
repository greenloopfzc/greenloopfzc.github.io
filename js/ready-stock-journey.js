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

  function getClient() { if (!client) client = window.GREENLOOP_GET_CLIENT(); return client; }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function dubaiDate() {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dubai", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
    const value = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
    return `${value.year}-${value.month}-${value.day}`;
  }
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
    total.textContent = String(rows.length);
    rangeLabel.textContent = rangeFrom.value && rangeTo.value
      ? `Final QC passed from ${rangeFrom.value} to ${rangeTo.value}. Latest pass appears first.`
      : "All current Ready Stock devices. Latest Final QC pass appears first.";
    body.innerHTML = rows.length
      ? rows.map((row) => `<tr><td class="journey-imei">${escapeHtml(row.imei)}</td><td>${escapeHtml(row.device_details || "—")}</td><td>${escapeHtml(formatDateTime(row.date_received))}</td><td>${escapeHtml(formatDateTime(row.date_completed))}</td><td>${escapeHtml(row.stock_channel)}</td><td>${escapeHtml(row.invoice_number)}</td><td>${escapeHtml(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? row.supplier_company : "Confidential supplier")}</td><td>${escapeHtml(row.quantity_received)}</td><td>${escapeHtml(row.supplier_code)}</td><td>${escapeHtml(row.battery_health || "—")}</td><td>${escapeHtml(row.supplier_grade)}</td><td>${escapeHtml(row.company_initial_grade)}</td><td>${escapeHtml(row.company_final_grade)}</td><td class="journey-parts">${escapeHtml(row.parts_issued)}</td><td class="journey-money">${escapeHtml(formatMoney(row.parts_cost))}</td><td>${escapeHtml(row.service_done)}</td><td>${escapeHtml(row.technician_name)}</td><td>${escapeHtml(row.box_number)}</td><td>${escapeHtml(formatDateTime(row.export_date))}</td><td>${escapeHtml(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? row.customer_name : "Confidential customer")}</td></tr>`).join("")
      : '<tr><td class="journey-empty" colspan="20">No completed device is available for this date range.</td></tr>';
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

  async function loadJourney() {
    const refresh = document.querySelector("#refresh-journey");
    const from = rangeFrom.value || null, to = rangeTo.value || null;
    if ((from && !to) || (!from && to) || (from && to && from > to)) throw new Error("Select a valid From date and To date, or clear both dates.");
    const generation = ++journeyGeneration;
    refresh.disabled = true;
    refresh.textContent = "Loading...";
    try {
      const { data, error } = await getClient().rpc("get_ready_stock_journey", { p_date_from: from, p_date_to: to });
      if (generation !== journeyGeneration) return;
      if (error) throw error;
      render(Array.isArray(data) ? data : []);
      rangeLabel.textContent = from && to ? "Final QC passed from " + from + " to " + to + ". Latest pass appears first." : "All completed devices, including exported phones. Latest Final QC pass appears first.";
    } finally {
      if (generation === journeyGeneration) { refresh.disabled = false; refresh.textContent = "Refresh table"; }
    }
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canView, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "production", "final_qc", "shop_staff"] });
    if (error) throw error;
    if (!canView) { permissionMessage.textContent = "Your account does not have Ready Stock permission."; permissionMessage.hidden = false; return; }
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "ready_stock_journey") return;
    app.hidden = false;
    const today = dubaiDate();
    rangeFrom.value = today;
    rangeTo.value = today;
    await loadJourney();
    const currentDevice = window.GREENLOOP_GET_CONNECTED_DEVICE?.();
    if (currentDevice) applyConnectedDevice(currentDevice);
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-journey").addEventListener("click", () => loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")));
  document.querySelector("#apply-journey-range").addEventListener("click", () => loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")));
  document.querySelector("#clear-journey-range").addEventListener("click", () => { rangeFrom.value = ""; rangeTo.value = ""; loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")); });
  window.addEventListener("greenloop:device-reader-status", (event) => { if (["offline", "waiting"].includes(event.detail?.state)) clearConnectedDevice(); });
  window.addEventListener("greenloop:device", (event) => applyConnectedDevice(event.detail));
  saveCableDetails.addEventListener("click", () => saveConnectedDeviceDetails().catch((error) => showToast(error.message || "Connected phone details could not be saved.")));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Device journey could not be loaded."; permissionMessage.hidden = false; });
})();
