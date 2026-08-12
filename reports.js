(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#reports-app");
  const permissionMessage = document.querySelector("#permission-message");
  const filterForm = document.querySelector("#report-filter");
  const dateFrom = document.querySelector("#date-from");
  const dateTo = document.querySelector("#date-to");
  const message = document.querySelector("#report-message");
  const summary = document.querySelector("#report-summary");
  const tabs = document.querySelector("#report-tabs");
  const panelKicker = document.querySelector("#report-panel-kicker");
  const panelTitle = document.querySelector("#report-panel-title");
  const panelDescription = document.querySelector("#report-panel-description");
  const rowCount = document.querySelector("#report-row-count");
  const reportContent = document.querySelector("#report-content");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  let client;
  let reportData = {};
  let activeReport = "overview";
  let selectedExportBox = "";
  let exportBoxImeiFilter = "";

  const reports = {
    stock_received: {
      title: "Stock received",
      description: "Every incoming IMEI received during the selected date range.",
      columns: [["Received", "received_at", "date"], ["IMEI", "imei"], ["Model", "model"], ["Memory", "memory"], ["Color", "color"], ["Battery", "battery", "percent"], ["Source", "source"], ["Job", "job_number"]]
    },
    work_in_progress: {
      title: "Work in progress",
      description: "All active devices currently moving through the Greenloop workflow.",
      columns: [["IMEI", "imei"], ["Model", "model"], ["Job", "job_number"], ["Current status", "status", "status"], ["Location", "location"], ["Received", "received_at", "date"], ["Days open", "days_open"]]
    },
    parts_requests: {
      title: "Parts required and usage",
      description: "Requested, issued, installed, and returned parts during the selected date range.",
      columns: [["Requested", "requested_at", "date"], ["IMEI", "imei"], ["Job", "job_number"], ["Part", "part_name"], ["Required", "requested"], ["Issued", "issued"], ["Installed", "installed"], ["Returned", "returned"], ["Status", "status", "status"], ["Request source", "source"]]
    },
    parts_inventory: {
      title: "Parts inventory",
      description: "Current parts quantity, unit cost, stock value, and low-stock warning.",
      columns: [["SKU", "sku"], ["Part", "part_name"], ["In stock", "in_stock"], ["Unit cost", "unit_cost", "money"], ["Stock value", "stock_value", "money"], ["Stock level", "low_stock", "stock"]]
    },
    technicians: {
      title: "Technician performance",
      description: "Laboratory assignment, completed jobs, active hours, and rework for the selected date range.",
      columns: [["Technician", "technician"], ["Jobs assigned", "jobs_assigned"], ["Jobs completed", "jobs_completed"], ["Active hours", "active_hours", "hours"], ["Rework", "rework_count"]]
    },
    final_qc: {
      title: "Final QC results",
      description: "Pass and fail results, QC attempts, and failure reasons for the selected date range.",
      columns: [["Inspected", "inspected_at", "date"], ["IMEI", "imei"], ["Model", "model"], ["Job", "job_number"], ["Attempt", "attempt"], ["Result", "result", "status"], ["Return department", "failure_department"], ["Failure reason", "failure_reason"]]
    },
    costs: {
      title: "Device cost",
      description: "Purchase, installed parts, laboratory, glass, and total recorded cost by IMEI.",
      columns: [["IMEI", "imei"], ["Model", "model"], ["Job", "job_number"], ["Purchase", "purchase_cost", "money"], ["Parts", "parts_cost", "money"], ["Laboratory", "laboratory_cost", "money"], ["Glass", "glass_cost", "money"], ["Total cost", "total_cost", "money"]]
    },
    export_boxes: {
      title: "Export boxes",
      description: "Select a box number to see the phones scanned inside it.",
      columns: []
    },
    deleted_history: {
      title: "Deleted history",
      description: "Every deleted record, including the user, time, deletion method, and its saved snapshot.",
      columns: [["Deleted at", "deleted_at", "date"], ["Deleted by", "deleted_by"], ["Item type", "record_type"], ["Item", "record_label"], ["Deletion", "deletion_method", "status"], ["Reason", "deletion_reason"], ["Saved details", "record_data", "details"]]
    },
    rma: {
      title: "RMA report",
      description: "RMA devices received during the selected date range and their current workflow position.",
      columns: [["Received", "received_at", "date"], ["IMEI", "imei"], ["Model", "model"], ["Customer", "customer"], ["Job", "job_number"], ["Status", "status", "status"]]
    },
    retail_shop: {
      title: "Retail Shop report",
      description: "Devices received from, or currently held in, Retail Shop stock.",
      columns: [["IMEI", "imei"], ["Model", "model"], ["Memory", "memory"], ["Grade", "grade"], ["Job", "job_number"], ["Source", "source"], ["Status", "status", "status"], ["Location", "location"]]
    },
    production: {
      title: "Production report",
      description: "Today's Production is shown above. This table contains every production record in the selected date range.",
      columns: [["IMEI", "imei"], ["Model", "model"], ["Memory", "memory"], ["Grade", "grade"], ["Job", "job_number"], ["Status", "status", "status"], ["Started", "started_at", "date"], ["Completed", "completed_at", "date"]]
    }
  };

  function getClient() { if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey); return client; }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function setMessage(text = "", type = "error") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); message.classList.toggle("is-success", type === "success"); }
  function localDate(value) { const date = new Date(value); return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`; }
  function dateLabel(value) { return value ? new Date(`${value}T00:00:00`).toLocaleDateString([], { day: "2-digit", month: "short", year: "numeric" }) : "—"; }
  function dateTime(value) { return value ? new Date(value).toLocaleString([], { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }) : "—"; }
  function money(value) { return `AED ${Number(value || 0).toFixed(2)}`; }
  function title(value) { return String(value || "—").replaceAll("_", " "); }

  function renderSummary() {
    const data = reportData.summary || {};
    const cards = [
      ["Stock received", data.stock_received, "Selected date range", ""],
      ["Initial QC pending", data.initial_qc_pending, "Waiting for inspection", ""],
      ["Parts pending", data.parts_pending, "Open part requests", ""],
      ["Laboratory pending", data.laboratory_pending, "Laboratory queue", ""],
      ["Final QC pending", data.final_qc_pending, "Waiting for final inspection", ""],
      ["Today's Production", data.today_production, "Completed today", "production"],
      ["Total Production", data.total_production, `${dateLabel(reportData.date_from)} to ${dateLabel(reportData.date_to)}`, "production"],
      ["Retail Shop stock", data.retail_shop_stock, "Devices currently in shop", ""]
    ];
    summary.innerHTML = cards.map(([label, value, note, style]) => `<article class="report-metric ${style}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value ?? 0)}</strong><small>${escapeHtml(note)}</small></article>`).join("");
  }

  function formatCell(value, type) {
    if (type === "date") return escapeHtml(dateTime(value));
    if (type === "money") return escapeHtml(money(value));
    if (type === "percent") return value === null || value === undefined ? "—" : `${escapeHtml(value)}%`;
    if (type === "hours") return `${escapeHtml(value ?? 0)} h`;
    if (type === "status") {
      const raw = String(value || "pending").toLowerCase();
      return `<span class="report-status ${escapeHtml(raw)}">${escapeHtml(title(value))}</span>`;
    }
    if (type === "details") {
      const details = value && typeof value === "object" ? JSON.stringify(value, null, 2) : String(value || "No extra details saved.");
      return `<details class="report-deletion-details"><summary>View saved data</summary><pre>${escapeHtml(details)}</pre></details>`;
    }
    if (type === "stock") return value ? '<span class="report-status low">Low</span>' : '<span class="report-status">OK</span>';
    return escapeHtml(value === null || value === undefined || value === "" ? "—" : value);
  }

  function renderOverview() {
    const data = reportData.summary || {};
    const items = [
      ["Stock received", data.stock_received], ["Initial QC pending", data.initial_qc_pending],
      ["Parts pending", data.parts_pending], ["Laboratory pending", data.laboratory_pending],
      ["Final QC pending", data.final_qc_pending], ["Today's Production", data.today_production],
      ["Total Production", data.total_production], ["Retail Shop stock", data.retail_shop_stock]
    ];
    panelKicker.textContent = "Overview";
    panelTitle.textContent = "Live workflow overview";
    panelDescription.textContent = `Operational totals. Date-based figures use ${dateLabel(reportData.date_from)} to ${dateLabel(reportData.date_to)}.`;
    rowCount.textContent = "Live totals";
    reportContent.innerHTML = `<div class="report-overview-grid">${items.map(([label, value]) => `<article class="report-overview-item"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value ?? 0)}</strong></article>`).join("")}</div>`;
  }

  function renderTable(reportKey) {
    const report = reports[reportKey];
    const rows = reportData[reportKey] || [];
    panelKicker.textContent = report.title;
    panelTitle.textContent = report.title;
    panelDescription.textContent = report.description;
    rowCount.textContent = `${rows.length} record${rows.length === 1 ? "" : "s"}`;
    const headers = report.columns.map(([label]) => `<th>${escapeHtml(label)}</th>`).join("");
    const body = rows.length
      ? rows.map((row) => `<tr>${report.columns.map(([, key, type]) => `<td>${formatCell(row[key], type)}</td>`).join("")}</tr>`).join("")
      : `<tr><td class="report-empty" colspan="${report.columns.length}">No records were found for this report.</td></tr>`;
    reportContent.innerHTML = `<div class="report-table-wrap"><table class="report-table"><thead><tr>${headers}</tr></thead><tbody>${body}</tbody></table></div>`;
  }

  function getExportBoxGroups() {
    const groups = new Map();
    (reportData.export_boxes || []).forEach((row) => {
      const boxNumber = String(row.box_number || "Unknown box");
      if (!groups.has(boxNumber)) groups.set(boxNumber, []);
      groups.get(boxNumber).push(row);
    });
    return [...groups.entries()]
      .map(([boxNumber, rows]) => ({ boxNumber, rows }))
      .sort((left, right) => new Date(right.rows[0]?.opened_at || 0) - new Date(left.rows[0]?.opened_at || 0));
  }

  function renderExportBoxes() {
    const boxes = getExportBoxGroups();
    const selected = boxes.find((box) => box.boxNumber === selectedExportBox);
    panelKicker.textContent = "Export boxes";
    panelTitle.textContent = "Export box history";
    panelDescription.textContent = "Only box numbers are shown first. Select a box number to view its phones and search IMEI inside that box.";
    rowCount.textContent = `${boxes.length} box${boxes.length === 1 ? "" : "es"}`;

    const boxList = boxes.length
      ? boxes.map((box) => `<button class="export-box-select${box.boxNumber === selectedExportBox ? " active" : ""}" type="button" data-export-box="${escapeHtml(box.boxNumber)}">${escapeHtml(box.boxNumber)}</button>`).join("")
      : '<p class="report-empty export-box-empty">No export boxes were found for this date range.</p>';

    let detail = '<div class="export-box-detail-empty">Select a box number to view its phones.</div>';
    if (selected) {
      const filter = exportBoxImeiFilter.trim().toLowerCase();
      const rows = selected.rows.filter((row) => !filter || String(row.imei || "").toLowerCase().includes(filter));
      const body = rows.length
        ? rows.map((row) => `<tr><td>${escapeHtml(row.serial_no)}</td><td>${escapeHtml(row.imei)}</td><td>${formatCell(row.model)}</td><td>${formatCell(row.memory)}</td><td>${formatCell(row.final_grade)}</td><td>${formatCell(row.color)}</td><td>${formatCell(row.scanned_at, "date")}</td></tr>`).join("")
        : '<tr><td class="report-empty" colspan="7">No IMEI in this box matches your search.</td></tr>';
      detail = `
        <section class="export-box-detail">
          <div class="export-box-detail-heading"><div><p class="panel-kicker">Selected export box</p><h3>${escapeHtml(selected.boxNumber)}</h3></div><div class="export-box-detail-actions"><span>${selected.rows.length} phone${selected.rows.length === 1 ? "" : "s"}</span><button class="report-delete-box" type="button" data-delete-export-box="${escapeHtml(selected.boxNumber)}">Delete box</button></div></div>
          <label class="export-box-imei-search" for="export-box-imei-filter">Search IMEI in this box<input id="export-box-imei-filter" type="search" autocomplete="off" value="${escapeHtml(exportBoxImeiFilter)}" placeholder="Type or scan an IMEI"></label>
          <div class="report-table-wrap"><table class="report-table export-box-lines"><thead><tr><th>S.No</th><th>IMEI</th><th>Model</th><th>GB</th><th>Grade</th><th>Color</th><th>Scanned</th></tr></thead><tbody>${body}</tbody></table></div>
        </section>`;
    }

    reportContent.innerHTML = `<div class="export-box-report"><div class="export-box-list" aria-label="Export box numbers">${boxList}</div>${detail}</div>`;
  }

  async function deleteSelectedExportBox(boxNumber) {
    const code = window.prompt(`Enter deletion code to delete ${boxNumber}. This returns all phones to Ready Stock.`);
    if (code === null) return;
    if (!code.trim()) { setMessage("Enter the deletion code to delete this export box."); return; }

    setMessage();
    const { data, error } = await getClient().rpc("delete_export_box_by_number_with_restore", {
      p_box_number: boxNumber,
      p_delete_code: code
    });
    if (error) { setMessage(error.message || "The export box could not be deleted."); return; }
    const deleted = Array.isArray(data) ? data[0] : data;
    const restored = Number(deleted?.restored_items || 0);
    await loadReports();
    setMessage(`${deleted?.deleted_box_number || boxNumber} was deleted. ${restored} phone(s) returned to Ready Stock.`, "success");
  }

  function renderActiveReport() {
    document.querySelectorAll(".report-tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.report === activeReport));
    if (activeReport === "overview") renderOverview();
    else if (activeReport === "export_boxes") renderExportBoxes();
    else renderTable(activeReport);
  }

  async function loadReports(event) {
    event?.preventDefault();
    setMessage();
    if (!dateFrom.value || !dateTo.value) { setMessage("Select both dates first."); return; }
    const submit = document.querySelector("#apply-report-filter");
    submit.disabled = true;
    submit.textContent = "Loading...";
    const { data, error } = await getClient().rpc("get_greenloop_reports", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    submit.disabled = false;
    submit.textContent = "Apply date range";
    if (error) { setMessage(error.message || "Reports could not be loaded."); return; }
    reportData = Array.isArray(data) ? data[0] : data || {};
    const { data: exportBoxes, error: exportBoxesError } = await getClient().rpc("get_export_box_report", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    reportData.export_boxes = exportBoxesError ? [] : (exportBoxes || []);
    const { data: deletedHistory, error: deletedHistoryError } = await getClient().rpc("get_deletion_history", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    reportData.deleted_history = deletedHistoryError ? [] : (deletedHistory || []);
    selectedExportBox = "";
    exportBoxImeiFilter = "";
    const { data: openPartsCount } = await getClient().rpc("get_open_parts_pending_count");
    if (Number.isFinite(Number(openPartsCount))) {
      reportData.summary = reportData.summary || {};
      reportData.summary.parts_pending = Number(openPartsCount);
    }
    renderSummary();
    renderActiveReport();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canView, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "initial_qc", "parts", "technician", "final_qc", "production", "rma", "shop_staff"] });
    if (error) throw error;
    if (!canView) { permissionMessage.textContent = "Your account does not have Reports permission."; permissionMessage.hidden = false; return; }
    const requestedReport = new URLSearchParams(window.location.search).get("report");
    if (requestedReport && reports[requestedReport]) activeReport = requestedReport;
    const now = new Date();
    dateFrom.value = localDate(new Date(now.getFullYear(), now.getMonth(), 1));
    dateTo.value = localDate(now);
    app.hidden = false;
    await loadReports();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  filterForm.addEventListener("submit", loadReports);
  tabs.addEventListener("click", (event) => {
    const tab = event.target.closest(".report-tab");
    if (!tab) return;
    activeReport = tab.dataset.report;
    renderActiveReport();
  });
  reportContent.addEventListener("click", (event) => {
    const deleteBoxButton = event.target.closest("[data-delete-export-box]");
    if (deleteBoxButton) {
      deleteSelectedExportBox(deleteBoxButton.dataset.deleteExportBox || "").catch((error) => setMessage(error.message || "The export box could not be deleted."));
      return;
    }
    const boxButton = event.target.closest("[data-export-box]");
    if (!boxButton) return;
    selectedExportBox = boxButton.dataset.exportBox || "";
    exportBoxImeiFilter = "";
    renderExportBoxes();
  });
  reportContent.addEventListener("input", (event) => {
    if (event.target.id !== "export-box-imei-filter") return;
    exportBoxImeiFilter = event.target.value;
    renderExportBoxes();
    const filter = document.querySelector("#export-box-imei-filter");
    if (filter) {
      filter.focus();
      filter.setSelectionRange(filter.value.length, filter.value.length);
    }
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Reports could not be loaded."; permissionMessage.hidden = false; });
})();
