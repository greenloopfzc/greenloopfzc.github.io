(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const isFrameMode = window.location.hash.toLowerCase() === "#frame";
  window.addEventListener("hashchange", () => window.location.reload());
  const standardParts = ["Case", "Glass", "Touch panel", "NFC flex", "Vibrator", "Speaker", "Camera", "Face ID flex", "LCD display", "Battery", "Charging flex"];
  let standardServices = ["Polish", "Cleaning", "Software", "Testing", "Face ID calibration", "Camera calibration", "Housing repair", "Glass work", "Frame work"];
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
  const usageCounts = {part: new Map(), service: new Map()};
  function rankChoices(kind, options) { return [...options].sort((a,b) => (usageCounts[kind].get(normalise(b)) || 0) - (usageCounts[kind].get(normalise(a)) || 0) || (normalise(a) < normalise(b) ? -1 : normalise(a) > normalise(b) ? 1 : 0)); }
  let manualLabPartsMode = false;
  let frameGradeItems = [];
  const lineDrafts = new Map();
  const workbenchReads = new Map();
  let boardRead = null;
  let toastTimer;
  let rowLoadVersion = 0;
  let editVersion = 0;
  let focusedImei = "", focusedStepId = "", imeiLookupVersion = 0, imeiTimer, pendingImei = "";
  const clearTechnicianImei = document.querySelector("#clear-technician-imei");
  const searchable = () => !isFrameMode && window.GREENLOOP_PAGE_ACCESS?.pageKey === "lab_glass" && window.GREENLOOP_CAN?.("search", "lab_glass") === true;

  const editable = () => window.GREENLOOP_PAGE_ACCESS?.pageKey === (isFrameMode ? "frame_department" : "lab_glass") && window.GREENLOOP_PAGE_ACCESS.canEdit === true;

  function getClient() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]); }
  // Anchor elapsed time to the server using a monotonic local clock; no timer RPCs.
  let phoneClock=null;
  function phoneNow(){return phoneClock?phoneClock.server+Math.max(0,performance.now()-phoneClock.local):NaN;}
  function elapsedPhoneTime(start){const minutes=Math.floor(Math.max(0,phoneNow()-start)/60000);if(!Number.isFinite(minutes))return 'Not recorded';if(minutes===0)return 'Less than 1 min';const days=Math.floor(minutes/1440),hours=Math.floor(minutes%1440/60),mins=minutes%60;return [days?days+'d':'',hours?hours+'h':'',mins?mins+'m':''].filter(Boolean).join(' ');}
  function phoneTime(row){
    for(const [key,label]of [['lab_entered_at','Time in Lab & Glass'],['technician_assigned_at','Time with technician'],['line_created_at','Work line age']]){
      const start=row[key]?Date.parse(row[key]):NaN;if(!Number.isFinite(start)||start>phoneNow())continue;
      const since=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'numeric',minute:'2-digit',hour12:true}).format(new Date(start));
      return `<div class="lab-phone-time${phoneNow()-start>=172800000?' is-overdue':''}" title="${escapeHtml(label+' · Since '+since+' · UAE')}"><span>${escapeHtml(label)}</span><strong data-lab-phone-age data-started-at="${escapeHtml(new Date(start).toISOString())}">${escapeHtml(elapsedPhoneTime(start))}</strong></div>`;
    }
    return '<div class="lab-phone-time is-unrecorded"><span>Time in Lab &amp; Glass</span><strong>Time not recorded</strong></div>';
  }
  function updatePhoneAges(){if(isFrameMode||document.hidden||app.hidden||!app.isConnected)return;for(const el of technicianWorkRows.querySelectorAll('[data-lab-phone-age]')){const start=Date.parse(el.dataset.startedAt),text=elapsedPhoneTime(start);if(el.textContent!==text)el.textContent=text;el.closest('.lab-phone-time').classList.toggle('is-overdue',phoneNow()-start>=172800000);}}
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
    const byId=new Map(technicianRows.map(row=>[String(row.step_id),row]));
    const rows=elements.map(el=>byId.get(el.dataset.stepId)||{});
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
    const pendingTotal=technicians.reduce((sum,t)=>sum+Math.max(0,Number(t.pending_count)||0),0);
    document.querySelector('#lab-total-pending-count').textContent=pendingTotal.toLocaleString('en-US');
    document.querySelector('#lab-total-pending-unit').textContent=pendingTotal===1?'phone':'phones';
    technicianCards.innerHTML = technicians.length ? technicians.map((technician) => {
      const count = Number(technician.pending_count || 0);
      const active = String(technician.id) === String(activeTechnicianId);
      return `<button class="technician-card${active ? " is-active" : ""}" type="button" data-capability="view" data-capability-page="lab_glass" data-search-read-only data-technician-id="${escapeHtml(technician.id)}" aria-pressed="${active}"><span class="technician-avatar">${escapeHtml(initials(technician.full_name))}</span><span class="technician-card-copy"><strong>${escapeHtml(technician.full_name)}</strong><span>${count} ${technician.unassigned?'unassigned':'assigned'} IMEI${count === 1 ? "" : "s"}</span></span><span class="technician-card-count${count ? "" : " is-zero"}" aria-label="${count} pending phone${count===1?'':'s'}">${count.toLocaleString('en-US')}</span></button>`;
    }).join("") : '<p class="technician-lines-empty">No technicians are available.</p>';
    const selected = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    technicianBoardTitle.textContent = selected?.unassigned?'Phones awaiting employee assignment':selected ? `${selected.full_name}'s assigned work` : "Select a technician";
    technicianLinesTitle.textContent = selected?.unassigned?'Unassigned phones':selected ? `${selected.full_name}'s phone lines` : "Assigned phone lines";
    removeTechnicianButton.disabled = !selected || !!selected.unassigned;
    document.querySelector('#technician-lines-help').textContent=selected?.unassigned?'Assign an employee to continue this phone’s work.':'Review the lower line, order required parts, then complete the job after Parts has issued them.';
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
  function additionalMode(row) { const p=row?.pf_plan; return !!(p?.additional_only||p?.submitted||p?.locked); }
  function canOrderPart(row,name) {
    if(!additionalMode(row))return true;const p=row.pf_plan,k=normalise(name);
    if(p.parts.some(x=>normalise(x.name)===k&&Number(x.quantity)>Number(x.issued)))return false;
    const issued=(p.part_history||p.parts).some(x=>normalise(x.name)===k&&Number(x.issued)>0);
    return !issued||(p.reorder_available||[]).some(x=>normalise(x.name)===k&&Number(x.quantity)>0);
  }
  function choiceCell(kind, options, selected, data={}) {
    return `<div class="lab-choice" data-choice="${kind}"><div class="lab-choice-row"><select>${optionsMarkup(rankChoices(kind,kind==='part'?options.filter(name=>canOrderPart(data,name)):options),kind==='part'?'Select part':'Select service')}</select><button type="button" data-add-choice="${kind}" title="Add">+</button></div><div class="lab-choice-tags">${unique(selected).map(value=>choiceTag(kind,value,lineDrafts.get(String(data.step_id))?.quantities?.[value]??data.pf_plan?.parts?.find(p=>normalise(p.name)===normalise(value))?.quantity??1)).join('')}</div></div>`;
  }
  function selectedChoices(row, kind) {
    const tags = [...row.querySelectorAll(`[data-choice="${kind}"] [data-remove-choice]`)].map((button) => button.dataset.value);
    const currentSelection = row.querySelector(`[data-choice="${kind}"] select`)?.value || "";
    return unique([...tags, currentSelection]);
  }
  function rememberLineDraft(row, kind) {
    if (!row?.dataset.stepId) return;
    const id=String(row.dataset.stepId),old=lineDrafts.get(id)||{};
    lineDrafts.set(id, {...old,cycle:rowData(row)?.pf_plan?.cycle,modeLocked:additionalMode(rowData(row)),
      ...(kind==='part'?{parts:selectedChoices(row,'part'),quantities:Object.fromEntries([...row.querySelectorAll('[data-part-quantity]')].map(e=>[e.dataset.name,e.value])),partsDirty:true}:{}),
      ...(kind==='service'?{services:selectedChoices(row,'service'),servicesDirty:true}:{})});
  }
  function clearDraftKind(id,kind){const d=lineDrafts.get(String(id));if(!d)return;delete d[kind+'Dirty'];delete d[kind==='parts'?'parts':'services'];if(kind==='parts')delete d.quantities;if(!d.partsDirty&&!d.servicesDirty)lineDrafts.delete(String(id));}
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
    return {submitted:!!p.submitted,locked:!!p.locked,pendingReturns:p.returns.filter(r=>r.status==='pending'),allIssued:p.parts.every(r=>Number(r.issued)>=Number(r.quantity))&&(!p.parts.length||!!p.submitted),hasParts:p.parts.length>0,manualFlow:false};
  }
  function linePartVisual(row){const p=lineWorkflowState(row);return {className:p.pendingReturns.length?'parts-pending':p.allIssued?'parts-issued':'parts-pending',label:p.pendingReturns.length?'Return pending':!p.hasParts?'No parts required':!p.submitted?'Preparing parts list':p.allIssued?'Parts issued':'Waiting for Parts'};}
  function actionCell(row) {
    const p=row.pf_plan||{},st=lineWorkflowState(row),d=lineDrafts.get(String(row.step_id))||{},servicesReady=p.services_saved||!p.services?.length,ready=st.allIssued&&!st.pendingReturns.length&&servicesReady&&!d.partsDirty&&!d.servicesDirty;
    const send=st.hasParts||st.submitted||d.partsDirty;
    return `${additionalMode(row)?`<button type="button" class="line-save order-parts" data-order-parts="${escapeHtml(row.step_id)}" ${d.partsDirty&&d.parts?.length?'':'disabled'}>Order Additional Parts</button>`:send?`<button type="button" class="line-save order-parts" data-order-parts="${escapeHtml(row.step_id)}">${st.submitted?'Update Parts list':'Send to Parts'}</button>`:''}<button type="button" class="line-save job-completed" data-complete-lab="${escapeHtml(row.step_id)}" ${ready?'':'disabled'}>Job Completed</button><small class="line-status" data-line-status>${d.partsDirty||d.servicesDirty?'Save the changed list before completing the job':st.pendingReturns.length?'Waiting for Parts return review':!servicesReady?'Save the Lab services list':ready?'Ready to send to Final QC':!st.submitted?'Send the parts list to Parts':'Waiting for required parts'}</small>`;
  }
  function activePartList(row){const parts=row.pf_plan?.parts||[];return parts.length?'<ul class="pp-active-parts">'+parts.map(p=>`<li><span>${escapeHtml(p.name)} × ${escapeHtml(p.quantity)} <small>${Number(p.issued)>=Number(p.quantity)?'Issued':'Awaiting issue'}</small></span>${p.can_cancel?`<button type="button" data-cancel-part="${escapeHtml(p.request_id)}" aria-label="Remove unissued ${escapeHtml(p.name)}">Remove</button>`:''}</li>`).join('')+'</ul>':'<small>No active parts.</small>';}
  function returnableParts(row) {
    return activeLabPartRequests(row).filter((item) => Number(item.issued || 0) - Number(item.installed || 0) - Number(item.returned || 0) > 0);
  }
  function issuedPartTools(row) {
    const p=row.pf_plan;if(!p)return '';const issues=p.issues.filter(i=>Number(i.available)>0);
    const previous=p.previous_manual_parts?.length?'<p class="pf-lab-lock">Earlier manual records: '+p.previous_manual_parts.map(m=>escapeHtml(m.name)+' x '+escapeHtml(m.quantity)).join(', ')+'</p>':'';
    const pendingReturns=p.returns.filter(r=>r.status==='pending');const returns=pendingReturns.length?'<ul class="pf-return-status">'+pendingReturns.map(r=>`<li>${escapeHtml(p.issues.find(i=>i.issue_id===r.issue_id)?.name||'Part')} × ${escapeHtml(r.quantity)} returned · ${escapeHtml(r.status)}${r.classification?' · '+escapeHtml(r.classification.replaceAll('_',' ')):''}</li>`).join('')+'</ul>':'';
    if(!issues.length)return previous+returns;
    return previous+`<details class="lab-issued-tools"><summary>Return Part</summary><div class="pf-lab-return"><label>Issued part<select data-pf-return-issue><option value="">Select part to return</option>${issues.map(i=>`<option value="${escapeHtml(i.issue_id)}" data-available="${escapeHtml(i.available)}">${escapeHtml(i.name)} · ${escapeHtml(i.available)} available</option>`).join('')}</select></label><label data-pf-return-qty-wrap hidden>Return quantity<input type="number" min="1" step="1" value="1" data-pf-return-qty></label><button class="line-save" type="button" data-pf-return>Send return request</button><small>Parts Department will decide the return reason.</small></div></details>${returns}`;
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
      if(row.unassigned){return `<tr class="lab-phone-row unassigned-phone" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card"><div class="lab-card-header">${phoneTime(row)}<div class="lab-card-status"><span>Awaiting employee assignment</span></div></div><div class="lab-static-grid">${staticLine}</div><div class="employee-assignment"><label>Assign employee<select data-assign-employee data-capability="entry" data-capability-page="lab_glass"><option value="">Choose employee</option>${technicians.filter(t=>!t.unassigned).map(t=>`<option value="${escapeHtml(t.id)}">${escapeHtml(t.full_name)}</option>`).join('')}</select></label><button type="button" class="line-save" data-assign-employee-save data-capability="entry" data-capability-page="lab_glass">Assign employee</button></div></article></td></tr>`;}
      const visual = linePartVisual(row);
      const draft = lineDrafts.get(String(row.step_id));
      const displayedParts = draft?.partsDirty ? draft.parts : additionalMode(row)?[]:labPartNames(row);
      const displayedServices = draft?.servicesDirty ? draft.services : labServiceNames(row);
      return `<tr class="lab-phone-row ${visual.className}" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card"><div class="lab-card-header">${phoneTime(row)}<div class="lab-card-status"><span>${escapeHtml(visual.label)}</span></div></div><div class="lab-static-grid">${staticLine}</div><div class="lab-edit-grid"><fieldset class="pf-lab-choices"><div class="lab-edit-field lab-parts-field"><span class="lab-field-label">${additionalMode(row)?"Required parts":usesManualParts(row)?"Parts added in Lab":"Final parts required"}</span>${additionalMode(row)?(row.pf_plan?.qc_parts_sent?'<small class="pf-lab-lock">Initial QC parts sent directly to Parts.</small>':'')+activePartList(row)+'<span class="lab-field-label">Order additional parts</span>':''}${choiceCell("part",unique([...partOptions,...(row.pf_plan?.part_history||[]).map(p=>p.name)]),displayedParts,row)}</div></fieldset><div class="lab-edit-field pf-lab-services"><span class="lab-field-label">Lab &amp; Glass services</span>${choiceCell("service", standardServices, displayedServices,row)}<button type="button" class="line-save" data-save-services="${escapeHtml(row.step_id)}" ${row.pf_plan?.services_saved&&!draft?.servicesDirty?'disabled':''}>Save Services</button><small>${draft?.servicesDirty?'Unsaved service changes':row.pf_plan?.services_saved?'Saved in Lab &amp; Glass':'Managed in Lab &amp; Glass'}</small></div><div class="lab-line-actions">${saveCell}${issuedPartTools(row)}</div></div></article></td></tr>`;
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

  let workOptionsFingerprint='';
  function applyWorkOptions(data){const fingerprint=JSON.stringify(data);if(fingerprint===workOptionsFingerprint)return;workOptionsFingerprint=fingerprint;for(const [kind,list] of [['part',data.parts],['service',data.services]])usageCounts[kind]=new Map(list.map(o=>[normalise(o.name),Number(o.usage_count)||0]));partOptions=data.parts.map(o=>o.name);standardServices=data.services.map(o=>o.name);initialQcServices.clear();for(const service of data.services)if(service.initial_qc)initialQcServices.add(normalise(service.name));
    for(const holder of technicianWorkRows.querySelectorAll('[data-choice]')){const select=holder.querySelector('select');if(!select)continue;const value=select.value;select.innerHTML=optionsMarkup(holder.dataset.choice==='part'?partOptions:standardServices,holder.dataset.choice==='part'?'Select part':'Select service');if(value&&![...select.options].some(o=>o.value===value))select.insertAdjacentHTML('beforeend',`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`);select.value=value;}
  }
  async function loadFrameGrades() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "grade" });
    if (error) throw error;
    frameGradeItems = data || [];
  }
  async function labRead(promise){
    let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Phone data is taking too long. Check the connection and refresh.')),12000);})]);}finally{clearTimeout(timer);}
  }
  async function readWorkbench(args) {
    const key=JSON.stringify(args);
    if(!workbenchReads.has(key)){
      const request=labRead(getClient().rpc('get_ranked_lab_workbench_v1',args)).then(({data,error})=>{if(error)throw error;if(!data||!Array.isArray(data.rows)||!Number.isFinite(Date.parse(data.server_now))||!Array.isArray(data.work_options?.parts)||!Array.isArray(data.work_options?.services)||![...data.work_options.parts,...data.work_options.services].every(o=>typeof o.name==='string'&&o.name.trim()))throw new Error('Phone lines could not be verified.');return data;}).finally(()=>workbenchReads.delete(key));
      workbenchReads.set(key,request);
    }
    return workbenchReads.get(key);
  }
  function applyWorkbenchRows(rows,{quiet=false,serverTime,workOptions}={}){
    applyWorkOptions(workOptions);
    if(Number.isFinite(Date.parse(serverTime)))phoneClock={server:Date.parse(serverTime),local:performance.now()};
    for(const row of rows){const p=row.pf_plan;if(!p)continue;const id=String(row.step_id),d=lineDrafts.get(id);if(d&&d.cycle!==p.cycle)lineDrafts.delete(id);else if(d?.partsDirty&&d.modeLocked!==additionalMode(row))clearDraftKind(id,'parts');}
    if(quiet&&JSON.stringify(technicianRows)===JSON.stringify(rows))return;
    technicianRows=rows;renderTechnicianLines();
  }
  async function loadTechnicianRows({quiet=false}={}) {
    if(!app.isConnected)return;
    const version=++rowLoadVersion,technicianId=activeTechnicianId,editsAtStart=editVersion,scan=focusedImei;
    if(!quiet)setBoardMessage();
    if(!technicianId){technicianRows=[];renderTechnicianLines();return;}
    const employee=technicians.find(t=>String(t.id)===String(technicianId));
    const data=await readWorkbench({p_employee_id:employee?.unassigned?null:technicianId,p_imei:scan||null});
    if(version!==rowLoadVersion||technicianId!==activeTechnicianId||editsAtStart!==editVersion||scan!==focusedImei)return;
    if(scan&&String(data.employee_id)!==String(technicianId)){setBoardMessage('Phone assignment changed. Scan the IMEI again.');return;}
    applyWorkbenchRows(data.rows,{quiet,serverTime:data.server_now,workOptions:data.work_options});
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
    const selectionAtStart=activeTechnicianId;
    if(!boardRead)boardRead=labRead(getClient().rpc('get_lab_employee_board_v1')).finally(()=>boardRead=null);
    const {data,error}=await boardRead;if(error)throw error;
    if(activeTechnicianId!==selectionAtStart)preferredId=activeTechnicianId;
    const next=data||[];const rosterChanged=JSON.stringify(technicians)!==JSON.stringify(next);technicians=next;
    activeTechnicianId = technicians.some((item) => String(item.id) === String(preferredId)) ? String(preferredId) : String(technicians.find((item) => Number(item.pending_count || 0) > 0)?.id || technicians[0]?.id || "");
    if(rosterChanged||document.querySelector('#lab-total-pending-count').textContent==='…')renderTechnicianCards();
    for(const select of technicianWorkRows.querySelectorAll('[data-assign-employee]')){
      if(select===document.activeElement)continue;
      const choices=technicians.filter(t=>!t.unassigned),current=select.value;
      if(JSON.stringify([...select.options].slice(1).map(o=>[o.value,o.text]))!==JSON.stringify(choices.map(t=>[String(t.id),t.full_name]))){
        select.innerHTML='<option value="">Choose employee</option>'+choices.map(t=>`<option value="${escapeHtml(t.id)}">${escapeHtml(t.full_name)}</option>`).join('');
        select.value=choices.some(t=>String(t.id)===current)?current:'';
      }
    }
  }
  async function refreshAll() {
    if (isFrameMode) { await loadFrameRows(); return; }
    const previous=activeTechnicianId;
    if(previous){await Promise.all([loadTechnicians(previous),loadTechnicianRows({quiet:true})]);if(previous!==activeTechnicianId)await loadTechnicianRows();}
    else{await loadTechnicians();await loadTechnicianRows();}
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
    window.GREENLOOP_EMPLOYEES?.changed();
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
    window.GREENLOOP_EMPLOYEES?.changed();
    activeTechnicianId = "";
    await refreshAll();
  }

  function addChoice(button) {
    const holder = button.closest("[data-choice]");
    const select = holder.querySelector("select");
    const value = select.value;
    if(holder.dataset.choice==='part'&&value&&!canOrderPart(rowData(button.closest('tr')),value)){setBoardMessage('This part is already ordered or issued. Return it before reordering.');return;}
    if (!value || selectedChoices(button.closest("tr"), holder.dataset.choice).some((item) => normalise(item) === normalise(value))) return;
    holder.querySelector(".lab-choice-tags").insertAdjacentHTML("beforeend", choiceTag(holder.dataset.choice,value));
    select.value = "";
    rememberLineDraft(button.closest("tr"),holder.dataset.choice);
    markLineChanged(button.closest("tr"),holder.dataset.choice);
  }
  function addSelectedChoice(select) {
    const holder = select.closest("[data-choice]");
    const row = select.closest("tr");
    const value = select.value;
    if (!holder || !row || !value) return;
    if(holder.dataset.choice==='part'&&!canOrderPart(rowData(row),value)){select.value='';setBoardMessage('This part is already ordered or issued. Return it before reordering.');return;}
    const existing = [...holder.querySelectorAll("[data-remove-choice]")]
      .some((button) => normalise(button.dataset.value) === normalise(value));
    if (!existing) {
      holder.querySelector(".lab-choice-tags").insertAdjacentHTML(
        "beforeend",
        choiceTag(holder.dataset.choice,value)
      );
    }
    rememberLineDraft(row,holder.dataset.choice);
    row.dataset.editing = "true";
    markLineChanged(row,holder.dataset.choice);
  }
  function markLineChanged(row,kind='part') {
    editVersion+=1;row.dataset.dirty='true';
    const actions=row.querySelector('.lab-line-actions'),template=document.createElement('template');template.innerHTML=actionCell(rowData(row));
    for(const selector of ['[data-order-parts]','[data-complete-lab]','[data-line-status]']){const next=template.content.querySelector(selector),current=actions.querySelector(selector);if(current&&next){current.textContent=next.textContent;current.disabled=next.disabled;}else if(next)actions.prepend(next);}

    const serviceButton=row.querySelector('[data-save-services]');if(kind==='service'&&serviceButton)serviceButton.disabled=false;
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
    if(!editable())return;const row=button.closest('tr'),data=rowData(row),p=data?.pf_plan;if(!p)return;
    const parts=selectedChoices(row,'part').map(name=>({name,quantity:Number([...row.querySelectorAll('[data-part-quantity]')].find(e=>normalise(e.dataset.name)===normalise(name))?.value||1)}));
    const {error}=await getClient().rpc(additionalMode(data)?'add_lab_parts_v1':'submit_lab_parts_plan_v2',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_parts:parts});
    if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';clearDraftKind(row.dataset.stepId,'parts');showToast(additionalMode(data)?'Additional parts ordered.':'Parts list sent to Parts.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();
  }
  async function saveServices(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const {error}=await getClient().rpc('save_lab_services_v1',{p_step_id:row.dataset.stepId,p_services_revision:p.services_revision??0,p_services:selectedChoices(row,'service')});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';clearDraftKind(row.dataset.stepId,'services');showToast('Services saved in Lab & Glass.');await refreshAll();}
  async function assignEmployee(button){const row=button.closest('tr'),employeeId=row.querySelector('[data-assign-employee]').value;if(!employeeId){setBoardMessage('Choose an employee for this phone.');return;}const {data,error}=await getClient().rpc('assign_lab_employee_v1',{p_step_id:row.dataset.stepId,p_employee_id:employeeId});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';activeTechnicianId=String(data.employee_id);await refreshAll();showToast('Phone assigned to '+data.employee_name+'.');document.dispatchEvent(new Event('greenloop:notifications-changed'));}
  async function cancelPart(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const {error}=await getClient().rpc('cancel_lab_part_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_request_id:button.dataset.cancelPart});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';showToast('Unissued part removed.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();}
  async function submitPartReturn(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const issueId=row.querySelector('[data-pf-return-issue]').value;if(!issueId){setBoardMessage('Select the part to return.');return;}const quantity=Number(row.querySelector('[data-pf-return-qty]').value);if(!Number.isInteger(quantity)||quantity<1){setBoardMessage('Enter a valid return quantity.');return;}const {error}=await getClient().rpc('request_parts_flow_return_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_issue_id:issueId,p_quantity:quantity,p_notes:null});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';showToast('Return sent to Parts for classification.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();}
  async function completeLab(button) {
    if (!editable()) return;
    setSubmitting(button, true, "Completing...");
    const { error } = await getClient().rpc("complete_parts_only_lab_v1", { p_step_id: button.dataset.completeLab,p_revision:rowData(button.closest("tr"))?.pf_plan?.revision??0,p_services_revision:rowData(button.closest("tr"))?.pf_plan?.services_revision??0 });
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
  function clearImeiFocus(render=true) {
    cancelImeiLookup(); focusedImei = ""; focusedStepId = ""; technicianImeiScan.value = "";
    clearTechnicianImei.hidden = true; setBoardMessage(); if(render)renderTechnicianLines();
  }
  async function scanTechnicianImei() {
    if (!searchable()) return;
    const imei = technicianImeiScan.value.trim();
    if (!/^\d{15}$/.test(imei)) { setBoardMessage("Enter or scan a valid 15-digit IMEI."); return; }
    if (pendingImei === imei) return;
    if (technicianWorkRows.querySelector('tr[data-busy="yes"]')) { setBoardMessage("Wait for the current save to finish, then open the IMEI."); return; }
    const ticket = ++imeiLookupVersion;
    const scanCurrent = () => ticket === imeiLookupVersion && technicianImeiScan.value.trim() === imei && searchable() && app.isConnected;
    pendingImei = imei; focusedImei = imei; focusedStepId = ""; clearTechnicianImei.hidden = false; technicianWorkRows.innerHTML='<tr><td colspan="12" class="technician-lines-empty">Finding phone…</td></tr>';
    technicianImeiScanWrap.setAttribute("aria-busy", "true"); checkTechnicianImei.textContent = "Opening…";
    setBoardMessage("Finding the assigned technician…");
    try {
      ++rowLoadVersion;
      const data=await readWorkbench({p_employee_id:null,p_imei:imei});
      if(!scanCurrent())return;
      if(data.identity?.matched_type==='secondary'){
        renderTechnicianLines();setBoardMessage('Duplicate phone — use IMEI 1.');
        await window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei,knownRecord:data.identity,isCurrent:scanCurrent});return;
      }
      if(!data.step_id||!data.rows.length){
        technicianRows=[];renderTechnicianLines();setBoardMessage('This IMEI has no pending Lab or Glass work.');
        if(data.identity?.found)void window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei,title:'Phone unavailable here',message:'This IMEI has no pending Lab or Glass work.',knownRecord:data.identity,isCurrent:scanCurrent});return;
      }
      const technician=technicians.find(t=>String(t.id)===String(data.employee_id))||{id:data.employee_id,full_name:data.employee_name,pending_count:data.rows.length,unassigned:data.unassigned};
      if(!technicians.some(t=>String(t.id)===String(technician.id)))technicians.push(technician);
      activeTechnicianId=String(technician.id);focusedStepId=String(data.step_id);
      renderTechnicianCards();await workFilters.clear();if(!scanCurrent())return;
      applyWorkbenchRows(data.rows,{serverTime:data.server_now,workOptions:data.work_options});
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
    if (!isFrameMode) {await refreshAll();if(!technicianEditorIsActive())renderTechnicianLines();}
    else {await loadFrameGrades();await refreshAll();}
    if (!isFrameMode) {
      window.GREENLOOP_EMPLOYEES?.watch(async()=>{if(!app.hidden&&!technicianWorkRows.querySelector('tr[data-busy="yes"]')){const previous=activeTechnicianId;await loadTechnicians(activeTechnicianId);if(previous!==activeTechnicianId&&!technicianEditorIsActive())await loadTechnicianRows();}});
      const refreshBoard=()=>{if(!document.hidden&&!app.hidden&&app.isConnected)loadTechnicians(activeTechnicianId).catch(()=>{});};
      document.addEventListener('greenloop:workflow-notifications-refreshed',refreshBoard);
      window.setInterval(refreshBoard,5000);
      window.setInterval(updatePhoneAges,60000);
      window.addEventListener("storage",e=>{if(e.key==="greenloop-qc-work-options-changed"&&!document.hidden&&!app.hidden&&!technicianEditorIsActive())loadTechnicianRows({quiet:true}).catch(()=>{});});
      document.addEventListener("visibilitychange",updatePhoneAges);
      window.addEventListener("focus",updatePhoneAges);
      window.setInterval(() => {
        if (
          document.visibilityState !== "visible"
          || app.hidden
          || !app.isConnected
          || technicianEditorIsActive()
          || technicianWorkRows.querySelector('tr[data-dirty="true"], tr[data-editing="true"], tr[data-busy="yes"]')
        ) return;
        loadTechnicianRows({quiet:true}).catch(() => {});
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
    if(card.dataset.technicianId===activeTechnicianId&&!focusedImei)return;
    clearImeiFocus(false); activeTechnicianId = card.dataset.technicianId; technicianRows = [];
    renderTechnicianCards(); technicianWorkRows.innerHTML='<tr><td colspan="12" class="technician-lines-empty">Loading phone lines…</td></tr>';
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
      rememberLineDraft(row,holder.dataset.choice);
      markLineChanged(row,holder.dataset.choice);
      return;
    }
    const assign=event.target.closest('[data-assign-employee-save]');if(assign){runLineAction(assign,assignEmployee).catch(e=>setBoardMessage(e.message));return;}
    const cancelled=event.target.closest('[data-cancel-part]');if(cancelled){runLineAction(cancelled,cancelPart).catch(e=>setBoardMessage(e.message));return;}
    const saveService=event.target.closest('[data-save-services]');if(saveService){runLineAction(saveService,saveServices).catch(e=>setBoardMessage(e.message));return;}
    const returned=event.target.closest("[data-pf-return]");if(returned){runLineAction(returned,submitPartReturn).catch(e=>setBoardMessage(e.message));return;}
    const order = event.target.closest("[data-order-parts]"); if (order && !order.disabled) runLineAction(order, orderParts).catch((error) => setBoardMessage(error.message));
    const completeLabButton = event.target.closest("[data-complete-lab]"); if (completeLabButton) runLineAction(completeLabButton, completeLab).catch((error) => setBoardMessage(error.message));
    const completeFrameButton = event.target.closest("[data-complete-frame]"); if (completeFrameButton) runLineAction(completeFrameButton, completeFrame).catch((error) => setBoardMessage(error.message));
  });
  technicianWorkRows.addEventListener("change", (event) => {
    if (!editable()) return;
    if(event.target.matches('[data-pf-return-issue]')){const row=event.target.closest('tr'),available=Number(event.target.selectedOptions[0]?.dataset.available||1),qty=row.querySelector('[data-pf-return-qty]');qty.max=available;qty.value='1';row.querySelector('[data-pf-return-qty-wrap]').hidden=available<=1;return;}
    if(event.target.matches("[data-part-quantity]")){rememberLineDraft(event.target.closest("tr"),"part");markLineChanged(event.target.closest("tr"),"part");return;}
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
