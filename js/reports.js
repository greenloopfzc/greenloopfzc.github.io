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
  let correctionRecord = null;
  let canManageCorrections = false;
  let auditView = "deleted";
  let selectedSupplier = "all";

  const reports = {
    stock_received: {
      title: "Stock received",
      description: "Every incoming IMEI received during the selected date range.",
      columns: [["Received", "received_at", "date"], ["IMEI", "imei"], ["Model", "model"], ["Memory", "memory"], ["Color", "color"], ["Battery", "battery", "percent"], ["Source", "source"], ["Job", "job_number"]]
    },
    supplier_progress: {
      title: "Supplier stock progress",
      description: "Supplier and model-wise stock received, pending department, Ready Stock, and exported quantity.",
      columns: []
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
    data_correction: {
      title: "IMEI data correction",
      description: "Search one device and correct its master, receiving, and grade information. Every old and new value is permanently audited.",
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

  function supplierTotal(rows, key) {
    return rows.reduce((total, row) => total + Number(row[key] || 0), 0);
  }

  function renderSupplierProgress() {
    const allRows = reportData.supplier_progress || [];
    const suppliers = [...new Map(allRows.map((row) => [String(row.supplier_id), {
      id: String(row.supplier_id),
      label: [row.supplier_code, row.supplier_name].filter(Boolean).join(" - ")
    }])).values()].sort((left, right) => left.label.localeCompare(right.label));

    if (selectedSupplier !== "all" && !suppliers.some((supplier) => supplier.id === selectedSupplier)) selectedSupplier = "all";
    const rows = selectedSupplier === "all" ? allRows : allRows.filter((row) => String(row.supplier_id) === selectedSupplier);
    const received = supplierTotal(rows, "received_quantity");
    const ready = supplierTotal(rows, "ready_quantity");
    const exported = supplierTotal(rows, "exported_quantity");
    const stagePending = supplierTotal(rows, "initial_qc_pending") + supplierTotal(rows, "lab_glass_pending") + supplierTotal(rows, "parts_pending") + supplierTotal(rows, "final_qc_pending") + supplierTotal(rows, "other_quantity");
    const completedPercent = received ? Math.round(((ready + exported) / received) * 100) : 0;

    panelKicker.textContent = "Supplier progress";
    panelTitle.textContent = "Supplier stock progress";
    panelDescription.textContent = `Models received from ${dateLabel(reportData.date_from)} to ${dateLabel(reportData.date_to)}, with their present workflow position.`;
    rowCount.textContent = `${rows.length} model line${rows.length === 1 ? "" : "s"}`;

    const supplierOptions = suppliers.map((supplier) => `<option value="${escapeHtml(supplier.id)}"${supplier.id === selectedSupplier ? " selected" : ""}>${escapeHtml(supplier.label)}</option>`).join("");
    const tableBody = rows.length ? rows.map((row) => `<tr>
      <td><strong>${escapeHtml(row.supplier_code)}</strong><small>${escapeHtml(row.supplier_name)}</small></td>
      <td>${escapeHtml(row.model)}</td>
      <td>${escapeHtml(row.storage_label || "—")}</td>
      <td>${escapeHtml(row.batch_numbers)}</td>
      <td>${escapeHtml(row.stock_channels)}</td>
      <td>${escapeHtml(row.planned_quantity)}</td>
      <td>${escapeHtml(row.received_quantity)}</td>
      <td class="supplier-count pending">${escapeHtml(row.imei_entry_pending)}</td>
      <td class="supplier-count pending">${escapeHtml(row.initial_qc_pending)}</td>
      <td class="supplier-count pending">${escapeHtml(row.lab_glass_pending)}</td>
      <td class="supplier-count pending">${escapeHtml(row.parts_pending)}</td>
      <td class="supplier-count pending">${escapeHtml(row.final_qc_pending)}</td>
      <td class="supplier-count ready">${escapeHtml(row.ready_quantity)}</td>
      <td class="supplier-count exported">${escapeHtml(row.exported_quantity)}</td>
      <td>${escapeHtml(row.other_quantity)}</td>
    </tr>`).join("") : '<tr><td class="report-empty" colspan="15">No supplier stock was received in this date range.</td></tr>';

    reportContent.innerHTML = `<div class="supplier-report-tools">
      <label>Supplier<select id="supplier-progress-filter"><option value="all">All suppliers</option>${supplierOptions}</select></label>
      <div class="supplier-progress-track"><span style="width:${Math.min(completedPercent, 100)}%"></span></div><strong>${completedPercent}% Ready / Exported</strong>
    </div>
    <div class="supplier-report-summary">
      <article><span>Planned stock</span><strong>${supplierTotal(rows, "planned_quantity")}</strong></article>
      <article><span>IMEIs entered</span><strong>${received}</strong></article>
      <article><span>Workflow pending</span><strong>${stagePending}</strong></article>
      <article class="ready"><span>Ready Stock</span><strong>${ready}</strong></article>
      <article class="exported"><span>Exported</span><strong>${exported}</strong></article>
    </div>
    <div class="report-table-wrap"><table class="report-table supplier-progress-table"><thead><tr>
      <th>Supplier</th><th>Model</th><th>GB</th><th>Batch</th><th>Channel</th><th>Planned</th><th>IMEIs entered</th><th>IMEI entry pending</th><th>Initial QC</th><th>Lab &amp; Glass</th><th>Parts</th><th>Final QC</th><th>Ready Stock</th><th>Exported</th><th>Other</th>
    </tr></thead><tbody>${tableBody}</tbody></table></div>`;
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

  function optionMarkup(options, selectedValue, emptyLabel = "Not set") {
    const selected = String(selectedValue ?? "");
    const values = Array.isArray(options) ? [...options] : [];
    if (selected && !values.some((value) => String(value) === selected)) values.unshift(selected);
    return `<option value="">${escapeHtml(emptyLabel)}</option>${values.map((value) => `<option value="${escapeHtml(value)}"${String(value) === selected ? " selected" : ""}>${escapeHtml(value)}</option>`).join("")}`;
  }

  function supplierOptionMarkup(options, selectedId, selectedLabel) {
    const selected = String(selectedId ?? "");
    const values = Array.isArray(options) ? [...options] : [];
    if (selected && !values.some((option) => String(option.id) === selected)) values.unshift({ id: selected, label: selectedLabel || "Current supplier" });
    return `<option value="">No supplier</option>${values.map((option) => `<option value="${escapeHtml(option.id)}"${String(option.id) === selected ? " selected" : ""}>${escapeHtml(option.label)}</option>`).join("")}`;
  }

  function renderCorrectionHistory(record) {
    const history = Array.isArray(record?.workflow_history) ? record.workflow_history : [];
    if (!history.length) return '<p class="correction-empty">No workflow events have been recorded for this device.</p>';
    return `<div class="correction-timeline">${history.map((event) => `
      <details>
        <summary><span>${escapeHtml(event.title || title(event.event_type))}</span><time>${escapeHtml(dateTime(event.occurred_at))}</time></summary>
        <p>Recorded by ${escapeHtml(event.actor || "System")}</p>
        ${event.details && Object.keys(event.details).length ? `<pre>${escapeHtml(JSON.stringify(event.details, null, 2))}</pre>` : ""}
      </details>`).join("")}</div>`;
  }

  function renderTestDataCleanup() {
    return `
      <section class="test-cleanup-card">
        <div class="test-cleanup-copy">
          <span class="test-cleanup-icon" aria-hidden="true">!</span>
          <div><h3>Reset all operational data to zero</h3><p>Permanently clears every supplier code, customer, stock batch, phone, QC record, Laboratory job, Parts inventory/receipt/issue/return, Ready Stock record, Export Box, correction, and deletion-history entry. Users, permissions, roles, technicians, locations, stock channels, and dropdown options are preserved.</p></div>
        </div>
        <form id="test-data-cleanup-form" class="test-cleanup-form" novalidate>
          <label>Deletion code<input name="deletion_code" type="password" inputmode="numeric" autocomplete="off" placeholder="Enter code" required></label>
          <label>Type RESET GREENLOOP TO ZERO<input name="confirmation" type="text" autocomplete="off" placeholder="RESET GREENLOOP TO ZERO" required></label>
          <button class="danger-button" type="submit">Reset everything to zero</button>
        </form>
      </section>`;
  }

  function renderDataCorrection() {
    panelKicker.textContent = "Management control";
    panelTitle.textContent = "IMEI data correction";
    panelDescription.textContent = "Correct authorised device data without erasing the original workflow. Correction code 1213 and a reason are required.";
    rowCount.textContent = correctionRecord ? "1 device loaded" : "Search required";

    const search = `
      <form id="correction-search-form" class="correction-search" novalidate>
        <label for="correction-identifier">IMEI or device number</label>
        <div><input id="correction-identifier" name="identifier" type="search" autocomplete="off" placeholder="Scan IMEI or enter DEV-000001" required><button class="primary-button" type="submit">Search record</button></div>
      </form>`;

    if (!correctionRecord) {
      reportContent.innerHTML = `<div class="correction-workspace">${search}<div class="correction-welcome"><strong>Search one device to begin.</strong><span>IMEI, device details, supplier, receiving data, grades, notes, and the complete workflow timeline will load here.</span></div>${renderTestDataCleanup()}</div>`;
      return;
    }

    const record = correctionRecord;
    const fields = record.fields || {};
    const grades = record.grade_options || [];
    const finalGradeHelp = record.has_final_pass ? "Required because this device passed Final QC." : "Available only after Final QC pass.";
    reportContent.innerHTML = `
      <div class="correction-workspace">
        ${search}
        <section class="correction-record-head">
          <div><span>Device</span><strong>${escapeHtml(record.device_number)}</strong></div>
          <div><span>Job</span><strong>${escapeHtml(record.job_number || "-")}</strong></div>
          <div><span>Status</span><strong>${escapeHtml(title(record.current_status))}</strong></div>
          <div><span>Supplier</span><strong>${escapeHtml(record.supplier_label || "-")}</strong></div>
          <div><span>Batch</span><strong>${escapeHtml(record.batch_number || "-")}</strong></div>
        </section>
        <form id="correction-save-form" class="correction-form" novalidate>
          <input type="hidden" name="device_id" value="${escapeHtml(record.device_id)}">
          <section class="correction-section">
            <div class="correction-section-title"><span>01</span><div><h3>Device information</h3><p>Correct identification and physical device data.</p></div></div>
            <div class="correction-grid">
              <label>IMEI <em>Required</em><input name="imei" inputmode="numeric" maxlength="15" value="${escapeHtml(fields.imei || "")}" required></label>
              <label>Serial number<input name="serial_number" value="${escapeHtml(fields.serial_number || "")}"></label>
              <label>Brand<input name="brand" value="${escapeHtml(fields.brand || "")}"></label>
              <label>Model<input name="model" value="${escapeHtml(fields.model || "")}"></label>
              <label>GB<input name="storage_gb" type="number" min="1" step="1" value="${escapeHtml(fields.storage_gb ?? "")}"></label>
              <label>Color<input name="color" value="${escapeHtml(fields.color || "")}"></label>
              <label>Battery Health %<input name="battery_health" type="number" min="0" max="100" step="1" value="${escapeHtml(fields.battery_health ?? "")}"></label>
              <label>Device notes<textarea name="device_notes" rows="2">${escapeHtml(fields.device_notes || "")}</textarea></label>
            </div>
          </section>
          <section class="correction-section">
            <div class="correction-section-title"><span>02</span><div><h3>Receiving and grades</h3><p>Correct the supplier, receiving record, and QC grades.</p></div></div>
            <div class="correction-grid">
              <label>Supplier<select name="supplier_id">${supplierOptionMarkup(record.supplier_options, fields.supplier_id, record.supplier_label)}</select></label>
              <label>Receiving source <em>Required</em><input name="receiving_source" value="${escapeHtml(fields.receiving_source || "")}" required></label>
              <label>Purchase cost (AED)<input name="purchase_cost" type="number" min="0" step="0.01" value="${escapeHtml(fields.purchase_cost ?? 0)}"></label>
              <label>Supplier grade<select name="supplier_grade">${optionMarkup(grades, fields.supplier_grade, "Not graded")}</select></label>
              <label>Initial QC grade<select name="initial_grade">${optionMarkup(grades, fields.initial_grade, "Not graded")}</select></label>
              <label>Final QC grade<select name="final_grade"${record.has_final_pass ? " required" : " disabled"}>${optionMarkup(grades, fields.final_grade, "Not graded")}</select><small>${escapeHtml(finalGradeHelp)}</small></label>
              <label class="correction-wide">Job / receiving notes<textarea name="job_notes" rows="2">${escapeHtml(fields.job_notes || "")}</textarea></label>
            </div>
          </section>
          <section class="correction-approval">
            <label class="correction-reason">Correction reason <em>Required</em><textarea name="change_reason" rows="3" placeholder="Explain exactly why this record is being corrected" required></textarea></label>
            <label>Correction code <em>Required</em><input name="correction_code" type="password" inputmode="numeric" autocomplete="off" placeholder="Enter code" required></label>
            <button class="primary-button" type="submit">Save audited correction</button>
          </section>
        </form>
        <section class="correction-history">
          <div class="correction-section-title"><span>03</span><div><h3>Permanent workflow history</h3><p>Past events are never erased. Every correction is added as a new audited event.</p></div></div>
          ${renderCorrectionHistory(record)}
        </section>
        ${renderTestDataCleanup()}
      </div>`;
  }

  function renderChangedFields(value) {
    const changes = value && typeof value === "object" ? value : {};
    const entries = Object.entries(changes);
    if (!entries.length) return "No field details saved.";
    return entries.map(([field, detail]) => `<div class="change-field"><strong>${escapeHtml(title(field))}</strong><span class="change-old">${escapeHtml(detail?.old ?? "-")}</span><b aria-hidden="true">→</b><span class="change-new">${escapeHtml(detail?.new ?? "-")}</span></div>`).join("");
  }

  function renderDeletedHistory() {
    const deletionRows = reportData.deleted_history || [];
    const changeRows = reportData.data_changes || [];
    const rows = auditView === "changes" ? changeRows : deletionRows;
    panelKicker.textContent = "Permanent audit";
    panelTitle.textContent = "Deleted history and data changes";
    panelDescription.textContent = "Nothing is hidden: deleted records and every authorised old/new value correction are saved separately.";
    rowCount.textContent = `${rows.length} record${rows.length === 1 ? "" : "s"}`;

    let table;
    if (auditView === "changes") {
      const body = changeRows.length ? changeRows.map((row) => `<tr>
        <td>${formatCell(row.changed_at, "date")}</td><td>${escapeHtml(row.changed_by || "System")}</td>
        <td>${escapeHtml(row.device_number || "-")}</td><td>${escapeHtml(row.imei_before || "-")}<br><span class="audit-arrow">→ ${escapeHtml(row.imei_after || "-")}</span></td>
        <td>${escapeHtml(row.job_number || "-")}</td><td class="audit-reason">${escapeHtml(row.change_reason || "-")}</td>
        <td><details class="report-deletion-details"><summary>View old / new values</summary><div class="change-fields">${renderChangedFields(row.changed_fields)}</div><details><summary>Full snapshots</summary><pre>${escapeHtml(JSON.stringify({ before: row.before_data, after: row.after_data }, null, 2))}</pre></details></details></td>
      </tr>`).join("") : '<tr><td class="report-empty" colspan="7">No data corrections were found for this date range.</td></tr>';
      table = `<div class="report-table-wrap"><table class="report-table audit-table"><thead><tr><th>Changed at</th><th>Changed by</th><th>Device</th><th>IMEI old → new</th><th>Job</th><th>Reason</th><th>Changes</th></tr></thead><tbody>${body}</tbody></table></div>`;
    } else {
      const report = reports.deleted_history;
      const headers = report.columns.map(([label]) => `<th>${escapeHtml(label)}</th>`).join("");
      const body = deletionRows.length ? deletionRows.map((row) => `<tr>${report.columns.map(([, key, type]) => `<td>${formatCell(row[key], type)}</td>`).join("")}</tr>`).join("") : `<tr><td class="report-empty" colspan="${report.columns.length}">No deleted records were found for this date range.</td></tr>`;
      table = `<div class="report-table-wrap"><table class="report-table"><thead><tr>${headers}</tr></thead><tbody>${body}</tbody></table></div>`;
    }

    reportContent.innerHTML = `<div class="audit-switch"><button type="button" data-audit-view="deleted" class="${auditView === "deleted" ? "active" : ""}">Deleted records <span>${deletionRows.length}</span></button><button type="button" data-audit-view="changes" class="${auditView === "changes" ? "active" : ""}">Data changes <span>${changeRows.length}</span></button></div>${table}`;
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

  async function searchCorrectionRecord(identifier) {
    const cleaned = String(identifier || "").trim();
    if (!cleaned) { setMessage("Enter an IMEI or device number first."); return; }
    setMessage();
    const { data, error } = await getClient().rpc("get_imei_correction_record", { p_identifier: cleaned });
    if (error) { correctionRecord = null; renderDataCorrection(); setMessage(error.message || "The device record could not be loaded."); return; }
    correctionRecord = data || null;
    renderDataCorrection();
    setMessage(`${correctionRecord?.device_number || "Device"} loaded. Review every value before saving.`, "success");
  }

  function optionalNumber(formData, name) {
    const value = String(formData.get(name) ?? "").trim();
    return value === "" ? null : Number(value);
  }

  async function saveCorrection(form) {
    const formData = new FormData(form);
    const submit = form.querySelector('button[type="submit"]');
    submit.disabled = true;
    submit.textContent = "Saving...";
    setMessage();
    const fields = correctionRecord?.fields || {};
    const payload = {
      p_device_id: formData.get("device_id"),
      p_imei: formData.get("imei"),
      p_serial_number: formData.get("serial_number"),
      p_brand: formData.get("brand"),
      p_model: formData.get("model"),
      p_storage_gb: optionalNumber(formData, "storage_gb"),
      p_color: formData.get("color"),
      p_battery_health: optionalNumber(formData, "battery_health"),
      p_supplier_id: formData.get("supplier_id") || null,
      p_supplier_grade: formData.get("supplier_grade"),
      p_initial_grade: formData.get("initial_grade"),
      p_final_grade: correctionRecord?.has_final_pass ? formData.get("final_grade") : (fields.final_grade || null),
      p_receiving_source: formData.get("receiving_source"),
      p_purchase_cost: optionalNumber(formData, "purchase_cost"),
      p_device_notes: formData.get("device_notes"),
      p_job_notes: formData.get("job_notes"),
      p_change_reason: formData.get("change_reason"),
      p_correction_code: formData.get("correction_code")
    };
    const { data, error } = await getClient().rpc("correct_imei_complete_record", payload);
    submit.disabled = false;
    submit.textContent = "Save audited correction";
    if (error) { setMessage(error.message || "The correction could not be saved."); return; }

    const changedCount = Object.keys(data?.changed_fields || {}).length;
    await searchCorrectionRecord(data?.imei || payload.p_imei);
    const { data: changes } = await getClient().rpc("get_data_change_history", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    reportData.data_changes = changes || [];
    setMessage(`${data?.device_number || "Device"} was corrected. ${changedCount} field${changedCount === 1 ? "" : "s"} saved in permanent Data Changes history.`, "success");
  }

  async function deleteAllTestData(form) {
    const formData = new FormData(form);
    const confirmation = String(formData.get("confirmation") || "").trim();
    if (confirmation !== "RESET GREENLOOP TO ZERO") { setMessage("Type RESET GREENLOOP TO ZERO exactly to confirm."); return; }
    const approved = window.confirm("This will permanently delete ALL operational data, including suppliers, phones, parts stock, workflow, export boxes, and audit histories. Dropdowns, users, permissions, and technicians will stay. Continue?");
    if (!approved) return;

    const submit = form.querySelector('button[type="submit"]');
    submit.disabled = true;
    submit.textContent = "Deleting...";
    setMessage();
    const { data, error } = await getClient().rpc("reset_greenloop_to_zero", {
      p_deletion_code: formData.get("deletion_code"),
      p_confirmation: confirmation
    });
    submit.disabled = false;
    submit.textContent = "Reset everything to zero";
    if (error) { setMessage(error.message || "Greenloop data could not be reset."); return; }

    correctionRecord = null;
    await loadReports();
    form.reset();
    setMessage(`Greenloop is now at zero. Deleted: ${Number(data?.deleted_devices || 0)} phone(s), ${Number(data?.deleted_jobs || 0)} job(s), ${Number(data?.deleted_suppliers || 0)} supplier(s), ${Number(data?.deleted_batches || 0)} stock batch(es), ${Number(data?.deleted_inventory_items || 0)} Parts inventory item(s), and ${Number(data?.deleted_export_boxes || 0)} export box(es). Dropdowns, users, permissions, and technicians were preserved.`, "success");
  }

  function renderActiveReport() {
    document.querySelectorAll(".report-tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.report === activeReport));
    if (activeReport === "overview") renderOverview();
    else if (activeReport === "supplier_progress") renderSupplierProgress();
    else if (activeReport === "export_boxes") renderExportBoxes();
    else if (activeReport === "data_correction") renderDataCorrection();
    else if (activeReport === "deleted_history") renderDeletedHistory();
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
    const { data: supplierProgress, error: supplierProgressError } = await getClient().rpc("get_supplier_stock_progress", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    reportData.supplier_progress = supplierProgressError ? [] : (supplierProgress || []);
    if (supplierProgressError) setMessage(supplierProgressError.message || "Supplier Progress report could not be loaded.");
    const { data: deletedHistory, error: deletedHistoryError } = await getClient().rpc("get_deletion_history", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
    reportData.deleted_history = deletedHistoryError ? [] : (deletedHistory || []);
    if (canManageCorrections) {
      const { data: dataChanges, error: dataChangesError } = await getClient().rpc("get_data_change_history", { p_date_from: dateFrom.value, p_date_to: dateTo.value });
      reportData.data_changes = dataChangesError ? [] : (dataChanges || []);
    } else {
      reportData.data_changes = [];
    }
    selectedExportBox = "";
    exportBoxImeiFilter = "";
    selectedSupplier = "all";
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
    const { data: correctionPermission } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager"] });
    canManageCorrections = Boolean(correctionPermission);
    const correctionTab = document.querySelector('[data-report="data_correction"]');
    if (correctionTab) correctionTab.hidden = !canManageCorrections;
    const requestedReport = new URLSearchParams(window.location.search).get("report");
    if (requestedReport && reports[requestedReport] && (requestedReport !== "data_correction" || canManageCorrections)) activeReport = requestedReport;
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
    const auditButton = event.target.closest("[data-audit-view]");
    if (auditButton) {
      auditView = auditButton.dataset.auditView || "deleted";
      renderDeletedHistory();
      return;
    }
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
  reportContent.addEventListener("submit", (event) => {
    if (event.target.id === "correction-search-form") {
      event.preventDefault();
      const formData = new FormData(event.target);
      searchCorrectionRecord(formData.get("identifier")).catch((error) => setMessage(error.message || "The device record could not be loaded."));
      return;
    }
    if (event.target.id === "correction-save-form") {
      event.preventDefault();
      saveCorrection(event.target).catch((error) => setMessage(error.message || "The correction could not be saved."));
      return;
    }
    if (event.target.id === "test-data-cleanup-form") {
      event.preventDefault();
      deleteAllTestData(event.target).catch((error) => setMessage(error.message || "Greenloop data could not be reset."));
    }
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
  reportContent.addEventListener("change", (event) => {
    if (event.target.id !== "supplier-progress-filter") return;
    selectedSupplier = event.target.value || "all";
    renderSupplierProgress();
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Reports could not be loaded."; permissionMessage.hidden = false; });
})();
