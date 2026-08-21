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
  let client;
  let toastTimer;
  let supplierNames = new Map();
  let batchQuantities = new Map();

  function getClient() { if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey); return client; }
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
  function supplierLabel(code, batchNumber) {
    const safeCode = String(code || "").trim();
    const baseCode = safeCode.replace(/-\(\d+\)$/, "");
    const name = supplierNames.get(baseCode);
    const quantity = batchQuantities.get(String(batchNumber || ""));
    if (typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function") return window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(safeCode, quantity, name, "—");
    return safeCode && Number(quantity) > 0 ? `${safeCode}-(${quantity})` : (safeCode || "—");
  }

  async function addDeviceIdentity(rows) {
    const imeis = [...new Set(rows.map((row) => String(row?.imei || "").trim()).filter(Boolean))];
    if (!imeis.length) return rows;
    const { data, error } = await getClient().from("devices")
      .select("imei_1, serial_number, specification_region")
      .in("imei_1", imeis);
    if (error) return rows;
    const identityByImei = new Map((data || []).map((device) => [String(device.imei_1 || ""), device]));
    return rows.map((row) => ({ ...row, ...(identityByImei.get(String(row.imei || "")) || {}) }));
  }

  function render(rows) {
    total.textContent = String(rows.length);
    rangeLabel.textContent = rangeFrom.value && rangeTo.value
      ? `Final QC passed from ${rangeFrom.value} to ${rangeTo.value}. Latest pass appears first.`
      : "All current Ready Stock devices. Latest Final QC pass appears first.";
    body.innerHTML = rows.length
      ? rows.map((row) => `<tr><td>${escapeHtml(formatDateTime(row.stock_received_at))}</td><td>${escapeHtml(supplierLabel(row.supplier_code, row.stock_batch))}</td><td>${escapeHtml(row.stock_channel)}</td><td>${escapeHtml(row.stock_batch)}</td><td class="journey-imei">${escapeHtml(row.imei)}</td><td>${escapeHtml(row.serial_number || "—")}</td><td>${escapeHtml(row.specification_region || "—")}</td><td>${escapeHtml(row.model)}</td><td>${row.storage_gb ? `${escapeHtml(row.storage_gb)} GB` : "—"}</td><td>${escapeHtml(row.color)}</td><td>${escapeHtml(row.supplier_grade)}</td><td>${escapeHtml(row.company_initial_grade)}</td><td>${escapeHtml(row.company_final_qc_grade)}</td><td class="journey-parts">${escapeHtml(row.parts_used)}</td><td class="journey-money">${escapeHtml(formatMoney(row.parts_cost))}</td><td>${escapeHtml(row.work_done)}</td><td>${escapeHtml(row.worked_by)}</td><td>${escapeHtml(row.step_by_step)}</td><td>${escapeHtml(formatDateTime(row.final_qc_passed_at))}</td></tr>`).join("")
      : '<tr><td class="journey-empty" colspan="19">No Final-QC-passed device is waiting in Ready Stock for this date range.</td></tr>';
  }

  async function loadJourney() {
    const refresh = document.querySelector("#refresh-journey");
    refresh.disabled = true;
    refresh.textContent = "Loading...";
    const from = rangeFrom.value || null;
    const to = rangeTo.value || null;
    if ((from && !to) || (!from && to) || (from && to && from > to)) {
      refresh.disabled = false;
      refresh.textContent = "Refresh table";
      throw new Error("Select a valid From date and To date, or clear both dates.");
    }
    const [journeyResponse, supplierResponse, batchResponse] = await Promise.all([
      getClient().rpc("get_ready_stock_journey", { p_date_from: from, p_date_to: to }),
      getClient().from("suppliers").select("supplier_code, company_name"),
      getClient().from("receiving_batches").select("batch_number, planned_quantity")
    ]);
    refresh.disabled = false;
    refresh.textContent = "Refresh table";
    if (journeyResponse.error) throw journeyResponse.error;
    if (supplierResponse.error) throw supplierResponse.error;
    if (batchResponse.error) throw batchResponse.error;
    supplierNames = new Map((supplierResponse.data || []).map((supplier) => [supplier.supplier_code, supplier.company_name]));
    batchQuantities = new Map((batchResponse.data || []).map((batch) => [String(batch.batch_number || ""), batch.planned_quantity]));
    render(await addDeviceIdentity(Array.isArray(journeyResponse.data) ? journeyResponse.data : []));
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canView, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "production", "final_qc", "shop_staff"] });
    if (error) throw error;
    if (!canView) { permissionMessage.textContent = "Your account does not have Ready Stock permission."; permissionMessage.hidden = false; return; }
    app.hidden = false;
    const today = dubaiDate();
    rangeFrom.value = today;
    rangeTo.value = today;
    await loadJourney();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-journey").addEventListener("click", () => loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")));
  document.querySelector("#apply-journey-range").addEventListener("click", () => loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")));
  document.querySelector("#clear-journey-range").addEventListener("click", () => { rangeFrom.value = ""; rangeTo.value = ""; loadJourney().catch((error) => showToast(error.message || "Device journey could not be loaded.")); });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Device journey could not be loaded."; permissionMessage.hidden = false; });
})();
