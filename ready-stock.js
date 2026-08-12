(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#ready-stock-app");
  const permissionMessage = document.querySelector("#permission-message");
  const total = document.querySelector("#ready-stock-total");
  const body = document.querySelector("#ready-stock-body");
  const totalGradeA = document.querySelector("#total-grade-a");
  const totalGradeB = document.querySelector("#total-grade-b");
  const totalOtherGrade = document.querySelector("#total-other-grade");
  const totalRma = document.querySelector("#total-rma");
  const totalQty = document.querySelector("#total-qty");
  const rangeFrom = document.querySelector("#ready-stock-from");
  const rangeTo = document.querySelector("#ready-stock-to");
  const rangeLabel = document.querySelector("#ready-stock-range-label");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let toastTimer;

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
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200); }

  function render(data) {
    const rows = data?.rows || [];
    const sum = (key) => rows.reduce((value, row) => value + Number(row[key] || 0), 0);
    total.textContent = `${Number(data?.total_qty || 0)} pcs`;
    totalGradeA.textContent = sum("grade_a");
    totalGradeB.textContent = sum("grade_b");
    totalOtherGrade.textContent = sum("other_grade");
    totalRma.textContent = sum("rma");
    totalQty.textContent = `${Number(data?.total_qty || 0)} pcs`;
    rangeLabel.textContent = data?.date_from && data?.date_to
      ? `Current Ready Stock passed Final QC from ${data.date_from} to ${data.date_to}`
      : "Final-QC-passed devices still held by Greenloop";
    body.innerHTML = rows.length
      ? rows.map((row) => `<tr><td>${escapeHtml(row.model || "Unknown model")}</td><td>${escapeHtml(row.grade_a || 0)}</td><td>${escapeHtml(row.grade_b || 0)}</td><td>${escapeHtml(row.other_grade || 0)}</td><td>${escapeHtml(row.rma || 0)}</td><td>${escapeHtml(formatDateTime(row.latest_passed_at))}</td><td>${escapeHtml(row.total_qty || 0)}</td></tr>`).join("")
      : '<tr><td class="ready-stock-empty" colspan="7">No Final-QC-passed stock is waiting in Ready Stock.</td></tr>';
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
    const { data, error } = await getClient().rpc("get_ready_stock_summary_by_date", { p_date_from: from, p_date_to: to });
    refresh.disabled = false;
    refresh.textContent = "Refresh table";
    if (error) throw error;
    render(Array.isArray(data) ? data[0] : data);
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
    await loadReadyStock();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-ready-stock").addEventListener("click", () => loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")));
  document.querySelector("#apply-ready-stock-range").addEventListener("click", () => loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")));
  document.querySelector("#clear-ready-stock-range").addEventListener("click", () => { rangeFrom.value = ""; rangeTo.value = ""; loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")); });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Ready Stock could not be loaded."; permissionMessage.hidden = false; });
})();
