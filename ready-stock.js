(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#ready-stock-app");
  const permissionMessage = document.querySelector("#permission-message");
  const total = document.querySelector("#ready-stock-total");
  const tableHead = document.querySelector("#ready-stock-head");
  const tableBody = document.querySelector("#ready-stock-body");
  const tableFoot = document.querySelector("#ready-stock-foot");
  const rangeFrom = document.querySelector("#ready-stock-from");
  const rangeTo = document.querySelector("#ready-stock-to");
  const rangeLabel = document.querySelector("#ready-stock-range-label");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const reworkForm = document.querySelector("#ready-stock-rework-form");
  const reworkImei = document.querySelector("#ready-stock-rework-imei");
  const reworkDepartment = document.querySelector("#ready-stock-rework-department");
  const reworkReason = document.querySelector("#ready-stock-rework-reason");
  const reworkTechnician = document.querySelector("#ready-stock-rework-technician");
  const reworkTechnicianWrap = document.querySelector("#ready-stock-rework-technician-wrap");
  const reworkSubmit = document.querySelector("#ready-stock-rework-submit");
  const stockView = document.querySelector("#ready-stock-view");
  const reworkView = document.querySelector("#ready-stock-rework-view");
  const pageTitle = document.querySelector("#ready-stock-title");
  const pageSubtitle = document.querySelector("#ready-stock-subtitle");
  const stockSubtitle = pageSubtitle.textContent;
  const singleModeButton = document.querySelector("#ready-rework-single-mode");
  const bulkModeButton = document.querySelector("#ready-rework-bulk-mode");
  const bulkInput = document.querySelector("#ready-rework-imeis");
  const bulkCount = document.querySelector("#ready-rework-count");
  const bulkResults = document.querySelector("#ready-rework-results");
  const bulkRows = document.querySelector("#ready-rework-result-rows");
  const bulkProgress = document.querySelector("#ready-rework-progress");
  const bulkNote = document.querySelector("#ready-rework-result-note");
  const bulkStop = document.querySelector("#ready-rework-stop");
  const maxBulkPhones = 500;
  let reworkMode = "single";
  let bulkDraft = { rows: [], phones: [], tooLarge: false };
  let bulkBatch = null;
  let stopRequested = false;
  let techniciansAvailable = false;
  const unconfirmedImeis = new Set();
  let unconfirmedStorageKey;
  let client;
  let toastTimer;
  let sendingForRework = false;
  let readyGeneration = 0;

  function getClient() {
    if (!client) client = window.GREENLOOP_GET_CLIENT();
    return client;
  }

  function showReadyStockView(moveFocus = false) {
    if (app.hidden) return;
    const isRework = window.location.hash === "#rework";
    stockView.hidden = isRework;
    reworkView.hidden = !isRework;
    document.querySelector("#open-ready-stock-rework").hidden = isRework;
    document.querySelector("#back-to-ready-stock").hidden = !isRework;
    document.querySelector("#ready-stock-table-actions").hidden = isRework;
    const stockScanner = document.querySelector("#greenloop-quick-imei-scanner");
    if (stockScanner) stockScanner.hidden = isRework;
    pageTitle.textContent = isRework ? "Send for rework" : "Final QC passed stock";
    pageSubtitle.textContent = isRework ? "Send one or more Ready Stock phones to Laboratory or Frame Department for further work." : stockSubtitle;
    document.querySelector("#ready-stock-breadcrumb").textContent = isRework ? "Send for rework" : "Ready Stock";
    document.title = isRework ? "Send for rework | Greenloop" : "Ready Stock | Greenloop";
    if (moveFocus) {
      window.scrollTo({ top: 0, behavior: "auto" });
      (isRework ? (reworkMode === "bulk" ? bulkInput : reworkImei) : pageTitle).focus({ preventScroll: true });
    }
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function normalize(value) {
    return String(value || "").trim().replace(/\s+/g, " ").toLocaleLowerCase("en");
  }

  function dubaiDate() {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Dubai", year: "numeric", month: "2-digit", day: "2-digit"
    }).formatToParts(new Date());
    const value = Object.fromEntries(parts.map(({ type, value: partValue }) => [type, partValue]));
    return `${value.year}-${value.month}-${value.day}`;
  }

  function formatDateTime(value) {
    if (!value) return "-";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "-";
    return date.toLocaleString("en-GB", {
      timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric",
      hour: "2-digit", minute: "2-digit"
    });
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function showToast(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3200);
  }

  function buildGradeList(data, rows) {
    const labels = new Map();
    (data?.grade_options || []).forEach((grade) => {
      const label = String(grade || "").trim();
      if (label) labels.set(normalize(label), label);
    });
    rows.forEach((row) => {
      const label = String(row.final_grade || "Unspecified").trim() || "Unspecified";
      if (!labels.has(normalize(label))) labels.set(normalize(label), label);
    });
    return [...labels.entries()].map(([key, label]) => ({ key, label }));
  }

  function pivotRows(rows, grades) {
    const models = new Map();
    rows.forEach((row) => {
      const quantity = Number(row.quantity || 0);
      const model = String(row.model || "Unknown model").trim() || "Unknown model";
      if (!models.has(model)) models.set(model, { model, grades: new Map(), total: 0, latest: null });
      const target = models.get(model);
      const gradeKey = normalize(row.final_grade || "Unspecified");
      target.grades.set(gradeKey, Number(target.grades.get(gradeKey) || 0) + quantity);
      target.total += quantity;
      if (!target.latest || String(row.latest_passed_at || "") > String(target.latest || "")) target.latest = row.latest_passed_at;
    });

    return [...models.values()].sort((a, b) => a.model.localeCompare(b.model, undefined, { numeric: true }));
  }

  function render(data) {
    const flatRows = Array.isArray(data?.rows) ? data.rows : [];
    const grades = buildGradeList(data, flatRows);
    const rows = pivotRows(flatRows, grades);
    const gradeTotals = new Map(grades.map((grade) => [grade.key, 0]));
    rows.forEach((row) => {
      grades.forEach((grade) => gradeTotals.set(grade.key, Number(gradeTotals.get(grade.key) || 0) + Number(row.grades.get(grade.key) || 0)));
    });

    total.textContent = `${Number(data?.total_qty || 0)} pcs`;
    rangeLabel.textContent = data?.date_from && data?.date_to
      ? `Current Ready Stock passed Final QC from ${data.date_from} to ${data.date_to}`
      : "Final-QC-passed devices still held by Greenloop";
    tableHead.innerHTML = `<tr><th>Model</th>${grades.map((grade) => `<th>${escapeHtml(grade.label)}</th>`).join("")}<th>Latest Final QC pass</th><th>Total Qty</th></tr>`;
    tableBody.innerHTML = rows.length
      ? rows.map((row) => `<tr><td>${escapeHtml(row.model)}</td>${grades.map((grade) => `<td>${escapeHtml(row.grades.get(grade.key) || 0)}</td>`).join("")}<td>${escapeHtml(formatDateTime(row.latest))}</td><td>${escapeHtml(row.total || 0)}</td></tr>`).join("")
      : `<tr><td class="ready-stock-empty" colspan="${grades.length + 3}">No Final-QC-passed stock is waiting in Ready Stock.</td></tr>`;
    tableFoot.innerHTML = `<tr><th>Total</th>${grades.map((grade) => `<th>${escapeHtml(gradeTotals.get(grade.key) || 0)}</th>`).join("")}<th>-</th><th>${escapeHtml(Number(data?.total_qty || 0))} pcs</th></tr>`;
  }

  async function loadReadyStock() {
    const refresh = document.querySelector("#refresh-ready-stock");
    refresh.disabled = true;
    refresh.textContent = "Loading...";
    const from = rangeFrom.value || null;
    const to = rangeTo.value || null;
    if ((from && !to) || (!from && to) || (from && to && from > to)) {
      refresh.disabled = false;
      refresh.textContent = "Refresh table";
      throw new Error("Select a valid From date and To date, or clear both dates.");
    }
    const generation = ++readyGeneration;
    try {
    const { data, error } = await getClient().rpc("get_ready_stock_final_grade_table", {
      p_date_from: from,
      p_date_to: to
    });
    if (generation !== readyGeneration) return;
    if (error) throw error;
    render(Array.isArray(data) ? data[0] : data);
    } finally { if (generation === readyGeneration) { refresh.disabled = false; refresh.textContent = "Refresh table"; } }
  }

  function renderUnconfirmedPhones() {
    document.querySelector("#ready-rework-unconfirmed").hidden = !unconfirmedImeis.size;
    document.querySelector("#ready-rework-unconfirmed-list").innerHTML = [...unconfirmedImeis].map((imei) => `<li><strong>${imei}</strong><a class="secondary-button" href="imei-search.html?q=${imei}">View device history</a><button class="secondary-button" type="button" data-checked-imei="${imei}" ${sendingForRework ? "disabled" : ""}>History checked — allow retry</button></li>`).join("");
    try { if (unconfirmedStorageKey) sessionStorage.setItem(unconfirmedStorageKey, JSON.stringify([...unconfirmedImeis])); } catch (_) { /* The visible list still protects this open page. */ }
  }

  function unconfirmedResult(imei) {
    unconfirmedImeis.add(imei);
    renderUnconfirmedPhones();
    return { state: "unknown", detail: "Not confirmed. Check the device history before allowing a retry." };
  }

  function parseBulkImeis(text) {
    if (text.length > 50000) return { rows: [], phones: [], tooLarge: true };
    const seen = new Set();
    const phones = [];
    const rows = text.trim().split(/[\s,;]+/).filter(Boolean).map((value) => {
      if (!/^\d{15}$/.test(value)) return { imei: value, state: "invalid", detail: "Enter exactly 15 digits." };
      if (seen.has(value)) return { imei: value, state: "duplicate", detail: "Duplicate IMEI — counted once." };
      seen.add(value);
      if (unconfirmedImeis.has(value)) return { imei: value, state: "unknown", detail: "Check this phone in the Check before retrying list first." };
      const row = { imei: value, state: "pending", detail: "Ready to send. Stock eligibility is checked when sending." };
      phones.push(row);
      return row;
    });
    return { rows, phones, tooLarge: phones.length > maxBulkPhones || rows.length > 1500 };
  }

  const bulkStateLabels = { pending: "Pending", sending: "Sending", sent: "Sent", failed: "Failed", unknown: "Not confirmed", "not-sent": "Not sent", invalid: "Invalid", duplicate: "Duplicate" };

  function renderBulkRows(rows) {
    bulkRows.innerHTML = rows.map((row) => `<tr><td>${escapeHtml(row.imei.length > 80 ? row.imei.slice(0, 80) + "…" : row.imei)}</td><td><span class="ready-rework-status" data-state="${row.state}">${bulkStateLabels[row.state]}</span></td><td>${escapeHtml(row.detail)}</td></tr>`).join("");
  }

  function updateBatchProgress() {
    const count = (state) => bulkBatch.phones.filter((row) => row.state === state).length;
    bulkProgress.textContent = `${count("sent")} sent · ${count("failed")} failed · ${count("unknown")} not confirmed · ${count("pending") + count("sending") + count("not-sent")} remaining`;
  }

  function updateBulkDraft(showList = true) {
    bulkDraft = parseBulkImeis(bulkInput.value);
    const duplicates = bulkDraft.rows.filter((row) => row.state === "duplicate").length;
    const invalid = bulkDraft.rows.filter((row) => row.state === "invalid").length;
    const unconfirmed = bulkDraft.rows.filter((row) => row.state === "unknown").length;
    bulkCount.textContent = bulkDraft.tooLarge ? `Use batches of up to ${maxBulkPhones} phones; reduce the pasted list.` : `${bulkDraft.phones.length} phones · ${duplicates} duplicates · ${invalid} invalid${unconfirmed ? ` · ${unconfirmed} awaiting status check` : ""}`;
    if (showList) {
      bulkBatch = null;
      bulkNote.hidden = true;
      document.querySelector("#ready-rework-results-title").textContent = "Phone list";
      bulkProgress.textContent = bulkDraft.tooLarge ? "Reduce the list before sending." : "Duplicates and invalid entries will not be sent.";
      renderBulkRows(bulkDraft.tooLarge ? [] : bulkDraft.rows);
    }
    bulkResults.hidden = reworkMode !== "bulk" || (!bulkDraft.rows.length && !bulkBatch && !bulkDraft.tooLarge);
    syncReworkControls();
  }

  function syncReworkControls() {
    const isBulk = reworkMode === "bulk";
    document.querySelector("#ready-rework-single-field").hidden = isBulk;
    document.querySelector("#ready-rework-bulk-field").hidden = !isBulk;
    singleModeButton.setAttribute("aria-pressed", String(!isBulk));
    bulkModeButton.setAttribute("aria-pressed", String(isBulk));
    reworkForm.querySelectorAll("input,textarea,select,button").forEach((control) => { control.disabled = sendingForRework; });
    reworkImei.disabled = sendingForRework || isBulk;
    reworkImei.required = !isBulk;
    bulkInput.disabled = sendingForRework || !isBulk;
    bulkInput.required = isBulk;
    reworkTechnician.disabled = sendingForRework || !techniciansAvailable;
    reworkSubmit.disabled = sendingForRework || (isBulk && (bulkDraft.tooLarge || !bulkDraft.phones.length));
    reworkSubmit.textContent = sendingForRework ? "Sending..." : isBulk ? `Send ${bulkDraft.phones.length} phones for rework` : "Send for rework";
    bulkStop.hidden = !sendingForRework || !isBulk;
    bulkStop.disabled = stopRequested;
    bulkStop.textContent = stopRequested ? "Stopping after current phone..." : "Stop after current phone";
    renderUnconfirmedPhones();
  }

  function setReworkMode(mode) {
    if (sendingForRework) return;
    reworkMode = mode;
    updateBulkDraft(false);
    (mode === "bulk" ? bulkInput : reworkImei).focus();
  }

  function reworkErrorMessage(error) {
    if (error?.code === "PGRST202") return "Run the latest Greenloop database update before sending Ready Stock for rework.";
    if (String(error?.message || "").includes("not currently available in Ready Stock")) return "This mobile is not in Ready Stock.";
    return error?.message || "Phone could not be sent for rework.";
  }

  async function requestRework(imei, destination) {
    let timeout;
    try {
      const result = await Promise.race([
        getClient().rpc("send_ready_stock_for_rework_atomic_v2", { p_imei: imei, p_department: destination.department, p_customer_reason: destination.reason || null, p_technician_id: destination.department === "laboratory" ? destination.technician : null }),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error("Phone response timed out.")), 45000); })
      ]);
      if (result.error) {
        // A missing response may hide a committed change. Do not automatically retry.
        if (!result.error.code || result.status >= 500) return unconfirmedResult(imei);
        return { state: "failed", detail: reworkErrorMessage(result.error), stop: ["42501", "PGRST202", "PGRST301", "PGRST302"].includes(result.error.code) };
      }
      return { state: "sent", detail: `Sent to ${destination.name}. Journey updated.` };
    } catch (_) {
      return unconfirmedResult(imei);
    } finally { clearTimeout(timeout); }
  }

  async function sendBulkForRework(destination) {
    // Keep the batch and destination fixed even if the user navigates between views.
    bulkBatch = { rows: bulkDraft.rows.map((row) => ({ ...row })), phones: [] };
    bulkBatch.phones = bulkBatch.rows.filter((row) => row.state === "pending");
    bulkResults.hidden = false;
    bulkNote.hidden = true;
    document.querySelector("#ready-rework-results-title").textContent = "Batch results";
    renderBulkRows(bulkBatch.rows);
    updateBatchProgress();
    for (let index = 0; index < bulkBatch.phones.length; index++) {
      if (stopRequested) break;
      const row = bulkBatch.phones[index];
      row.state = "sending";
      row.detail = `Sending to ${destination.name}...`;
      renderBulkRows(bulkBatch.rows);
      const result = await requestRework(row.imei, destination);
      Object.assign(row, result);
      updateBatchProgress();
      renderBulkRows(bulkBatch.rows);
      if (result.state === "unknown" || result.stop) { stopRequested = true; break; }
    }
    bulkBatch.phones.filter((row) => row.state === "pending").forEach((row) => { row.state = "not-sent"; row.detail = "Not sent. Kept in the input list."; });
    // Sent and unconfirmed phones are excluded from a subsequent batch.
    // Unconfirmed IMEIs remain in the result list for journey verification.
    bulkInput.value = bulkBatch.rows.filter((row) => ["failed", "not-sent", "invalid"].includes(row.state)).map((row) => row.imei).join("\n");
    const unknown = bulkBatch.phones.some((row) => row.state === "unknown");
    bulkNote.textContent = unknown ? "Connection or server response was not confirmed, so the batch stopped. Check the device journey for each Not confirmed phone before re-entering it. Failed and not-sent phones remain in the input list." : "Sent phones were removed from the input list. Failed, invalid and not-sent entries remain for correction or retry.";
    bulkNote.hidden = false;
    updateBatchProgress();
    renderBulkRows(bulkBatch.rows);
    updateBulkDraft(false);
    showToast("Bulk rework finished. Check the per-phone results below.");
  }

  async function sendForRework(event) {
    event.preventDefault();
    if (sendingForRework) return;
    if (window.GREENLOOP_PAGE_ACCESS?.canEdit === false) { showToast("Entry Allowed permission is required to send phones for rework."); return; }
    const department = reworkDepartment.value;
    const technician = reworkTechnician.value;
    const imei = reworkImei.value.trim();
    const reason = reworkReason.value.trim();
    const isBulk = reworkMode === "bulk";
    if (isBulk) {
      updateBulkDraft();
      if (bulkDraft.tooLarge || !bulkDraft.phones.length) { showToast("Enter a valid batch of up to 500 unique IMEIs."); bulkInput.focus(); return; }
    } else if (!/^\d{15}$/.test(imei)) { showToast("Enter a 15-digit Ready Stock IMEI."); reworkImei.focus(); return; }
    if (!isBulk && unconfirmedImeis.has(imei)) { showToast("Check this phone in the Check before retrying list first."); return; }
    const departmentName = department === "frame" ? "Frame Department" : "Laboratory";
    if (department === "laboratory" && !technician) { showToast("Select the Laboratory technician."); reworkTechnician.focus(); return; }
    if (!["laboratory", "frame"].includes(department)) { showToast("Select a rework department."); return; }
    if (!window.confirm(`Send ${isBulk ? bulkDraft.phones.length + " phones" : imei} from Ready Stock to ${departmentName}${department === "laboratory" ? " — " + reworkTechnician.selectedOptions[0].textContent : ""}?`)) return;
    sendingForRework = true;
    stopRequested = false;
    syncReworkControls();
    try {
      const destination = { department, technician, reason, name: departmentName };
      if (isBulk) {
        await sendBulkForRework(destination);
      } else {
        const result = await requestRework(imei, destination);
        if (result.state === "unknown") reworkImei.value = "";
        if (result.state !== "sent") throw new Error(result.detail);
        const bulkText = bulkInput.value;
        reworkForm.reset();
        bulkInput.value = bulkText;
        showToast(`Phone sent to ${departmentName}. Journey updated.`);
        syncReworkTechnician();
      }
      try { await loadReadyStock(); } catch (_) { showToast("Rework results are saved. Refresh Ready Stock to update the table."); }
    } finally { sendingForRework = false; syncReworkControls(); }
  }

  function syncReworkTechnician() { reworkTechnicianWrap.hidden = reworkDepartment.value !== "laboratory"; }
  async function loadReworkTechnicians() {
    const { data, error } = await getClient().rpc("get_ready_stock_rework_technicians");
    if (error) {
      techniciansAvailable = false;
      reworkTechnician.replaceChildren(new Option("Technicians unavailable — run the update", ""));
      reworkTechnician.disabled = true;
      showToast(error.message || "Laboratory technicians could not be loaded.");
      return;
    }
    reworkTechnician.replaceChildren(new Option("Select technician", ""));
    (data || []).forEach((item) => reworkTechnician.add(new Option(item.full_name || item.email || "Technician", item.id)));
    techniciansAvailable = true;
    syncReworkControls();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }
    unconfirmedStorageKey = `greenloop-rework-unconfirmed:${sessionData.session.user.id}`;
    try {
      const saved = JSON.parse(sessionStorage.getItem(unconfirmedStorageKey) || "[]");
      if (Array.isArray(saved)) saved.filter((imei) => typeof imei === "string" && /^\d{15}$/.test(imei)).forEach((imei) => unconfirmedImeis.add(imei));
    } catch (_) { /* Invalid browser storage must not stop the page. */ }
    renderUnconfirmedPhones();
    const { data: canView, error } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner", "manager", "production", "final_qc", "shop_staff"]
    });
    if (error) throw error;
    if (!canView) {
      permissionMessage.textContent = "Your account does not have Ready Stock permission.";
      permissionMessage.hidden = false;
      return;
    }
    app.hidden = false;
    showReadyStockView();
    const today = dubaiDate();
    rangeFrom.value = today;
    rangeTo.value = today;
    await Promise.all([loadReadyStock(), loadReworkTechnicians()]);
    syncReworkTechnician();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-ready-stock").addEventListener("click", () => loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")));
  document.querySelector("#apply-ready-stock-range").addEventListener("click", () => loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")));
  document.querySelector("#clear-ready-stock-range").addEventListener("click", () => {
    rangeFrom.value = "";
    rangeTo.value = "";
    loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded."));
  });
  reworkImei.addEventListener("input", () => { reworkImei.value = reworkImei.value.replace(/\D/g, "").slice(0, 15); });
  reworkDepartment.addEventListener("change", syncReworkTechnician);
  singleModeButton.addEventListener("click", () => setReworkMode("single"));
  bulkModeButton.addEventListener("click", () => setReworkMode("bulk"));
  bulkInput.addEventListener("input", () => updateBulkDraft());
  document.querySelector("#ready-rework-unconfirmed-list").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-checked-imei]");
    if (!button || sendingForRework) return;
    unconfirmedImeis.delete(button.dataset.checkedImei);
    renderUnconfirmedPhones();
    updateBulkDraft(false);
  });
  bulkStop.addEventListener("click", () => { stopRequested = true; bulkStop.disabled = true; bulkStop.textContent = "Stopping after current phone..."; });
  window.addEventListener("beforeunload", (event) => { if (sendingForRework) { event.preventDefault(); event.returnValue = ""; } });
  reworkForm.addEventListener("submit", (event) => sendForRework(event).catch((error) => showToast(error.message || "Phone could not be sent for rework.")));
  window.addEventListener("hashchange", () => showReadyStockView(true));
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Ready Stock could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
