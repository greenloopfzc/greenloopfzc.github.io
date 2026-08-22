(() => {
  "use strict";

  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const openMenuButton = document.querySelector("#open-menu");
  const closeMenuButton = document.querySelector("#close-menu");
  const searchInput = document.querySelector("#dashboard-search");
  const searchEmpty = document.querySelector("#search-empty");
  const toast = document.querySelector("#toast");
  const dashboardTitle = document.querySelector("#dashboard-title");
  const liveHeadlines = document.querySelector(".live-headlines");
  const liveHeadlinesItems = document.querySelector("#live-headlines-items");
  const config = window.GREENLOOP_CONFIG || {};
  let client;
  let toastTimer;
  let rows = [];
  let currentQueueTotal = 0;
  let liveHeadlinesSignature = "";

  document.querySelector("#dashboard-date").textContent = new Intl.DateTimeFormat("en-US", {
    weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "Asia/Dubai"
  }).format(new Date());

  function getDubaiHour() {
    const hourPart = new Intl.DateTimeFormat("en-US", {
      hour: "2-digit",
      hourCycle: "h23",
      timeZone: "Asia/Dubai"
    }).formatToParts(new Date()).find((part) => part.type === "hour");
    return Number(hourPart?.value || 0);
  }

  function updateDashboardGreeting(name = "Admin") {
    const hour = getDubaiHour();
    const greeting = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : hour < 22 ? "Good evening" : "Good night";
    dashboardTitle.textContent = `${greeting}, ${name || "Admin"}.`;
  }

  updateDashboardGreeting();

  function getClient() {
    return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
  }

  function titleCase(value) {
    return String(value || "Pending").replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  }

  function localDate(value) {
    const date = value instanceof Date ? value : new Date(value);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  }

  function dateInDubai(value) {
    const format = new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Dubai", year: "numeric", month: "2-digit", day: "2-digit" });
    const parts = Object.fromEntries(format.formatToParts(new Date(value)).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
    return `${parts.year}-${parts.month}-${parts.day}`;
  }

  function dateLabel(value) {
    return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", { weekday: "short", timeZone: "Asia/Dubai" });
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function showToast(text) {
    window.clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => {
      toast.classList.remove("is-visible");
      toast.hidden = true;
    }, 3600);
  }

  function renderMetrics(workflow) {
    const cards = [
      ["Stock Received", workflow.stock_received, "Total received quantity", "company-stock", "stock-entry.html", "◫"],
      ["IMEI Entry", workflow.imei_entry, "Waiting for IMEI entry", "imei-entry-stock", "imei-entry.html", "⌕"],
      ["Initial QC", workflow.initial_qc, "Waiting for inspection", "customer-stock", "initial-qc.html", "✓"],
      ["Lab & Glass", workflow.lab_glass, "Waiting for repair", "lab-stock", "laboratory.html", "⌁"],
      ["Parts", workflow.parts, "Open part requests", "rma-stock", "parts.html", "▦"],
      ["Final QC", workflow.final_qc, "Waiting for final check", "final-qc-stock", "final-qc.html", "◉"],
      ["Frame Department", workflow.frame, "Waiting for frame work", "frame-stock", "laboratory.html#frame", "□"],
      ["Ready Stock", workflow.ready_stock, "Available now", "ready-stock", "ready-stock.html", "▤"],
      ["Export Data", workflow.export_data, "IMEIs in export boxes", "export-stock", "export-box.html", "↝"]
    ];

    document.querySelector(".workflow-metric-grid").innerHTML = cards.map(([label, value, note, style, href, icon]) => `
      <a class="metric-card metric-card-link ${style}" href="${href}">
        <div class="metric-topline"><span class="metric-icon">${icon}</span><span class="trend up">Live</span></div>
        <p>${escapeHtml(label)}</p><strong>${escapeHtml(value || 0)}</strong><small>${escapeHtml(note)} <span aria-hidden="true">&rarr;</span></small>
      </a>
    `).join("");
  }

  function headlineTime(value) {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: "Asia/Dubai", hour: "numeric", minute: "2-digit", hour12: true, day: "2-digit", month: "short"
    }).format(new Date(value));
  }

  function renderLiveHeadlines(headlines) {
    if (!liveHeadlines || !liveHeadlinesItems) return;
    const signature = JSON.stringify((headlines || []).map((item) => [item.event_at, item.imei, item.from_stage, item.to_stage, item.activity_title]));
    if (signature === liveHeadlinesSignature) return;
    liveHeadlinesSignature = signature;
    liveHeadlines.hidden = false;
    if (!headlines.length) {
      const emptyMarkup = '<span class="live-headline-item"><strong>NO LIVE ACTIVITY</strong><span>New Stock Received, IMEI, QC, Lab, Frame, Ready Stock, and Export activity will appear here automatically.</span></span>';
      liveHeadlinesItems.innerHTML = emptyMarkup + emptyMarkup;
      setLiveHeadlineSpeed();
      return;
    }
    const itemMarkup = headlines.map((item) => {
      const supplier = item.supplier_code || "Supplier";
      const device = [item.model || "Model", item.storage_gb ? `${item.storage_gb} GB` : "GB -", item.color || "Color -"].join(" · ");
      return `<span class="live-headline-item"><time>${escapeHtml(headlineTime(item.event_at))}</time><strong>${escapeHtml(item.imei || "IMEI")}</strong><span>${escapeHtml(supplier)} · ${escapeHtml(device)}</span><b>${escapeHtml(item.from_stage || "Workflow")} &rarr; ${escapeHtml(item.to_stage || "Updated")}</b><em>${escapeHtml(item.activity_title || "Activity recorded")}</em></span>`;
    }).join("");
    liveHeadlinesItems.innerHTML = itemMarkup + itemMarkup;
    setLiveHeadlineSpeed();
  }

  function setLiveHeadlineSpeed() {
    window.requestAnimationFrame(() => {
      const loopDistance = liveHeadlinesItems.scrollWidth / 2;
      const durationSeconds = Math.max(16, Math.ceil(loopDistance / 100));
      liveHeadlinesItems.style.animationDuration = `${durationSeconds}s`;
    });
  }

  async function refreshLiveHeadlines() {
    const { data, error } = await getClient().rpc("get_overview_activity_headlines", { p_limit: 12 });
    if (error) {
      renderLiveHeadlines([]);
      return;
    }
    renderLiveHeadlines(data || []);
  }

  function renderQueues(summary, readyTotal) {
    const queues = [
      ["Initial QC", Number(summary.initial_qc_pending) || 0, "qc"],
      ["Parts", Number(summary.parts_pending) || 0, "parts"],
      ["Laboratory & Glass", Number(summary.laboratory_pending) || 0, "lab"],
      ["Final QC", Number(summary.final_qc_pending) || 0, "final-qc"],
      ["Ready Stock", Number(readyTotal) || 0, "production"]
    ];
    const maximum = Math.max(...queues.map(([, count]) => count), 1);
    currentQueueTotal = queues.reduce((total, [, count]) => total + count, 0);
    document.querySelector(".queue-list").innerHTML = queues.map(([label, count, style]) => `
      <div class="queue-row"><span class="queue-name"><i class="queue-dot ${style}"></i>${escapeHtml(label)}</span><span class="queue-bar"><b style="width: ${Math.round((count / maximum) * 100)}%"></b></span><strong>${count}</strong></div>
    `).join("");

    const largest = queues.reduce((best, item) => item[1] > best[1] ? item : best, queues[0]);
    document.querySelector(".queue-insight p").innerHTML = largest[1]
      ? `<strong>${escapeHtml(largest[0])} is the largest live queue.</strong> It currently has ${largest[1]} device${largest[1] === 1 ? "" : "s"}.`
      : "<strong>All live queues are clear.</strong> No device is waiting in the current workflow queues.";
  }

  function renderThroughput(finalQc, days) {
    const completed = finalQc.filter((row) => row.result === "pass" && row.inspected_at).map((row) => ({ completed_at: row.inspected_at }));
    const counts = new Map(days.map((day) => [day, 0]));
    completed.forEach((row) => {
      const day = dateInDubai(row.completed_at);
      if (counts.has(day)) counts.set(day, counts.get(day) + 1);
    });
    const maximum = Math.max(...counts.values(), 1);
    const today = days[days.length - 1];
    const chart = document.querySelector(".bar-chart");
    chart.innerHTML = days.map((day) => {
      const value = counts.get(day) || 0;
      return `<div class="bar-column${day === today ? " current" : ""}"><span class="bar-value">${value}</span><i style="height: ${value ? Math.max(8, Math.round((value / maximum) * 86)) : 2}%"></i><small>${escapeHtml(dateLabel(day))}</small></div>`;
    }).join("");
    document.querySelector(".throughput-panel .panel-kicker").textContent = "Last 7 days";
    document.querySelector(".throughput-panel h2").textContent = "Final QC passes";
    document.querySelector(".throughput-panel .chart-legend").lastChild.textContent = "Passed";
    document.querySelector(".throughput-summary").innerHTML = `<strong>${completed.length}</strong><span>phones passed Final QC in the last 7 days</span><em>${counts.get(today) || 0} passed today</em>`;
  }

  function renderPriority(rowsToRender) {
    const body = document.querySelector(".priority-table tbody");
    body.innerHTML = rowsToRender.length ? rowsToRender.slice(0, 5).map((row) => {
      const age = Number(row.days_open) || 0;
      const status = titleCase(row.status);
      const style = row.status?.includes("in_progress") ? "info" : "warning";
      return `<tr data-search="${escapeHtml([row.job_number, row.imei, row.model, row.status].join(" ").toLowerCase())}">
        <td><strong>${escapeHtml(row.job_number || "-")}</strong><small>${escapeHtml(row.imei || "-")}</small></td>
        <td>${escapeHtml(status)}</td><td>${age} day${age === 1 ? "" : "s"}</td><td><span class="status-chip ${style}">${escapeHtml(status)}</span></td>
      </tr>`;
    }).join("") : '<tr><td colspan="4">No active devices need attention.</td></tr>';
    rows = [...body.querySelectorAll("tr[data-search]")];
    filterRows();
  }

  function isReadyStockStatus(status) {
    return ["qc_passed", "production_pending", "production_completed", "ready_for_packing", "ready_for_shipment"]
      .includes(String(status || "").trim().toLowerCase().replaceAll(" ", "_"));
  }

  function renderParts(inventory) {
    const list = document.querySelector(".stock-list");
    const lowStock = inventory.filter((row) => row.low_stock).slice(0, 4);
    list.innerHTML = lowStock.length ? lowStock.map((row) => `
      <li><span class="part-icon">${escapeHtml(String(row.part_name || "PT").slice(0, 2).toUpperCase())}</span><span><strong>${escapeHtml(row.part_name)}</strong><small>SKU: ${escapeHtml(row.sku || "-")}</small></span><b class="stock-level warning">${escapeHtml(row.in_stock || 0)} left</b></li>
    `).join("") : '<li><span><strong>No low-stock parts.</strong><small>Parts inventory is currently above its minimum level.</small></span></li>';
  }

  function renderLiveStatus(summary, readyTotal, reportData) {
    const locationPanel = document.querySelector(".location-panel");
    locationPanel.querySelector("h2").textContent = "Live stock status";
    locationPanel.querySelector(".location-grid").innerHTML = [
      ["Ready Stock", readyTotal],
      ["Work in progress", (reportData.work_in_progress || []).length]
    ].map(([label, value]) => `<div><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
  }

  function renderActivity(reportData) {
    const items = [
      ...(reportData.final_qc || []).map((row) => ({ time: row.inspected_at, title: `Final QC ${titleCase(row.result)}`, text: `${row.job_number || "Job"} · ${row.imei || "No IMEI"}`, style: row.result === "pass" ? "green" : "red" })),
      ...(reportData.parts_requests || []).map((row) => ({ time: row.requested_at, title: "Part request", text: `${row.part_name || "Part"} · ${row.job_number || "Job"}`, style: "amber" })),
      ...(reportData.stock_received || []).map((row) => ({ time: row.received_at, title: "Stock received", text: `${row.imei || "No IMEI"} · ${row.model || "Unknown model"}`, style: "green" }))
    ].filter((item) => item.time).sort((a, b) => new Date(b.time) - new Date(a.time)).slice(0, 4);
    document.querySelector(".activity-list").innerHTML = items.length ? items.map((item) => `
      <li><i class="activity-dot ${item.style}"></i><span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.text)}</small></span><time>${escapeHtml(new Date(item.time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}</time></li>
    `).join("") : '<li><span><strong>No recent live activity.</strong><small>New receipts and workflow actions will appear here.</small></span></li>';
  }

  function filterRows() {
    const query = searchInput.value.trim().toLowerCase();
    let visibleRows = 0;
    rows.forEach((row) => {
      const matches = row.dataset.search.toLowerCase().includes(query);
      row.hidden = !matches;
      if (matches) visibleRows += 1;
    });
    searchEmpty.hidden = visibleRows !== 0 || !query;
  }

  async function loadLiveDashboard() {
    const now = new Date();
    const start = new Date(now);
    start.setDate(start.getDate() - 6);
    const days = Array.from({ length: 7 }, (_, index) => {
      const day = new Date(start);
      day.setDate(start.getDate() + index);
      return localDate(day);
    });
    const [reportsResult, readyResult, partsResult, workflowResult] = await Promise.all([
      getClient().rpc("get_greenloop_reports", { p_date_from: days[0], p_date_to: days[6] }),
      getClient().rpc("get_ready_stock_summary"),
      getClient().rpc("get_open_parts_pending_count"),
      getClient().rpc("get_overview_workflow_counts")
    ]);
    if (reportsResult.error) throw reportsResult.error;
    if (workflowResult.error) throw workflowResult.error;
    const reportData = Array.isArray(reportsResult.data) ? reportsResult.data[0] : (reportsResult.data || {});
    const summary = reportData.summary || {};
    if (!partsResult.error && Number.isFinite(Number(partsResult.data))) summary.parts_pending = Number(partsResult.data);
    const readyData = readyResult.error ? {} : (Array.isArray(readyResult.data) ? readyResult.data[0] : readyResult.data || {});
    const readyTotal = Number(readyData.total_qty) || 0;

    const workflow = Array.isArray(workflowResult.data) ? workflowResult.data[0] : (workflowResult.data || {});
    renderMetrics(workflow);
    await refreshLiveHeadlines();
    renderQueues(summary, readyTotal);
    renderThroughput(reportData.final_qc || [], days);
    renderPriority((reportData.work_in_progress || []).filter((row) => !isReadyStockStatus(row.status)));
    renderParts(reportData.parts_inventory || []);
    renderLiveStatus(summary, readyTotal, reportData);
    renderActivity(reportData);
  }

  openMenuButton.addEventListener("click", () => setMenu(true));
  closeMenuButton.addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#notification-button").addEventListener("click", () => showToast(`${currentQueueTotal} device${currentQueueTotal === 1 ? " is" : "s are"} currently waiting across live queues.`));
  searchInput.addEventListener("input", filterRows);
  searchInput.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { searchInput.value = ""; filterRows(); searchInput.blur(); }
  });
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); searchInput.focus(); }
    if (event.key === "Escape") setMenu(false);
  });

  async function protectDashboard() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      showToast("Dashboard authentication is not configured.");
      return;
    }
    const { data: sessionData, error: sessionError } = await getClient().auth.getSession();
    if (sessionError || !sessionData.session) { window.location.replace("index.html"); return; }
    const { data: profile } = await getClient().from("user_profiles").select("full_name").eq("id", sessionData.session.user.id).maybeSingle();
    if (profile?.full_name) {
      const firstName = profile.full_name.trim().split(/\s+/)[0];
      updateDashboardGreeting(firstName || "Admin");
    } else {
      updateDashboardGreeting();
    }
    await window.GREENLOOP_ACCESS_READY;
    await loadLiveDashboard();
  }

  window.setInterval(() => {
    const currentName = dashboardTitle.textContent
      .replace(/good\s+(morning|afternoon|evening|night)\s*,?\s*/i, "")
      .replace(/\.$/, "")
      .trim() || "Admin";
    updateDashboardGreeting(currentName);
  }, 60000);

  protectDashboard().catch((error) => showToast(error.message || "Live dashboard data could not be loaded."));
  window.setInterval(() => refreshLiveHeadlines().catch(() => {}), 15000);
})();
