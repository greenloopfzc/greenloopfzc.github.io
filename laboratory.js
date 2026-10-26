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
  const framePendingPanel = document.querySelector("#frame-pending-panel");
  const frameViewTabs = document.querySelector("#frame-view-tabs");
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
  let manualLabPartsMode = false;
  let frameGradeItems = [];
  const lineDrafts = new Map();
  let toastTimer;
  let rowLoadVersion = 0;
  let editVersion = 0;
  let focusedImei = "", focusedStepId = "", imeiLookupVersion = 0, imeiTimer, pendingImei = "";
  const clearTechnicianImei = document.querySelector("#clear-technician-imei");
  const searchable = () => !isFrameMode && window.GREENLOOP_PAGE_ACCESS?.pageKey === "lab_glass" && window.GREENLOOP_CAN?.("search", "lab_glass") === true;

  const editable = () => window.GREENLOOP_PAGE_ACCESS?.pageKey === (isFrameMode ? "frame_department" : "lab_glass") && window.GREENLOOP_PAGE_ACCESS.canEdit === true;

  function getClient() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]); }
  function normalise(value) { return String(value || "").trim().replace(/\s+/g, " ").toLowerCase(); }
  function unique(values) { const seen = new Set(); return values.map((value) => String(value || "").trim()).filter((value) => value && !seen.has(normalise(value)) && seen.add(normalise(value))); }
  function asList(value) { if (Array.isArray(value)) return value; if (!value) return []; try { return JSON.parse(value); } catch { return []; } }
  function initials(value) { return String(value || "T").trim().split(/\s+/).slice(0,2).map((part) => part[0] || "").join("").toUpperCase() || "T"; }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function setBoardMessage(text = "", success = false) { boardMessage.textContent = text; boardMessage.classList.toggle("is-visible", Boolean(text)); boardMessage.classList.toggle("is-success", success); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3500); }
  function setSubmitting(button, busy, text) { if (busy) button.dataset.label = button.textContent.trim(); button.disabled = busy; button.textContent = busy ? text : button.dataset.label || button.textContent; }

  const workFilters=window.GREENLOOP_FILTERS.get('lab-work-filters',{
    before:technicianWorkRows.closest('.technician-lines-scroll'),
    search:isFrameMode,
    fields:[['model','Model'],['storage_gb','GB'],['color','Color'],['supplier_code','Supplier code'],...(!isFrameMode ? [['department','Department']] : [])],
    searchFields:['imei','device_number','serial_number','model','supplier_code','invoice_number'],
    onChange:applyWorkFilters
  });
  function applyWorkFilters(){
    const elements=[...technicianWorkRows.querySelectorAll('tr[data-step-id]')];
    const rows=elements.map(el=>technicianRows.find(row=>String(row.step_id)===el.dataset.stepId)||{});
    workFilters.bind(rows,elements);
  }
  new MutationObserver(applyWorkFilters).observe(technicianWorkRows,{childList:true});

  function configureMode() {
    if (!isFrameMode) return;
    document.body.classList.add("frame-mode");
    document.title = "Frame Department | Greenloop";
    document.querySelector("#breadcrumb-stage").textContent = "Frame Department";
    document.querySelector("#page-title").textContent = "Frame Department";
    document.querySelector("#page-subtitle").textContent = "Complete pending phones or review previous results.";
    document.querySelector(".lab-heading .quiet-link").href = "final-qc.html";
    document.querySelector(".lab-heading .quiet-link").textContent = "← Back to Final QC";
    technicianBoard.hidden = true;
    technicianImeiScanWrap.hidden = true;
    frameViewTabs.hidden = false;
    framePendingPanel.setAttribute('role', 'tabpanel');
    framePendingPanel.setAttribute('aria-labelledby', 'frame-pending-tab');
    frameReportPanel.setAttribute('role', 'tabpanel');
    frameReportPanel.setAttribute('aria-labelledby', 'frame-history-tab');
    showFrameView('pending');
    linesKicker.hidden = true;
    technicianLinesTitle.textContent = "Pending work";
    technicianLinesHelp.textContent = "Select Final Grade and Pass, or choose Fail.";
    refreshFrameButton.hidden = false;
    linesHead.innerHTML = "<th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>BH</th><th>Supplier code</th><th>Supplier grade</th><th>Initial grade</th><th>Final grade</th><th>Pass</th><th>Fail</th><th>Save</th>";
    document.querySelector("#workflow-rule-text").textContent = "Frame Department decides the Final Grade. Frame Pass sends the phone directly to Ready Stock. Frame Fail keeps it pending in Frame and adds to the permanent failure report.";
  }

  function showFrameView(view, moveFocus = false) {
    if (!isFrameMode) return;
    const history = view === 'history';
    framePendingPanel.hidden = history;
    frameReportPanel.hidden = !history;
    frameViewTabs.querySelectorAll('[data-frame-view]').forEach(button => {
      const active = button.dataset.frameView === (history ? 'history' : 'pending');
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
      if (active && moveFocus) button.focus();
    });
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
    technicianImeiScan.disabled = !searchable();
    checkTechnicianImei.disabled = !searchable();
    technicianImeiScan.placeholder = "Enter or scan 15-digit IMEI";
  }

  function optionsMarkup(options, placeholder) { return `<option value="">${escapeHtml(placeholder)}</option>${options.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("")}`; }
  function frameGradeMarkup() { return optionsMarkup(frameGradeItems.map((item) => item.option_value), "Select final grade"); }
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
  function manualPartNames(row) { return unique(asList(row.manual_parts).map((item) => item.name)); }
  function usesManualParts(row) { return false; }
  function initialServiceNames(row, requiredOnly = false) {
    return unique(asList(row.initial_services)
      .filter((item) => !requiredOnly || item.lab_decision !== "not_required")
      .map((item) => item.name)
      .filter(isInitialQcService));
  }
  function labPartNames(row) {
    if(row.pf_plan)return row.pf_plan.parts.map(p=>p.name);
    const manuallyAdded = manualPartNames(row);
    if (usesManualParts(row) && manuallyAdded.length) return manuallyAdded;
    const allRequests = allLabPartRequests(row);
    const activeNames = unique(activeLabPartRequests(row).map((item) => item.name));
    if (allRequests.length) return activeNames;
    return initialNames(row.initial_parts).filter((name) => !asList(row.initial_parts).some((item) => normalise(item.name) === normalise(name) && ["not_required", "unused_returned", "cancelled"].includes(normalise(item.status))));
  }
  function labServiceNames(row) {
    if(row.pf_plan)return row.pf_plan.services.map(p=>p.name);
    const reviewed = asList(row.lab_services);
    if (reviewed.length) return unique(reviewed
      .filter((item) => item.required !== false)
      .filter((item) => item.source !== "initial_qc" || isInitialQcService(item.name))
      .map((item) => item.name));
    return initialServiceNames(row, true);
  }
  function readOnlyList(values) { const list = unique(values); return list.length ? `<div class="line-list">${list.map((value) => `<span>${escapeHtml(value)}</span>`).join("")}</div>` : '<span class="line-empty">None</span>'; }
  function choiceTag(kind,value,quantity=1){return kind==='part'?`<span class="pf-lab-part-tag"><button type="button" data-remove-choice="part" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button><input data-part-quantity data-name="${escapeHtml(value)}" type="number" min="1" max="10000" step="1" value="${escapeHtml(quantity)}" aria-label="Quantity for ${escapeHtml(value)}"></span>`:`<button type="button" data-remove-choice="service" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`;}
  function choiceCell(kind, options, selected, data={}) {
    return `<div class="lab-choice" data-choice="${kind}"><div class="lab-choice-row"><select>${optionsMarkup(options,kind==='part'?'Select part':'Select service')}</select><button type="button" data-add-choice="${kind}" title="Add">+</button></div><div class="lab-choice-tags">${unique(selected).map(value=>choiceTag(kind,value,lineDrafts.get(String(data.step_id))?.quantities?.[value]??data.pf_plan?.parts?.find(p=>normalise(p.name)===normalise(value))?.quantity??1)).join('')}</div></div>`;
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
      quantities:Object.fromEntries([...row.querySelectorAll("[data-part-quantity]")].map(e=>[e.dataset.name,e.value])),
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
    const p=row.pf_plan||{parts:[],services:[],returns:[]};
    return {submitted:!!p.submitted,locked:!!p.locked,pendingReturns:p.returns.filter(r=>r.status==='pending'),allIssued:!!p.submitted&&p.parts.every(r=>Number(r.issued)>=Number(r.quantity))&&p.services.every(s=>s.status!=='pending'),hasParts:p.parts.length>0,manualFlow:false};
  }
  function linePartVisual(row){const p=lineWorkflowState(row);return {className:p.pendingReturns.length?'parts-pending':p.allIssued?'parts-issued':'parts-pending',label:p.pendingReturns.length?'Return pending':!p.submitted?'Preparing requirements':p.locked?(p.allIssued?'Parts issued · List locked':'Partially issued · List locked'):'Sent to Parts · Editable'};}
  function actionCell(row) {
    const p=row.pf_plan||{},st=lineWorkflowState(row),ready=st.allIssued&&!st.pendingReturns.length;
    return `${!st.locked?`<button type="button" class="line-save order-parts" data-order-parts="${escapeHtml(row.step_id)}">${st.submitted?'Update Parts list':'Send to Parts'}</button>`:'<span class="pf-lab-lock">List locked after issue</span>'}<button type="button" class="line-save job-completed" data-complete-lab="${escapeHtml(row.step_id)}" ${ready?'':'disabled'}>Job Completed</button><small class="line-status" data-line-status>${st.pendingReturns.length?'Waiting for Parts return review':!st.submitted?'Finalise parts and services, then send to Parts':ready?'Ready to send to Final QC':'Waiting for issue and service confirmation'}</small>`;
  }
  function returnableParts(row) {
    return activeLabPartRequests(row).filter((item) => Number(item.issued || 0) - Number(item.installed || 0) - Number(item.returned || 0) > 0);
  }
  function issuedPartTools(row) {
    const p=row.pf_plan;if(!p)return '';const issues=p.issues.filter(i=>Number(i.available)>0);
    const previous=p.previous_manual_parts?.length?'<p class="pf-lab-lock">Earlier manual records: '+p.previous_manual_parts.map(m=>escapeHtml(m.name)+' x '+escapeHtml(m.quantity)).join(', ')+'</p>':'';
    const returns=p.returns.length?'<ul class="pf-return-status">'+p.returns.map(r=>`<li>${escapeHtml(r.quantity)} returned · ${escapeHtml(r.status)}${r.classification?' · '+escapeHtml(r.classification.replaceAll('_',' ')):''}</li>`).join('')+'</ul>':'';
    if(!issues.length)return previous+returns;
    return previous+`<details class="lab-issued-tools"><summary>Return issued part</summary><div class="pf-lab-return"><label>Issued part<select data-pf-return-issue>${issues.map(i=>`<option value="${escapeHtml(i.issue_id)}" data-available="${escapeHtml(i.available)}">${escapeHtml(i.name)} · ${escapeHtml(i.available)} available</option>`).join('')}</select></label><label>Return quantity<input type="number" min="1" step="1" value="1" data-pf-return-qty></label><label>Notes for Parts<input type="text" maxlength="1000" data-pf-return-notes placeholder="Why is this part being returned?"></label><button class="line-save" type="button" data-pf-return>Send return request</button><small>Parts will classify the return as Not Needed, Damaged or Faulty.</small></div></details>${returns}`;
  }
  function rowData(rowElement) { return technicianRows.find(item=>String(item.step_id)===String(rowElement?.dataset.stepId)); }
  function renderTechnicianLines() {
    const selectedTech = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    const assignedRows = technicianRows.filter((row) => isFrameMode ? String(row.department) === "frame" : ["laboratory", "glass"].includes(String(row.department)));
    const filtered = assignedRows.filter(row => !focusedImei || (String(row.imei) === focusedImei && (!focusedStepId || String(row.step_id) === focusedStepId)));
    const awaitingFinalQc = isFrameMode ? 0 : Math.max(0, Number(selectedTech?.pending_count || 0) - assignedRows.length);
    technicianLinesCount.textContent = focusedImei ? `${filtered.length} matching phone${filtered.length === 1 ? "" : "s"}` : `${filtered.length} repair line${filtered.length === 1 ? "" : "s"}${awaitingFinalQc ? ` - ${awaitingFinalQc} Final QC receipt` : ""}`;
    if (!activeTechnicianId) { technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">Select a technician.</td></tr>'; return; }
    if (!filtered.length) {
      technicianWorkRows.innerHTML = `<tr><td colspan="12" class="technician-lines-empty">${focusedImei ? `No pending line for IMEI ${escapeHtml(focusedImei)}. Use Show all to return to this technician’s phones.` : awaitingFinalQc ? `${escapeHtml(selectedTech?.full_name || "This technician")} has ${awaitingFinalQc} phone${awaitingFinalQc === 1 ? "" : "s"} awaiting Final QC receipt.` : `${escapeHtml(selectedTech?.full_name || "This technician")} has no ${isFrameMode ? "Frame" : "Laboratory"} phones pending.`}</td></tr>`;
      return;
    }
    technicianWorkRows.innerHTML = filtered.map((row) => {
      const qcParts = initialNames(row.initial_parts);
      const qcServices = initialServiceNames(row);
      const supplier = typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
        ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(row.supplier_code, row.planned_quantity, row.supplier_name, "—")
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
      return `<tr class="lab-phone-row ${visual.className}" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card"><div class="lab-card-status"><span>${escapeHtml(visual.label)}</span></div><div class="lab-static-grid">${staticLine}</div><div class="lab-edit-grid"><fieldset class="pf-lab-choices" ${row.pf_plan?.locked?'disabled':''}><div class="lab-edit-field lab-parts-field"><span class="lab-field-label">${usesManualParts(row) ? "Parts added in Lab" : "Final parts required"}</span>${row.pf_plan?.locked?readOnlyList(row.pf_plan.parts.map(p=>p.name+" x "+p.quantity)):choiceCell("part", partOptions, displayedParts,row)}</div><div class="lab-edit-field"><span class="lab-field-label">Final services required</span>${row.pf_plan?.locked?readOnlyList(displayedServices):choiceCell("service", standardServices, displayedServices,row)}</div></fieldset><div class="lab-line-actions">${saveCell}${issuedPartTools(row)}</div></div></article></td></tr>`;
    }).join("");
  }

  function renderFrameLines() {
    technicianLinesCount.textContent = `${technicianRows.length} waiting`;
    document.querySelector("#frame-pending-tab-count").textContent = technicianRows.length;
    if (!technicianRows.length) {
      technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">No phones are waiting in Frame.</td></tr>';
      return;
    }
    technicianWorkRows.innerHTML = technicianRows.map((row) => {
      const supplier = typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
        ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(row.supplier_code, row.planned_quantity, row.supplier_name, "—")
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
        <td><select class="frame-final-grade" data-frame-final-grade aria-label="Final Grade">${frameGradeMarkup()}</select></td>
        <td><label class="frame-pass-check"><input type="checkbox" data-frame-result="pass"><span>Pass</span></label></td>
        <td><label class="frame-fail-check"><input type="checkbox" data-frame-result="fail"><span>Fail</span></label></td>
        <td><button class="line-save frame-ready" type="button" data-complete-frame="${escapeHtml(row.step_id)}" disabled>Save</button><small class="line-status">Select Pass or Fail</small></td>
      </tr>`;
    }).join("");
  }

  function formatDateTime(value) {
    return value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short", hour12: true }).format(new Date(value)) : "—";
  }

  const frameFilters=window.GREENLOOP_FILTERS.remote('frame-result-filters',{
    before:frameReportRows.closest('.frame-report-scroll'),source:'frame_results',dateKey:'reviewed_at',dateLabel:'Checked',
    fields:[['supplier_code','Supplier code'],['model','Model'],['result','Result'],['reviewed_by_name','Checked by']],
    onResult:data=>{const rows=data.rows;
    document.querySelector("#frame-history-tab-count").textContent = data.total ?? rows.length;
    framePassCount.textContent = `${data.totals.pass} Pass`;
    frameFailCount.textContent = `${data.totals.fail} Fail`;
    frameReportRows.innerHTML = rows.length ? rows.map((row) => `<tr><td>${escapeHtml(formatDateTime(row.reviewed_at))}</td><td><strong>${escapeHtml(row.imei || "—")}</strong></td><td>${escapeHtml(row.supplier_code || "—")}</td><td>${escapeHtml(row.model || "—")}</td><td><span class="frame-result ${escapeHtml(row.result)}">${escapeHtml(String(row.result || "").toUpperCase())}</span></td><td>${escapeHtml(row.reviewed_by_name || "System")}</td></tr>`).join("") : '<tr><td colspan="6" class="technician-lines-empty">No Frame results recorded yet.</td></tr>';
    },onError:()=>{frameReportRows.innerHTML='<tr><td colspan="6">Frame results unavailable.</td></tr>';framePassCount.textContent=frameFailCount.textContent='Unavailable';}
  });
  async function loadFrameReport(){return frameFilters.load();}

  async function loadPartOptions() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "part_name" });
    if (!error && data?.length) partOptions = unique([...standardParts, ...data.map((item) => item.option_value)]);
  }
  async function loadFrameGrades() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "grade" });
    if (error) throw error;
    frameGradeItems = data || [];
  }
  async function loadTechnicianRows() {
    const version = ++rowLoadVersion;
    const technicianId = activeTechnicianId;
    const editsAtStart = editVersion;
    const isCurrent = () => version === rowLoadVersion && technicianId === activeTechnicianId && editsAtStart === editVersion;
    setBoardMessage();
    if (!activeTechnicianId) { technicianRows = []; renderTechnicianLines(); return; }
    const [rowResponse, returnResponse] = await Promise.all([
      getClient().rpc("get_lab_technician_rows_v2", { p_technician_id: technicianId }),
      getClient().rpc("get_lab_part_return_requests_for_technician", { p_technician_id: technicianId })
    ]);
    if (!isCurrent()) return;
    if (rowResponse.error) throw rowResponse.error;
    if (returnResponse.error) throw returnResponse.error;
    const pendingByStep = new Map();
    (returnResponse.data || []).forEach((item) => {
      const key = String(item.work_order_step_id);
      pendingByStep.set(key, [...(pendingByStep.get(key) || []), item]);
    });
    const rows = rowResponse.data || [];
    const jobIds = [...new Set(rows.map((row) => row.job_id).filter(Boolean))];
    const { data: batchJobs } = jobIds.length
      ? await getClient().from("jobs").select("id, job_number, device:devices(device_number, serial_number, imei_2), receiving_batch:receiving_batches(planned_quantity, invoice_number, batch_number)").in("id", jobIds)
      : { data: [] };
    const quantityByJob = new Map((batchJobs || []).map((job) => {
      const batch = Array.isArray(job.receiving_batch) ? job.receiving_batch[0] : job.receiving_batch;
      const device=Array.isArray(job.device)?job.device[0]:job.device;
      return [String(job.id), {...batch,...device,job_number:job.job_number}];
    }));
    if (!isCurrent()) return;
    const planResponse=await getClient().rpc('get_lab_parts_plans_v1',{p_step_ids:rows.map(r=>r.step_id)});if(!isCurrent())return;if(planResponse.error)throw planResponse.error;
    const plans=new Map((planResponse.data||[]).map(p=>[String(p.step_id),p]));for(const [id,p]of plans)if(p.locked)lineDrafts.delete(id);
    technicianRows = rows.map((row) => ({ ...row,pf_plan:plans.get(String(row.step_id)), ...quantityByJob.get(String(row.job_id)), pending_part_returns: pendingByStep.get(String(row.step_id)) || [] }));
    renderTechnicianLines();
    technicianWorkRows.querySelectorAll("tr[data-step-id]").forEach((row) => {
      if (lineDrafts.has(String(row.dataset.stepId))) markLineChanged(row);
    });
  }
  async function loadFrameRows() {
    setBoardMessage();
    const { data, error } = await getClient().rpc("get_frame_department_rows");
    if (error) throw error;
    const rows = data || [];
    const jobIds = [...new Set(rows.map((row) => row.job_id).filter(Boolean))];
    const { data: batchJobs } = jobIds.length
      ? await getClient().from("jobs").select("id, receiving_batch:receiving_batches(planned_quantity)").in("id", jobIds)
      : { data: [] };
    const quantityByJob = new Map((batchJobs || []).map((job) => {
      const batch = Array.isArray(job.receiving_batch) ? job.receiving_batch[0] : job.receiving_batch;
      return [String(job.id), batch?.planned_quantity];
    }));
    technicianRows = rows.map((row) => ({ ...row, planned_quantity: quantityByJob.get(String(row.job_id)) }));
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
    const { data: manualMode, error: manualModeError } = await getClient().rpc("get_manual_lab_parts_mode");
    if (manualModeError) throw manualModeError;
    manualLabPartsMode = Boolean(manualMode);
    await loadTechnicians(activeTechnicianId);
    await loadTechnicianRows();
  }

  function technicianEditorIsActive() {
    const active = document.activeElement;
    if (!active || !technicianWorkRows.contains(active)) return false;
    return active.matches("select, input, textarea");
  }

  async function addTechnician() {
    if (!editable()) return;
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
    if (!editable()) return;
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
    holder.querySelector(".lab-choice-tags").insertAdjacentHTML("beforeend", choiceTag(holder.dataset.choice,value));
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
        choiceTag(holder.dataset.choice,value)
      );
    }
    rememberLineDraft(row);
    row.dataset.editing = "true";
    markLineChanged(row);
  }
  function markLineChanged(row) {
    if(rowData(row)?.pf_plan?.locked)return;
    editVersion += 1;
    const orderButton = row.querySelector("[data-order-parts]");
    const completeButton = row.querySelector("[data-complete-lab]");
    const status = row.querySelector("[data-line-status]");
    if (!orderButton) return;
    row.dataset.dirty = "true";
    orderButton.disabled = false;
    const returnPart = row.querySelector("[data-return-part-select]")?.value || "";
    const returnReason = row.querySelector("[data-return-reason]:checked")?.value || "";
    const selectedParts = selectedChoices(row, "part");
    orderButton.textContent = returnPart || returnReason ? "Submit Part Return" : "Update Parts list";
    orderButton.className = "line-save order-parts";
    if (completeButton) completeButton.disabled = true;
    if (status) {
      status.textContent = "Submit the updated order before completing the job";
      status.className = "line-status";
    }
  }
  async function runLineAction(button, action) {
    if (!editable()) return;
    const row = button.closest("tr");
    if (button.disabled || row.dataset.busy === "yes" || row.dataset.saved === "yes") return;
    row.dataset.busy = "yes";
    const controls = [...row.querySelectorAll("input, select, button")].map((control) => [control, control.disabled]);
    const label = button.textContent;
    controls.forEach(([control]) => { control.disabled = true; });
    try { await action(button); }
    finally {
      row.dataset.busy = "";
      if (row.dataset.saved !== "yes") {
        controls.forEach(([control, disabled]) => { control.disabled = disabled; });
        button.textContent = label;
      } else {
        controls.forEach(([control]) => { control.disabled = true; });
      }
    }
  }
  async function orderParts(button) {
    if(!editable())return;const row=button.closest('tr'),data=rowData(row),p=data?.pf_plan;if(!p||p.locked)return;
    const parts=selectedChoices(row,'part').map(name=>({name,quantity:Number([...row.querySelectorAll('[data-part-quantity]')].find(e=>normalise(e.dataset.name)===normalise(name))?.value||1)}));
    const {error}=await getClient().rpc('submit_lab_parts_plan_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_parts:parts,p_services:selectedChoices(row,'service')});
    if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';lineDrafts.delete(String(row.dataset.stepId));showToast('Final parts and services sent to Parts.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();
  }
  async function submitPartReturn(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const quantity=Number(row.querySelector('[data-pf-return-qty]').value),notes=row.querySelector('[data-pf-return-notes]').value.trim();if(!notes||notes.length<2){setBoardMessage('Add notes for Parts to review this return.');return;}const {error}=await getClient().rpc('request_parts_flow_return_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_issue_id:row.querySelector('[data-pf-return-issue]').value,p_quantity:quantity,p_notes:notes});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';showToast('Return sent to Parts for classification.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();}
  async function completeLab(button) {
    if (!editable()) return;
    setSubmitting(button, true, "Completing...");
    const { error } = await getClient().rpc("complete_parts_flow_lab_v1", { p_step_id: button.dataset.completeLab,p_revision:rowData(button.closest("tr"))?.pf_plan?.revision??0 });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    button.closest("tr").dataset.saved = "yes";
    showToast("Job completed. Phone sent to Final QC.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }
  function cancelImeiLookup() {
    imeiLookupVersion++; window.clearTimeout(imeiTimer); pendingImei = "";
    technicianImeiScanWrap.removeAttribute("aria-busy"); checkTechnicianImei.textContent = "Open phone";
  }
  function clearImeiFocus() {
    cancelImeiLookup(); focusedImei = ""; focusedStepId = ""; technicianImeiScan.value = "";
    clearTechnicianImei.hidden = true; setBoardMessage(); renderTechnicianLines();
  }
  async function scanTechnicianImei() {
    if (!searchable()) return;
    const imei = technicianImeiScan.value.trim();
    if (!/^\d{15}$/.test(imei)) { setBoardMessage("Enter or scan a valid 15-digit IMEI."); return; }
    if (pendingImei === imei) return;
    if (technicianWorkRows.querySelector('tr[data-busy="yes"]')) { setBoardMessage("Wait for the current save to finish, then open the IMEI."); return; }
    const ticket = ++imeiLookupVersion;
    const scanCurrent = () => ticket === imeiLookupVersion && technicianImeiScan.value.trim() === imei && searchable() && app.isConnected;
    pendingImei = imei; focusedImei = imei; focusedStepId = ""; clearTechnicianImei.hidden = false; renderTechnicianLines();
    technicianImeiScanWrap.setAttribute("aria-busy", "true"); checkTechnicianImei.textContent = "Opening…";
    setBoardMessage("Finding the assigned technician…");
    try {
      if (!await window.GREENLOOP_IMEI_STAGE_NOTICE.checkPrimary(imei, {isCurrent:scanCurrent})) {
        if (scanCurrent()) setBoardMessage("Duplicate phone — use IMEI 1.");
        return;
      }
      // Read only the current Lab/Glass assignment; existing RLS and Office Only guards apply.
      const {data, error} = await getClient().from("job_work_order_steps")
        .select("id, assigned_technician_roster_id, assigned_technician_name, work_order:job_work_orders!inner(job:jobs!inner(deleted_at, device:devices!inner(imei_1, deleted_at)))")
        .in("department", ["laboratory", "glass"]).eq("step_status", "in_progress")
        .eq("work_order.job.device.imei_1", imei).is("work_order.job.deleted_at", null)
        .is("work_order.job.device.deleted_at", null)
        .order("created_at", {ascending:false}).order("id", {ascending:false}).limit(1).maybeSingle();
      if (!scanCurrent()) return;
      if (error) throw error;
      if (!data) {
        renderTechnicianLines();
        setBoardMessage("This IMEI has no pending Lab or Glass work.");
        window.GREENLOOP_IMEI_STAGE_NOTICE?.show({imei,title:"Phone unavailable here",message:"This IMEI has no pending Lab or Glass work.",onlyIfFound:true,isCurrent:scanCurrent});
        return;
      }
      const owner = () => technicians.find(t => data.assigned_technician_roster_id
        ? String(t.id) === String(data.assigned_technician_roster_id)
        : normalise(t.full_name) === normalise(data.assigned_technician_name));
      if (!owner()) await loadTechnicians(activeTechnicianId);
      if (!scanCurrent()) return;
      const technician = owner();
      if (!technician) throw new Error("This phone has no active technician assignment. Check its assignment before continuing.");
      activeTechnicianId = String(technician.id); focusedStepId = String(data.id);
      technicianRows = []; renderTechnicianCards(); renderTechnicianLines();
      await workFilters.clear();
      if (!scanCurrent()) return;
      await loadTechnicianRows();
      if (!scanCurrent()) return;
      const target = technicianWorkRows.querySelector(`tr[data-step-id="${CSS.escape(focusedStepId)}"]`);
      if (!target || target.hidden) throw new Error("The phone assignment changed or its line is no longer pending. Search the IMEI again.");
      setBoardMessage(`IMEI ${imei} · ${technician.full_name}`, true);
      target.classList.add("scan-match"); target.scrollIntoView({behavior:"smooth",block:"center"});
      window.setTimeout(() => target.classList.remove("scan-match"), 2600);
      if (document.activeElement === technicianImeiScan || document.activeElement === checkTechnicianImei) {
        technicianImeiScan.focus({preventScroll:true}); technicianImeiScan.select();
      }
    } catch (error) {
      if (scanCurrent()) { renderTechnicianLines(); setBoardMessage(error.message || "The IMEI could not be opened. Try again."); }
    } finally {
      if (ticket === imeiLookupVersion) { pendingImei = ""; technicianImeiScanWrap.removeAttribute("aria-busy"); checkTechnicianImei.textContent = "Open phone"; }
    }
  }
  async function completeFrame(button) {
    if (!editable()) return;
    const row = button.closest("tr");
    const result = row.querySelector("[data-frame-result]:checked")?.dataset.frameResult || "";
    if (!result) return;
    const finalGrade = row.querySelector("[data-frame-final-grade]")?.value || "";
    if (result === "pass" && !finalGrade) {
      setBoardMessage("Select the Final Grade before passing this Frame phone to Ready Stock.");
      row.querySelector("[data-frame-final-grade]")?.focus();
      return;
    }
    setSubmitting(button, true, "Saving...");
    const { error } = await getClient().rpc("record_frame_department_result_v3", {
      p_work_order_step_id: button.dataset.completeFrame,
      p_result: result,
      p_final_grade: result === "pass" ? finalGrade : null,
      p_notes: result === "pass" ? "Frame work passed" : "Frame work failed; remains pending"
    });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    row.dataset.saved = "yes";
    showToast(result === "pass" ? `Frame passed with grade ${finalGrade}. Phone sent directly to Ready Stock.` : "Frame failed. Phone remains in Frame and the failure was recorded.");
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
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== (isFrameMode ? "frame_department" : "lab_glass")) return;
    app.hidden = false;
    if (!isFrameMode) await loadPartOptions();
    else await loadFrameGrades();
    await refreshAll();
    if (!isFrameMode) {
      window.setInterval(() => {
        if (
          document.visibilityState !== "visible"
          || app.hidden
          || technicianEditorIsActive()
          || technicianWorkRows.querySelector('tr[data-dirty="true"], tr[data-editing="true"], tr[data-busy="yes"]')
        ) return;
        loadTechnicianRows().catch(() => {});
      }, 12000);
    }
  }

  frameViewTabs.addEventListener('click', event => {
    const button = event.target.closest('[data-frame-view]');
    if (button) showFrameView(button.dataset.frameView);
  });
  frameViewTabs.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const current = frameViewTabs.querySelector('[aria-selected="true"]')?.dataset.frameView;
    const next = event.key === 'Home' ? 'pending' : event.key === 'End' ? 'history' : current === 'pending' ? 'history' : 'pending';
    showFrameView(next, true);
  });

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-lab").addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  refreshFrameButton.addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  addTechnicianButton.addEventListener("click", () => addTechnician().catch((error) => setBoardMessage(error.message)));
  removeTechnicianButton.addEventListener("click", () => removeTechnician().catch((error) => setBoardMessage(error.message)));
  technicianCards.addEventListener("click", (event) => {
    const card = event.target.closest("[data-technician-id]"); if (!card) return;
    clearImeiFocus(); activeTechnicianId = card.dataset.technicianId; technicianRows = [];
    renderTechnicianCards(); renderTechnicianLines();
    workFilters.clear().then(() => loadTechnicianRows()).catch(error => setBoardMessage(error.message));
  });
  technicianImeiScan.addEventListener("input", () => {
    cancelImeiLookup();
    if (!technicianImeiScan.value.trim()) { clearImeiFocus(); return; }
    if (/^\d{15}$/.test(technicianImeiScan.value.trim())) imeiTimer = window.setTimeout(scanTechnicianImei, 200);
  });
  technicianImeiScan.addEventListener("keydown", event => {
    if (event.key !== "Enter" || event.isComposing) return;
    event.preventDefault(); window.clearTimeout(imeiTimer); scanTechnicianImei();
  });
  checkTechnicianImei.addEventListener("click", () => { window.clearTimeout(imeiTimer); scanTechnicianImei(); });
  clearTechnicianImei.addEventListener("click", () => { if (searchable()) { clearImeiFocus(); technicianImeiScan.focus(); } });
  technicianWorkRows.addEventListener("click", (event) => {
    if (!editable()) return;
    const add = event.target.closest("[data-add-choice]"); if (add) { addChoice(add); return; }
    const remove = event.target.closest("[data-remove-choice]"); if (remove) {
      const row = remove.closest("tr");
      const holder = remove.closest("[data-choice]");
      const select = holder?.querySelector("select");
      if (select && normalise(select.value) === normalise(remove.dataset.value)) select.value = "";
      (remove.closest(".pf-lab-part-tag")||remove).remove();
      rememberLineDraft(row);
      markLineChanged(row);
      return;
    }
    const returned=event.target.closest("[data-pf-return]");if(returned){runLineAction(returned,submitPartReturn).catch(e=>setBoardMessage(e.message));return;}
    const order = event.target.closest("[data-order-parts]"); if (order && !order.disabled) runLineAction(order, orderParts).catch((error) => setBoardMessage(error.message));
    const completeLabButton = event.target.closest("[data-complete-lab]"); if (completeLabButton) runLineAction(completeLabButton, completeLab).catch((error) => setBoardMessage(error.message));
    const completeFrameButton = event.target.closest("[data-complete-frame]"); if (completeFrameButton) runLineAction(completeFrameButton, completeFrame).catch((error) => setBoardMessage(error.message));
  });
  technicianWorkRows.addEventListener("change", (event) => {
    if (!editable()) return;
    if(event.target.matches("[data-part-quantity]")){rememberLineDraft(event.target.closest("tr"));markLineChanged(event.target.closest("tr"));return;}
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
    status.textContent = result === "pass" ? "Select Final Grade, then move to Ready Stock" : result === "fail" ? "Will stay in Frame" : "Select Pass or Fail";
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
