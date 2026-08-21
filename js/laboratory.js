(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const isFrameMode = window.location.hash.toLowerCase() === "#frame";
  window.addEventListener("hashchange", () => window.location.reload());
  const standardParts = ["Case", "Glass", "Touch panel", "NFC flex", "Vibrator", "Speaker", "Camera", "Face ID flex", "LCD display", "Battery", "Charging flex"];
  const standardServices = ["Polish", "Cleaning", "Software", "Testing", "Face ID calibration", "Camera calibration", "Housing repair", "Glass work", "Frame work"];
  const initialQcServices = new Set(["polish", "cleaning", "software", "testing"]);
  const app = document.querySelector("#lab-app");
  const permissionMessage = document.querySelector("#permission-message");
  const technicianCards = document.querySelector("#technician-cards");
  const technicianBoard = document.querySelector("#technician-board");
  const linesKicker = document.querySelector("#lines-kicker");
  const linesHead = document.querySelector("#technician-lines-head");
  const refreshFrameButton = document.querySelector("#refresh-frame");
  const technicianBoardTitle = document.querySelector("#technician-board-title");
  const technicianLinesTitle = document.querySelector("#technician-lines-title");
  const technicianLinesHelp = document.querySelector("#technician-lines-help");
  const technicianLinesCount = document.querySelector("#technician-lines-count");
  const technicianWorkRows = document.querySelector("#technician-work-rows");
  const technicianImeiScanWrap = document.querySelector("#technician-imei-scan-wrap");
  const technicianImeiScan = document.querySelector("#technician-imei-scan");
  const checkTechnicianImei = document.querySelector("#check-technician-imei");
  const frameReportPanel = document.querySelector("#frame-report-panel");
  const frameReportRows = document.querySelector("#frame-report-rows");
  const framePassCount = document.querySelector("#frame-pass-count");
  const frameFailCount = document.querySelector("#frame-fail-count");
  const boardMessage = document.querySelector("#lab-board-message");
  const addTechnicianButton = document.querySelector("#add-lab-technician");
  const removeTechnicianButton = document.querySelector("#remove-lab-technician");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let technicians = [];
  let technicianRows = [];
  let activeTechnicianId = "";
  let partOptions = [...standardParts];
  const lineDrafts = new Map();
  let toastTimer;

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]); }
  function normalise(value) { return String(value || "").trim().replace(/\s+/g, " ").toLowerCase(); }
  function unique(values) { const seen = new Set(); return values.map((value) => String(value || "").trim()).filter((value) => value && !seen.has(normalise(value)) && seen.add(normalise(value))); }
  function asList(value) { if (Array.isArray(value)) return value; if (!value) return []; try { return JSON.parse(value); } catch { return []; } }
  function initials(value) { return String(value || "T").trim().split(/\s+/).slice(0,2).map((part) => part[0] || "").join("").toUpperCase() || "T"; }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function setBoardMessage(text = "", success = false) { boardMessage.textContent = text; boardMessage.classList.toggle("is-visible", Boolean(text)); boardMessage.classList.toggle("is-success", success); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3500); }
  function setSubmitting(button, busy, text) { if (busy) button.dataset.label = button.textContent.trim(); button.disabled = busy; button.textContent = busy ? text : button.dataset.label || button.textContent; }

  function configureMode() {
    if (!isFrameMode) return;
    document.body.classList.add("frame-mode");
    document.title = "Frame Department | Greenloop";
    document.querySelector("#breadcrumb-stage").textContent = "Frame Department";
    document.querySelector("#page-title").textContent = "Frame Department";
    document.querySelector("#page-subtitle").textContent = "Phones selected as Pass + Frame in Final QC appear here as compact lines.";
    document.querySelector(".lab-heading .quiet-link").href = "final-qc.html";
    document.querySelector(".lab-heading .quiet-link").textContent = "← Back to Final QC";
    technicianBoard.hidden = true;
    technicianImeiScanWrap.hidden = true;
    frameReportPanel.hidden = false;
    linesKicker.textContent = "Frame queue";
    technicianLinesTitle.textContent = "Phones waiting for Frame completion";
    technicianLinesHelp.textContent = "Select exactly one result. Pass sends to Ready Stock; Fail stays in Frame and is recorded.";
    refreshFrameButton.hidden = false;
    linesHead.innerHTML = "<th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>BH</th><th>Supplier code</th><th>Supplier grade</th><th>Initial grade</th><th>Final grade</th><th>Pass</th><th>Fail</th><th>Save</th>";
    document.querySelector("#workflow-rule-text").textContent = "Frame Pass sends the phone directly to Ready Stock. Frame Fail keeps it pending in Frame and adds to the permanent failure report.";
  }

  function renderTechnicianCards() {
    technicianCards.innerHTML = technicians.length ? technicians.map((technician) => {
      const count = Number(technician.pending_count || 0);
      const active = String(technician.id) === String(activeTechnicianId);
      return `<button class="technician-card${active ? " is-active" : ""}" type="button" data-technician-id="${escapeHtml(technician.id)}" aria-pressed="${active}"><span class="technician-avatar">${escapeHtml(initials(technician.full_name))}</span><span class="technician-card-copy"><strong>${escapeHtml(technician.full_name)}</strong><span>${count} assigned IMEI${count === 1 ? "" : "s"}</span></span><span class="technician-card-count${count ? "" : " is-zero"}">${count > 99 ? "99+" : count}</span></button>`;
    }).join("") : '<p class="technician-lines-empty">No technicians are available.</p>';
    const selected = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    technicianBoardTitle.textContent = selected ? `${selected.full_name}'s assigned work` : "Select a technician";
    technicianLinesTitle.textContent = selected ? `${selected.full_name}'s phone lines` : "Assigned phone lines";
    removeTechnicianButton.disabled = !selected;
    technicianImeiScan.disabled = !selected;
    checkTechnicianImei.disabled = !selected;
    technicianImeiScan.placeholder = selected ? `Scan IMEI assigned to ${selected.full_name}` : "Select technician first";
  }

  function optionsMarkup(options, placeholder) { return `<option value="">${escapeHtml(placeholder)}</option>${options.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("")}`; }
  function initialNames(items, requiredOnly = false) { return unique(asList(items).filter((item) => !requiredOnly || item.lab_decision !== "not_required").map((item) => item.name)); }
  function isInitialQcService(name) { return initialQcServices.has(normalise(name)); }
  function isReturnedPartRequest(item, row) {
    const status = normalise(item?.status).replaceAll(" ", "_");
    const hasActiveReturn = asList(row?.pending_part_returns).some((request) =>
      String(request.part_request_id) === String(item?.id) && ["pending", "approved"].includes(normalise(request.status))
    );
    return hasActiveReturn || status === "cancelled" || status === "unused_returned" ||
      (Number(item?.issued || 0) > 0 && Number(item?.returned || 0) >= Number(item?.issued || 0) && Number(item?.installed || 0) === 0);
  }
  function allLabPartRequests(row) { return asList(row.lab_part_requests); }
  function activeLabPartRequests(row) { return allLabPartRequests(row).filter((item) => !isReturnedPartRequest(item, row)); }
  function initialServiceNames(row, requiredOnly = false) {
    return unique(asList(row.initial_services)
      .filter((item) => !requiredOnly || item.lab_decision !== "not_required")
      .map((item) => item.name)
      .filter(isInitialQcService));
  }
  function labPartNames(row) {
    const allRequests = allLabPartRequests(row);
    const activeNames = unique(activeLabPartRequests(row).map((item) => item.name));
    if (allRequests.length) return activeNames;
    return initialNames(row.initial_parts).filter((name) => !asList(row.initial_parts).some((item) => normalise(item.name) === normalise(name) && ["not_required", "unused_returned", "cancelled"].includes(normalise(item.status))));
  }
  function labServiceNames(row) {
    const reviewed = asList(row.lab_services);
    if (reviewed.length) return unique(reviewed
      .filter((item) => item.required !== false)
      .filter((item) => item.source !== "initial_qc" || isInitialQcService(item.name))
      .map((item) => item.name));
    return initialServiceNames(row, true);
  }
  function readOnlyList(values) { const list = unique(values); return list.length ? `<div class="line-list">${list.map((value) => `<span>${escapeHtml(value)}</span>`).join("")}</div>` : '<span class="line-empty">None</span>'; }
  function choiceCell(kind, options, selected) {
    return `<div class="lab-choice" data-choice="${kind}"><div class="lab-choice-row"><select>${optionsMarkup(options, kind === "part" ? "Select part" : "Select service")}</select><button type="button" data-add-choice="${kind}" title="Add">+</button></div><div class="lab-choice-tags">${unique(selected).map((value) => `<button type="button" data-remove-choice="${kind}" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`).join("")}</div></div>`;
  }
  function selectedChoices(row, kind) {
    const tags = [...row.querySelectorAll(`[data-choice="${kind}"] [data-remove-choice]`)].map((button) => button.dataset.value);
    const currentSelection = row.querySelector(`[data-choice="${kind}"] select`)?.value || "";
    return unique([...tags, currentSelection]);
  }
  function rememberLineDraft(row) {
    if (!row?.dataset.stepId) return;
    lineDrafts.set(String(row.dataset.stepId), {
      parts: selectedChoices(row, "part"),
      services: selectedChoices(row, "service")
    });
  }
  function labelledStatic(label, value, className = "") {
    return `<div class="lab-static-field ${className}"><span class="lab-field-label">${escapeHtml(label)}</span><div class="lab-static-value">${value}</div></div>`;
  }
  function repeatPartOptions(row) {
    return unique([...partOptions, ...initialNames(row.initial_parts), ...labPartNames(row)]);
  }
  function repeatReasonMarkup() {
    return `<option value="">Select repeat reason</option><option value="faulty_part">Faulty Part</option><option value="technician_damage">Damaged by Technician</option><option value="other">Other</option>`;
  }
  function lineWorkflowState(row) {
    const allRequests = allLabPartRequests(row);
    const requests = activeLabPartRequests(row);
    const pendingReturns = asList(row.pending_part_returns).filter((item) => item.status === "pending");
    const initialParts = asList(row.initial_parts);
    const submitted = allRequests.length > 0 || asList(row.lab_services).length > 0 || initialParts.some((item) => ["requested", "not_required", "unused_returned"].includes(String(item.status)));
    const needsParts = requests.length > 0 || labPartNames(row).length > 0;
    const allIssued = submitted && (!needsParts || (requests.length > 0 && requests.every((item) => Number(item.issued || 0) >= Number(item.quantity || 1))));
    return { requests, pendingReturns, submitted, allIssued, hasParts: needsParts };
  }
  function linePartVisual(row) {
    const state = lineWorkflowState(row);
    const needsParts = state.hasParts;
    if (state.pendingReturns.length) return { className: "parts-pending", label: "Return pending" };
    if (needsParts && !state.allIssued) return { className: "parts-pending", label: "Parts pending" };
    return { className: "parts-issued", label: needsParts ? "Parts issued" : "No parts required" };
  }
  function actionCell(row) {
    const state = lineWorkflowState(row);
    if (state.pendingReturns.length) {
      const names = unique(state.pendingReturns.map((item) => item.part_name)).join(", ");
      return `<button class="line-save line-state return-pending" type="button" disabled>Return Pending</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}" disabled>✓ Job Completed</button><small class="line-status" data-line-status>Parts approval: ${escapeHtml(names)}</small>`;
    }
    if (!state.submitted) {
      const plannedParts = labPartNames(row);
      const plannedServices = labServiceNames(row);
      if (!plannedParts.length && !plannedServices.length) {
        return `<button class="line-save line-state parts-issued" type="button" data-order-parts="${escapeHtml(row.step_id)}" disabled>✓ No Parts Required</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}">✓ Job Completed</button><small class="line-status success" data-line-status>Ready to send to Final QC</small>`;
      }
      const label = plannedParts.length ? "Request Parts" : "Save Services";
      const help = plannedParts.length ? "Send only selected parts to Parts Department" : "Save services; no Parts notification will be sent";
      return `<button class="line-save order-parts" type="button" data-order-parts="${escapeHtml(row.step_id)}">${label}</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}" disabled>✓ Job Completed</button><small class="line-status" data-line-status>${help}</small>`;
    }
    if (!state.allIssued) {
      return `<button class="line-save line-state parts-ordered" type="button" data-order-parts="${escapeHtml(row.step_id)}" disabled>Parts Ordered</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}" disabled>✓ Job Completed</button><small class="line-status" data-line-status>Waiting for Parts Department</small>`;
    }
    const issuedLabel = state.hasParts ? "✓ Parts Issued" : "✓ No Parts Required";
    return `<button class="line-save line-state parts-issued" type="button" data-order-parts="${escapeHtml(row.step_id)}" disabled>${issuedLabel}</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}">✓ Job Completed</button><small class="line-status success" data-line-status>Ready to send to Final QC</small>`;
  }
  function returnableParts(row) {
    return activeLabPartRequests(row).filter((item) => Number(item.issued || 0) - Number(item.installed || 0) - Number(item.returned || 0) > 0);
  }
  function issuedPartTools(row) {
    const state = lineWorkflowState(row);
    if (!state.allIssued || !state.hasParts) return "";
    const parts = returnableParts(row);
    if (!parts.length) return "";
    const options = parts.map((part) => {
      const available = Number(part.issued || 0) - Number(part.installed || 0) - Number(part.returned || 0);
      return `<option value="${escapeHtml(part.id)}">${escapeHtml(part.name)} · ${available} issued</option>`;
    }).join("");
    return `<details class="lab-issued-tools"><summary>Manage issued parts</summary><div class="lab-issued-manager"><label class="lab-issued-part-select"><span class="lab-field-label">Part name</span><select data-return-part-select><option value="">Select issued part</option>${options}</select></label><fieldset class="lab-return-reasons"><legend>Reason — tick one</legend><label class="lab-return-reason damaged"><input type="checkbox" data-return-reason value="damaged"><span>Damage</span></label><label class="lab-return-reason faulty"><input type="checkbox" data-return-reason value="faulty"><span>Faulty</span></label><label class="lab-return-reason not-needed"><input type="checkbox" data-return-reason value="not_needed"><span>Not Needed</span></label></fieldset><p class="lab-return-rule">Damage and Faulty never return to usable Inventory. Not Needed returns to Inventory only after Parts approval.</p></div></details>`;
  }
  function rowData(rowElement) {
    return technicianRows.find((item) => String(item.step_id) === String(rowElement.dataset.stepId));
  }
  function renderTechnicianLines() {
    const selectedTech = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    const filtered = technicianRows.filter((row) => isFrameMode ? String(row.department) === "frame" : ["laboratory", "glass"].includes(String(row.department)));
    technicianLinesCount.textContent = `${filtered.length} line${filtered.length === 1 ? "" : "s"}`;
    if (!activeTechnicianId) { technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">Select a technician.</td></tr>'; return; }
    if (!filtered.length) { technicianWorkRows.innerHTML = `<tr><td colspan="12" class="technician-lines-empty">${escapeHtml(selectedTech?.full_name || "This technician")} has no ${isFrameMode ? "Frame" : "Laboratory"} phones pending.</td></tr>`; return; }
    technicianWorkRows.innerHTML = filtered.map((row) => {
      const qcParts = initialNames(row.initial_parts);
      const qcServices = initialServiceNames(row);
      const supplier = typeof window.GREENLOOP_PARTNER_LABEL === "function"
        ? window.GREENLOOP_PARTNER_LABEL(row.supplier_code, row.supplier_name, "—")
        : (row.supplier_code || "—");
      const saveCell = isFrameMode
        ? `<button class="line-save frame" type="button" data-complete-frame="${escapeHtml(row.step_id)}">Complete Frame</button><small class="line-status">Returns to Final QC</small>`
        : actionCell(row);
      if (isFrameMode) {
        return `<tr data-step-id="${escapeHtml(row.step_id)}"><td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong><small class="line-supplier">${escapeHtml(supplier)}</small></td><td>${escapeHtml(row.model || "—")}</td><td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td><td>${escapeHtml(row.color || "—")}</td><td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td><td>${readOnlyList(qcParts)}</td><td>${readOnlyList(qcServices)}</td><td>${readOnlyList(labPartNames(row))}</td><td>${readOnlyList(labServiceNames(row))}</td><td>—</td><td>—</td><td>${saveCell}</td></tr>`;
      }
      const staticLine = [
        labelledStatic("IMEI", `<strong class="line-imei">${escapeHtml(row.imei || "—")}</strong>`, "imei"),
        labelledStatic("Model", escapeHtml(row.model || "—")),
        labelledStatic("GB", escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)),
        labelledStatic("Color", escapeHtml(row.color || "—")),
        labelledStatic("BH", escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)),
        labelledStatic("Supplier Code", escapeHtml(supplier), "supplier"),
        labelledStatic("Initial QC Parts", readOnlyList(qcParts)),
        labelledStatic("Initial QC Service", readOnlyList(qcServices))
      ].join("");
      const visual = linePartVisual(row);
      const draft = lineDrafts.get(String(row.step_id));
      const displayedParts = draft?.parts || labPartNames(row);
      const displayedServices = draft?.services || labServiceNames(row);
      return `<tr class="lab-phone-row ${visual.className}" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card"><div class="lab-card-status"><span>${escapeHtml(visual.label)}</span></div><div class="lab-static-grid">${staticLine}</div><div class="lab-edit-grid"><div class="lab-edit-field lab-parts-field"><span class="lab-field-label">Final parts required</span>${choiceCell("part", partOptions, displayedParts)}</div><div class="lab-edit-field"><span class="lab-field-label">Final services required</span>${choiceCell("service", standardServices, displayedServices)}</div><div class="lab-line-actions">${saveCell}${issuedPartTools(row)}</div></div></article></td></tr>`;
    }).join("");
  }

  function renderFrameLines() {
    technicianLinesCount.textContent = `${technicianRows.length} waiting`;
    if (!technicianRows.length) {
      technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">No phones are waiting in Frame.</td></tr>';
      return;
    }
    technicianWorkRows.innerHTML = technicianRows.map((row) => {
      const supplier = typeof window.GREENLOOP_PARTNER_LABEL === "function"
        ? window.GREENLOOP_PARTNER_LABEL(row.supplier_code, row.supplier_name, "—")
        : (row.supplier_code || "—");
      return `<tr data-step-id="${escapeHtml(row.step_id)}">
        <td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong></td>
        <td>${escapeHtml(row.model || "—")}</td>
        <td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td>
        <td>${escapeHtml(row.color || "—")}</td>
        <td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td>
        <td class="frame-supplier">${escapeHtml(supplier)}</td>
        <td>${escapeHtml(row.supplier_grade || "—")}</td>
        <td>${escapeHtml(row.initial_grade || "—")}</td>
        <td>${escapeHtml(row.final_grade || "—")}</td>
        <td><label class="frame-pass-check"><input type="checkbox" data-frame-result="pass"><span>Pass</span></label></td>
        <td><label class="frame-fail-check"><input type="checkbox" data-frame-result="fail"><span>Fail</span></label></td>
        <td><button class="line-save frame-ready" type="button" data-complete-frame="${escapeHtml(row.step_id)}" disabled>Save</button><small class="line-status">Select Pass or Fail</small></td>
      </tr>`;
    }).join("");
  }

  function formatDateTime(value) {
    return value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  }

  async function loadFrameReport() {
    const { data, error } = await getClient().rpc("get_frame_department_report", { p_limit: 250 });
    if (error) throw error;
    const rows = data || [];
    framePassCount.textContent = `${rows.filter((row) => row.result === "pass").length} Pass`;
    frameFailCount.textContent = `${rows.filter((row) => row.result === "fail").length} Fail`;
    frameReportRows.innerHTML = rows.length ? rows.map((row) => `<tr><td>${escapeHtml(formatDateTime(row.reviewed_at))}</td><td><strong>${escapeHtml(row.imei || "—")}</strong></td><td>${escapeHtml(row.supplier_code || "—")}</td><td>${escapeHtml(row.model || "—")}</td><td><span class="frame-result ${escapeHtml(row.result)}">${escapeHtml(String(row.result || "").toUpperCase())}</span></td><td>${escapeHtml(row.reviewed_by_name || "System")}</td></tr>`).join("") : '<tr><td colspan="6" class="technician-lines-empty">No Frame results recorded yet.</td></tr>';
  }

  async function loadPartOptions() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "part_name" });
    if (!error && data?.length) partOptions = unique([...standardParts, ...data.map((item) => item.option_value)]);
  }
  async function loadTechnicianRows() {
    setBoardMessage();
    if (!activeTechnicianId) { technicianRows = []; renderTechnicianLines(); return; }
    const [rowResponse, returnResponse] = await Promise.all([
      getClient().rpc("get_lab_technician_rows", { p_technician_id: activeTechnicianId }),
      getClient().rpc("get_lab_part_return_requests_for_technician", { p_technician_id: activeTechnicianId })
    ]);
    if (rowResponse.error) throw rowResponse.error;
    if (returnResponse.error) throw returnResponse.error;
    const pendingByStep = new Map();
    (returnResponse.data || []).forEach((item) => {
      const key = String(item.work_order_step_id);
      pendingByStep.set(key, [...(pendingByStep.get(key) || []), item]);
    });
    technicianRows = (rowResponse.data || []).map((row) => ({ ...row, pending_part_returns: pendingByStep.get(String(row.step_id)) || [] }));
    renderTechnicianLines();
  }
  async function loadFrameRows() {
    setBoardMessage();
    const { data, error } = await getClient().rpc("get_frame_department_rows");
    if (error) throw error;
    technicianRows = data || [];
    renderFrameLines();
    await loadFrameReport();
  }
  async function loadTechnicians(preferredId = activeTechnicianId) {
    const { data, error } = await getClient().rpc("get_lab_technician_workboard_by_stage", { p_stage: isFrameMode ? "frame" : "laboratory" });
    if (error) throw error;
    technicians = data || [];
    activeTechnicianId = technicians.some((item) => String(item.id) === String(preferredId)) ? String(preferredId) : String(technicians.find((item) => Number(item.pending_count || 0) > 0)?.id || technicians[0]?.id || "");
    renderTechnicianCards();
  }
  async function refreshAll() {
    if (isFrameMode) { await loadFrameRows(); return; }
    await loadTechnicians(activeTechnicianId);
    await loadTechnicianRows();
  }

  function technicianEditorIsActive() {
    const active = document.activeElement;
    if (!active || !technicianWorkRows.contains(active)) return false;
    return active.matches("select, input, textarea");
  }

  async function addTechnician() {
    const fullName = window.prompt("Enter the technician name:");
    if (!fullName?.trim()) return;
    setSubmitting(addTechnicianButton, true, "Adding...");
    const { data, error } = await getClient().rpc("add_lab_technician", { p_full_name: fullName.trim() });
    setSubmitting(addTechnicianButton, false);
    if (error) throw error;
    const saved = data?.[0] || data;
    activeTechnicianId = String(saved?.id || "");
    await refreshAll();
    showToast("Technician added.");
  }
  async function removeTechnician() {
    const technician = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    if (!technician) return;
    if (Number(technician.pending_count || 0) > 0) throw new Error("Complete or move this technician's pending IMEIs first.");
    if (window.prompt(`Enter deletion code to remove ${technician.full_name}:`) !== "1213") return;
    const { error } = await getClient().rpc("remove_lab_technician", { p_technician_id: technician.id, p_deletion_code: "1213" });
    if (error) throw error;
    activeTechnicianId = "";
    await refreshAll();
  }

  function addChoice(button) {
    const holder = button.closest("[data-choice]");
    const select = holder.querySelector("select");
    const value = select.value;
    if (!value || selectedChoices(button.closest("tr"), holder.dataset.choice).some((item) => normalise(item) === normalise(value))) return;
    holder.querySelector(".lab-choice-tags").insertAdjacentHTML("beforeend", `<button type="button" data-remove-choice="${holder.dataset.choice}" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`);
    select.value = "";
    rememberLineDraft(button.closest("tr"));
    markLineChanged(button.closest("tr"));
  }
  function addSelectedChoice(select) {
    const holder = select.closest("[data-choice]");
    const row = select.closest("tr");
    const value = select.value;
    if (!holder || !row || !value) return;
    const existing = [...holder.querySelectorAll("[data-remove-choice]")]
      .some((button) => normalise(button.dataset.value) === normalise(value));
    if (!existing) {
      holder.querySelector(".lab-choice-tags").insertAdjacentHTML(
        "beforeend",
        `<button type="button" data-remove-choice="${holder.dataset.choice}" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`
      );
    }
    rememberLineDraft(row);
    row.dataset.editing = "true";
    markLineChanged(row);
  }
  function markLineChanged(row) {
    const orderButton = row.querySelector("[data-order-parts]");
    const completeButton = row.querySelector("[data-complete-lab]");
    const status = row.querySelector("[data-line-status]");
    if (!orderButton) return;
    row.dataset.dirty = "true";
    orderButton.disabled = false;
    const returnPart = row.querySelector("[data-return-part-select]")?.value || "";
    const returnReason = row.querySelector("[data-return-reason]:checked")?.value || "";
    const selectedParts = selectedChoices(row, "part");
    orderButton.textContent = returnPart || returnReason ? "Submit Part Return" : selectedParts.length ? "Request Parts" : "Save Services";
    orderButton.className = "line-save order-parts";
    if (completeButton) completeButton.disabled = true;
    if (status) {
      status.textContent = "Submit the updated order before completing the job";
      status.className = "line-status";
    }
  }
  async function orderParts(button) {
    const row = button.closest("tr");
    const status = row.querySelector("[data-line-status]");
    const requestId = row.querySelector("[data-return-part-select]")?.value || "";
    const returnReason = row.querySelector("[data-return-reason]:checked")?.value || "";
    if (requestId || returnReason) {
      if (!requestId || !returnReason) {
        status.textContent = "Select one issued part and tick exactly one reason.";
        status.className = "line-status error";
        return;
      }
      setSubmitting(button, true, "Submitting...");
      const { error } = await getClient().rpc("request_lab_part_return", {
        p_work_order_step_id: row.dataset.stepId,
        p_part_request_id: requestId,
        p_return_reason: returnReason
      });
      setSubmitting(button, false);
      if (error) { status.textContent = error.message; status.className = "line-status error"; return; }
      showToast("Return sent to Parts Department for approval. Inventory was not changed.");
      document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
      await refreshAll();
      return;
    }
    const selectedParts = selectedChoices(row, "part");
    const selectedServices = selectedChoices(row, "service");
    rememberLineDraft(row);
    setSubmitting(button, true, "Saving...");
    const { data, error } = await getClient().rpc("save_lab_technician_line_v2", {
      p_work_order_step_id: row.dataset.stepId,
      p_lab_parts: selectedParts,
      p_lab_services: selectedServices,
      p_extra_parts: [],
      p_extra_services: [],
      p_repeat_part: null,
      p_repeat_reason: null
    });
    setSubmitting(button, false);
    if (error) { status.textContent = error.message; status.className = "line-status error"; return; }
    lineDrafts.delete(String(row.dataset.stepId));
    const notifications = Number(data?.parts_notified || 0) + (data?.repeat_part_requested ? 1 : 0);
    status.textContent = data?.repeat_part_requested ? `${notifications} part notification(s); repeat order #${Number(data.repeat_number || 2)}` : `${notifications} part notification(s)`;
    status.className = "line-status success";
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    showToast("Parts order submitted. Services were saved without a Parts notification.");
    await refreshAll();
  }
  async function completeLab(button) {
    setSubmitting(button, true, "Completing...");
    const { error } = await getClient().rpc("complete_lab_technician_line", { p_work_order_step_id: button.dataset.completeLab });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast("Job completed. Phone sent to Final QC.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }
  async function scanTechnicianImei() {
    const imei = technicianImeiScan.value.replace(/\D/g, "");
    if (!activeTechnicianId) { setBoardMessage("Select a technician first."); return; }
    if (imei.length !== 15) { setBoardMessage("Scan a valid 15-digit IMEI."); return; }
    const { data, error } = await getClient().rpc("resolve_lab_imei_for_technician", {
      p_technician_id: activeTechnicianId,
      p_imei: imei
    });
    if (error) { setBoardMessage(error.message); technicianImeiScan.select(); return; }
    const row = technicianWorkRows.querySelector(`tr[data-step-id="${CSS.escape(String(data.step_id))}"]`);
    if (!row) { await loadTechnicianRows(); }
    const target = technicianWorkRows.querySelector(`tr[data-step-id="${CSS.escape(String(data.step_id))}"]`);
    if (!target) { setBoardMessage("The IMEI is assigned correctly but its line could not be displayed."); return; }
    setBoardMessage(`IMEI ${data.imei} belongs to ${data.technician_name}.`, true);
    target.classList.add("scan-match");
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    window.setTimeout(() => target.classList.remove("scan-match"), 2600);
    technicianImeiScan.value = "";
    technicianImeiScan.focus();
  }
  async function completeFrame(button) {
    const row = button.closest("tr");
    const result = row.querySelector("[data-frame-result]:checked")?.dataset.frameResult || "";
    if (!result) return;
    setSubmitting(button, true, "Saving...");
    const { error } = await getClient().rpc("record_frame_department_result", {
      p_work_order_step_id: button.dataset.completeFrame,
      p_result: result,
      p_notes: result === "pass" ? "Frame work passed" : "Frame work failed; remains pending"
    });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast(result === "pass" ? "Frame passed. Phone sent directly to Ready Stock." : "Frame failed. Phone remains in Frame and the failure was recorded.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }

  async function initialize() {
    configureMode();
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "technician"] });
    if (error) throw error;
    if (!allowed) { permissionMessage.textContent = "Your account does not have Laboratory permission."; permissionMessage.hidden = false; return; }
    app.hidden = false;
    if (!isFrameMode) await loadPartOptions();
    await refreshAll();
    if (!isFrameMode) {
      window.setInterval(() => {
        if (
          document.visibilityState !== "visible"
          || app.hidden
          || technicianEditorIsActive()
          || technicianWorkRows.querySelector('tr[data-dirty="true"], tr[data-editing="true"]')
        ) return;
        loadTechnicianRows().catch(() => {});
      }, 12000);
    }
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-lab").addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  refreshFrameButton.addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  addTechnicianButton.addEventListener("click", () => addTechnician().catch((error) => setBoardMessage(error.message)));
  removeTechnicianButton.addEventListener("click", () => removeTechnician().catch((error) => setBoardMessage(error.message)));
  technicianCards.addEventListener("click", (event) => { const card = event.target.closest("[data-technician-id]"); if (!card) return; activeTechnicianId = card.dataset.technicianId; renderTechnicianCards(); loadTechnicianRows().catch((error) => setBoardMessage(error.message)); });
  technicianImeiScan.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    scanTechnicianImei().catch((error) => setBoardMessage(error.message));
  });
  checkTechnicianImei.addEventListener("click", () => scanTechnicianImei().catch((error) => setBoardMessage(error.message)));
  technicianWorkRows.addEventListener("click", (event) => {
    const add = event.target.closest("[data-add-choice]"); if (add) { addChoice(add); return; }
    const remove = event.target.closest("[data-remove-choice]"); if (remove) {
      const row = remove.closest("tr");
      const holder = remove.closest("[data-choice]");
      const select = holder?.querySelector("select");
      if (select && normalise(select.value) === normalise(remove.dataset.value)) select.value = "";
      remove.remove();
      rememberLineDraft(row);
      markLineChanged(row);
      return;
    }
    const order = event.target.closest("[data-order-parts]"); if (order && !order.disabled) orderParts(order).catch((error) => setBoardMessage(error.message));
    const completeLabButton = event.target.closest("[data-complete-lab]"); if (completeLabButton) completeLab(completeLabButton).catch((error) => setBoardMessage(error.message));
    const completeFrameButton = event.target.closest("[data-complete-frame]"); if (completeFrameButton) completeFrame(completeFrameButton).catch((error) => setBoardMessage(error.message));
  });
  technicianWorkRows.addEventListener("change", (event) => {
    const choiceSelect = event.target.closest('[data-choice] select');
    if (choiceSelect) {
      addSelectedChoice(choiceSelect);
      return;
    }
    const returnControl = event.target.closest("[data-return-part-select], [data-return-reason]");
    if (returnControl) {
      const row = returnControl.closest("tr");
      if (returnControl.matches("[data-return-reason]") && returnControl.checked) {
        row.querySelectorAll("[data-return-reason]").forEach((other) => { if (other !== returnControl) other.checked = false; });
      }
      row.dataset.editing = "true";
      markLineChanged(row);
      return;
    }
    const checkbox = event.target.closest("[data-frame-result]");
    if (!checkbox) return;
    const row = checkbox.closest("tr");
    if (checkbox.checked) row.querySelectorAll("[data-frame-result]").forEach((other) => { if (other !== checkbox) other.checked = false; });
    const button = row.querySelector("[data-complete-frame]");
    const status = row.querySelector(".line-status");
    const result = row.querySelector("[data-frame-result]:checked")?.dataset.frameResult || "";
    button.disabled = !result;
    status.textContent = result === "pass" ? "Will move to Ready Stock" : result === "fail" ? "Will stay in Frame" : "Select Pass or Fail";
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
