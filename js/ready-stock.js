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
  let client;
  let toastTimer;

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
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
    const { data, error } = await getClient().rpc("get_ready_stock_final_grade_table", {
      p_date_from: from,
      p_date_to: to
    });
    refresh.disabled = false;
    refresh.textContent = "Refresh table";
    if (error) throw error;
    render(Array.isArray(data) ? data[0] : data);
  }

  async function sendForRework(event) {
    event.preventDefault();
    const imei = reworkImei.value.replace(/\D/g, "").slice(0, 15);
    const reason = reworkReason.value.trim();
    if (!/^\d{15}$/.test(imei)) { showToast("Enter a 15-digit Ready Stock IMEI."); reworkImei.focus(); return; }
    const departmentName = reworkDepartment.value === "frame" ? "Frame Department" : "Laboratory";
    if (reworkDepartment.value === "laboratory" && !reworkTechnician.value) { showToast("Select the Laboratory technician."); reworkTechnician.focus(); return; }
    if (!window.confirm(`Send ${imei} from Ready Stock to ${departmentName}?`)) return;
    reworkSubmit.disabled = true;
    reworkSubmit.textContent = "Sending...";
    let error;
    try {
      ({ error } = await getClient().rpc("send_ready_stock_for_rework", {
        p_imei: imei, p_department: reworkDepartment.value, p_customer_reason: reason || null
      }));
      if (!error && reworkDepartment.value === "frame") {
        ({ error } = await getClient().rpc("ensure_ready_stock_frame_rework_cycle", { p_imei: imei }));
      }
      if (!error && reworkDepartment.value === "laboratory") {
        ({ error } = await getClient().rpc("assign_ready_stock_rework_technician", { p_imei: imei, p_technician_id: reworkTechnician.value }));
      }
    } finally {
      reworkSubmit.disabled = false;
      reworkSubmit.textContent = "Send for rework";
    }
    if (error) {
      if (reworkDepartment.value === "laboratory" && String(error.message || "").includes("not in Ready Stock")) {
        const { error: assignError } = await getClient().rpc("assign_ready_stock_rework_technician", { p_imei: imei, p_technician_id: reworkTechnician.value });
        if (!assignError) {
          reworkForm.reset();
          syncReworkTechnician();
          showToast("Existing Lab rework phone assigned to the selected technician.");
          await loadReadyStock();
          return;
        }
      }
      if (String(error.message || "").includes("not currently available in Ready Stock")) throw new Error("This mobile is not in Ready Stock.");
      throw error;
    }
    reworkForm.reset();
    showToast(`Phone sent to ${departmentName}. Journey updated.`);
    await loadReadyStock();
  }

  function syncReworkTechnician() { reworkTechnicianWrap.hidden = reworkDepartment.value !== "laboratory"; }
  async function loadReworkTechnicians() {
    const { data, error } = await getClient().rpc("get_ready_stock_rework_technicians");
    if (error) {
      reworkTechnician.replaceChildren(new Option("Technicians unavailable — run the update", ""));
      reworkTechnician.disabled = true;
      showToast(error.message || "Laboratory technicians could not be loaded.");
      return;
    }
    reworkTechnician.replaceChildren(new Option("Select technician", ""));
    (data || []).forEach((item) => reworkTechnician.add(new Option(item.full_name || item.email || "Technician", item.id)));
    reworkTechnician.disabled = false;
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
  reworkForm.addEventListener("submit", (event) => sendForRework(event).catch((error) => showToast(error.message || "Phone could not be sent for rework.")));
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Ready Stock could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
