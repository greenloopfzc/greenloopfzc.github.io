(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const board = document.querySelector("#lab-live-board");
  const grid = document.querySelector("#technician-live-grid");
  const boardCount = document.querySelector("#board-count");
  const updated = document.querySelector("#board-updated");
  const refreshButton = document.querySelector("#refresh-board");
  const tvButton = document.querySelector("#tv-mode");
  let client;
  let toastTimer;

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function initials(name) { return String(name || "T").trim().split(/\s+/).slice(0, 2).map((word) => word[0]).join("").toUpperCase(); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200); }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function dateTime() { return new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", hour: "numeric", minute: "2-digit", hour12: true }).format(new Date()); }
  function deviceLabel(row) {
    if (!row.latest_imei) return "No phone currently assigned";
    return `<strong>${escapeHtml(row.latest_imei)}</strong> - ${escapeHtml([row.latest_model || "Model -", row.latest_gb ? `${row.latest_gb} GB` : "GB -", row.latest_color || "Color -"].join(" - "))}`;
  }
  function pendingAge(hours) {
    const total = Number(hours) || 0;
    if (!total) return "No active phone";
    const days = Math.floor(total / 24);
    const remaining = total % 24;
    return days ? `${days}d ${remaining}h` : `${remaining}h`;
  }
  function render(rows) {
    const totalPending = rows.reduce((total, row) => total + (Number(row.pending_count) || 0), 0);
    const totalWorking = rows.reduce((total, row) => total + (Number(row.working_count) || 0), 0);
    const totalCompleted = rows.reduce((total, row) => total + (Number(row.completed_today) || 0), 0);
    const totalOverdue = rows.reduce((total, row) => total + (Number(row.overdue_count) || 0), 0);
    const totalMonth = rows.reduce((total, row) => total + (Number(row.completed_month) || 0), 0);
    document.querySelector("#summary-technicians").textContent = rows.length;
    document.querySelector("#summary-pending").textContent = totalPending;
    document.querySelector("#summary-working").textContent = totalWorking;
    document.querySelector("#summary-completed").textContent = totalCompleted;
    document.querySelector("#summary-overdue").textContent = totalOverdue;
    document.querySelector("#summary-month").textContent = totalMonth;
    boardCount.textContent = `${rows.length} technician${rows.length === 1 ? "" : "s"}`;
    grid.innerHTML = rows.length ? rows.map((row) => {
      const pending = Number(row.pending_count) || 0;
      const working = Number(row.working_count) || 0;
      const handoff = Number(row.final_qc_handoff_count) || 0;
      const overdue = Number(row.overdue_count) || 0;
      const damages = Number(row.damage_month) || 0;
      const qcReturns = Number(row.qc_returns_month) || 0;
      const state = working ? "Working now" : pending ? "Pending work" : "Clear";
      const className = overdue ? "is-overdue" : working ? "is-busy" : pending ? "" : "is-clear";
      const alert = overdue ? `<div class="technician-live-alert"><strong>⚠ ${overdue} phone${overdue === 1 ? "" : "s"} over 2 days</strong><span>${escapeHtml(row.oldest_imei || "Oldest pending phone")} - waiting ${pendingAge(row.oldest_pending_hours)}</span></div>` : "";
      return `<article class="technician-live-card ${className}"><div class="technician-live-head"><span class="technician-live-avatar">${escapeHtml(initials(row.technician_name))}</span><span class="technician-live-name"><strong>${escapeHtml(row.technician_name)}</strong><span>Lab &amp; Glass technician</span></span><span class="technician-live-state">${state}</span></div>${alert}<div class="technician-live-main"><div><span>Pending phones</span><strong>${pending}</strong></div><div><span>Working now</span><strong>${working}</strong></div></div><div class="technician-live-stats"><div><span>Awaiting Final QC</span><strong>${handoff}</strong></div><div><span>Completed today</span><strong>${Number(row.completed_today) || 0}</strong></div><div><span>Completed month</span><strong>${Number(row.completed_month) || 0}</strong></div></div><div class="technician-live-quality"><div><span>Damages month</span><strong>${damages}</strong></div><div><span>QC returns month</span><strong>${qcReturns}</strong></div><div><span>Career completed</span><strong>${Number(row.completed_total) || 0}</strong></div></div><div class="technician-live-device">${deviceLabel(row)}</div></article>`;
    }).join("") : '<p class="technician-live-empty">No active Lab &amp; Glass technicians are available.</p>';
    updated.textContent = `Updated ${dateTime()}`;
  }
  async function loadBoard() {
    refreshButton.disabled = true;
    const { data, error } = await getClient().rpc("get_lab_live_board");
    refreshButton.disabled = false;
    if (error) throw error;
    render(data || []);
  }
  async function toggleTvMode() {
    const isTv = document.body.classList.toggle("lab-tv-mode");
    tvButton.textContent = isTv ? "Exit TV mode" : "TV mode";
    try { if (isTv && !document.fullscreenElement) await document.documentElement.requestFullscreen(); else if (!isTv && document.fullscreenElement) await document.exitFullscreen(); } catch { showToast("TV mode is ready. Press F11 for full screen."); }
  }
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  refreshButton.addEventListener("click", () => loadBoard().catch((error) => showToast(error.message || "Board could not be refreshed.")));
  tvButton.addEventListener("click", toggleTvMode);
  document.addEventListener("fullscreenchange", () => { if (!document.fullscreenElement && document.body.classList.contains("lab-tv-mode")) { document.body.classList.remove("lab-tv-mode"); tvButton.textContent = "TV mode"; } });
  async function start() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { showToast("Board connection is not configured."); return; }
    const { data, error } = await getClient().auth.getSession();
    if (error || !data.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;
    board.hidden = false;
    await loadBoard();
  }
  window.setInterval(() => loadBoard().catch(() => {}), 30000);
  start().catch((error) => showToast(error.message || "Lab Live Board could not be loaded."));
})();
