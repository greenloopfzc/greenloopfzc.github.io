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
  const hideTechnicianButton = document.querySelector('#hide-lab-technician');
  const showHiddenButton = document.querySelector('#show-hidden-technicians');
  let hiddenTechnicianIds = new Set(), showHiddenTechnicians = false, visibilityReady = false, visibilityBusy = false, visibilityRevision = 0;
  const canManageVisibility = () => !isFrameMode && editable() && window.GREENLOOP_CAN?.('manage_options','lab_glass') === true;
  const isHiddenTechnician = t => !t.unassigned && hiddenTechnicianIds.has(String(t.id));
  const visibleTechnicians = () => technicians.filter(t => !isHiddenTechnician(t) || showHiddenTechnicians || String(t.id) === activeTechnicianId);
  function applyVisibility(data) { if(!Array.isArray(data?.hidden_ids) || !data.hidden_ids.every(id=>typeof id==='string'))throw Error('Technician card visibility could not be verified. Refresh and retry.'); hiddenTechnicianIds = new Set(data.hidden_ids); visibilityReady = true; }
  async function changeTechnicianVisibility() {
    if (!canManageVisibility() || !visibilityReady || visibilityBusy) return;
    const technician = technicians.find(t => String(t.id) === activeTechnicianId);
    if (!technician || technician.unassigned || bulkWorkbenchImeis) return;
    if (window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()) throw Error('Save or cancel your phone changes before hiding or showing a technician.');
    const hidden = !isHiddenTechnician(technician); visibilityBusy = true; visibilityRevision++; renderTechnicianCards();
    try {
      const {data,error} = await getClient().rpc('set_lab_technician_visibility_v1',{p_employee_id:technician.id,p_hidden:hidden});
      if (error) throw error; applyVisibility(data); visibilityRevision++;
      if (hidden && !showHiddenTechnicians) { clearImeiFocus(false); activeTechnicianId = String(technicians.find(t => !isHiddenTechnician(t))?.id || ''); technicianRows = []; await loadTechnicianRows(); }
      setBoardMessage(technician.full_name + (hidden ? ' is hidden from Lab & Glass cards. Records and pending phones are preserved.' : ' is visible in Lab & Glass again.'),true);
    } finally { visibilityBusy = false; renderTechnicianCards(); }
  }
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let technicians = [];
  let technicianRows = [];
  let activeTechnicianId = "";
  let bulkWorkbenchImeis=null,mainScanReads=0;
  let activePhoneStepId = "";
  let partOptions = [...standardParts];
  const usageCounts = {part: new Map(), service: new Map()};
  function rankChoices(kind, options) { return [...options].sort((a,b) => (usageCounts[kind].get(normalise(b)) || 0) - (usageCounts[kind].get(normalise(a)) || 0) || (normalise(a) < normalise(b) ? -1 : normalise(a) > normalise(b) ? 1 : 0)); }
  let manualLabPartsMode = false;
  let frameGradeItems = [];
  let frameScan=null;
  const frameDrafts=new Map();
  let frameLabTechnicians = [], frameLabDefaults = new Map();
  const lineDrafts = new Map();
  const workbenchReads = new Map();
  let boardRead = null;
  let backgroundRead=null,backgroundQueued=false,backgroundTimer=null,labStopped=false;
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
    document.title = "B-DEPT | Greenloop";
    document.querySelector("#breadcrumb-stage").textContent = "B-DEPT";
    document.querySelector("#page-title").textContent = "B-DEPT";
    document.querySelector("#page-subtitle").textContent = "Complete pending phones or review previous results.";
    document.querySelector(".lab-heading .quiet-link").href = "final-qc.html";
    document.querySelector(".lab-heading .quiet-link").textContent = "← Back to Final QC";
    technicianBoard.hidden = true;
    document.querySelector("#open-b-dept-report").hidden = false;
    technicianImeiScanWrap.hidden = true;
    document.querySelector("#frame-view-controls").hidden = false;
    frameViewTabs.hidden = false;
    framePendingPanel.setAttribute('role', 'tabpanel');
    framePendingPanel.setAttribute('aria-labelledby', 'frame-pending-tab');
    frameReportPanel.setAttribute('role', 'tabpanel');
    frameReportPanel.setAttribute('aria-labelledby', 'frame-history-tab');
    showFrameView('pending');
    frameScan=window.GREENLOOP_B_DEPT_SCAN.mount({host:framePendingPanel,getRows:()=>technicianRows,reload:()=>loadFrameRows(true),render:renderFrameLines,start:()=>workFilters.clear(),resetDrafts:()=>{frameDrafts.clear();technicianWorkRows.replaceChildren();},allowed:()=>editable()&&window.GREENLOOP_CAN?.('entry','frame_department')===true});
    linesKicker.hidden = true;
    technicianLinesTitle.textContent = "Pending work";
    technicianLinesHelp.textContent = "Choose a destination after Pass. Selections carry to the visible rows below. Save each phone to transfer it.";
    refreshFrameButton.hidden = false;
    linesHead.innerHTML = "<th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>Initial BH</th><th>Final BH</th><th>Supplier code</th><th>Supplier grade</th><th>Initial grade</th><th>Final grade</th><th>Pass</th><th>Fail</th><th>Destination / Save</th>";
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
    technicianCards.innerHTML = visibleTechnicians().length ? visibleTechnicians().map((technician) => {
      const count = Number(technician.pending_count || 0);
      const active = String(technician.id) === String(activeTechnicianId);
      return `<button class="technician-card${active ? " is-active" : ""}${isHiddenTechnician(technician) ? " is-hidden-technician" : ""}" type="button" data-capability="view" data-capability-page="lab_glass" data-search-read-only data-technician-id="${escapeHtml(technician.id)}" aria-pressed="${active}"><span class="technician-avatar">${escapeHtml(initials(technician.full_name))}</span><span class="technician-card-copy"><strong>${escapeHtml(technician.full_name)}</strong>${isHiddenTechnician(technician)?'<small class="technician-hidden-label">Hidden card</small>':''}<span>${count} ${technician.unassigned?'unassigned':'assigned'} IMEI${count === 1 ? "" : "s"}</span></span><span class="technician-card-count${count ? "" : " is-zero"}" aria-label="${count} pending phone${count===1?'':'s'}">${count.toLocaleString('en-US')}</span></button>`;
    }).join("") : '<p class="technician-lines-empty">No visible technician cards. Choose Show hidden to view hidden cards.</p>';
    const selected = bulkWorkbenchImeis?{full_name:"Pasted IMEIs",pending_count:technicianRows.length}:technicians.find((item) => String(item.id) === String(activeTechnicianId));
    technicianBoardTitle.textContent = selected?.unassigned?'Phones awaiting employee assignment':selected ? `${selected.full_name}'s assigned work` : "Select a technician";
    technicianLinesTitle.textContent = selected?.unassigned?'Unassigned phones':selected ? `${selected.full_name}'s phone lines` : "Assigned phone lines";
    removeTechnicianButton.disabled = !selected || !!selected.unassigned;
    const hiddenCount=technicians.filter(isHiddenTechnician).length;
    if(!hiddenCount)showHiddenTechnicians=false;
    showHiddenButton.textContent=(showHiddenTechnicians?'Hide hidden':'Show hidden')+' ('+hiddenCount+')';
    showHiddenButton.disabled=!visibilityReady || visibilityBusy || !hiddenCount;
    showHiddenButton.setAttribute('aria-pressed',String(showHiddenTechnicians));
    hideTechnicianButton.hidden=!canManageVisibility();
    hideTechnicianButton.disabled=!visibilityReady || visibilityBusy || !selected || !!selected.unassigned || !!bulkWorkbenchImeis;
    hideTechnicianButton.textContent=visibilityBusy?'Saving…':hiddenTechnicianIds.has(activeTechnicianId)?'Show selected':'Hide selected';
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
  function choiceTag(kind,value,quantity=1,damaged=false,reason=''){return kind==='part'?`<span class="pf-lab-part-tag"><button type="button" data-remove-choice="part" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button><input data-part-quantity data-name="${escapeHtml(value)}" type="number" min="1" max="10000" step="1" value="${escapeHtml(quantity)}" aria-label="Quantity for ${escapeHtml(value)}"><label class="pd-check"><input type="checkbox" data-part-damaged data-name="${escapeHtml(value)}" ${damaged?'checked':''}> Damaged</label><input class="pd-reason" data-part-damage-reason data-name="${escapeHtml(value)}" value="${escapeHtml(reason)}" maxlength="1000" placeholder="Reason (optional)" aria-label="Damage reason for ${escapeHtml(value)}" ${damaged?'':'hidden'}></span>`:`<button type="button" data-remove-choice="service" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`;}
  function damageBadge(part){return part.damaged?`<span class="pd-badge" title="${escapeHtml([part.damage_by,part.damage_at?new Date(part.damage_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai'}):'',part.damage_source==='parts'?'Parts':'Lab & Glass',part.damage_reason].filter(Boolean).join(' · '))}">Damaged</span>`:'';}
  function draftChoice(kind,value,data){const d=lineDrafts.get(String(data.step_id)),saved=!additionalMode(data)?data.pf_plan?.parts?.find(p=>normalise(p.name)===normalise(value)):null;return choiceTag(kind,value,d?.quantities?.[value]??saved?.quantity??1,d?.damaged?.[value]??saved?.damaged??false,d?.damageReasons?.[value]??saved?.damage_reason??'');}

  function additionalMode(row) { const p=row?.pf_plan; return !!(p?.additional_only||p?.submitted||p?.locked); }
  function canOrderPart(row,name) {
    if(!additionalMode(row))return true;const p=row.pf_plan,k=normalise(name);
    if(p.parts.some(x=>normalise(x.name)===k&&Number(x.quantity)>Number(x.issued)))return false;
    const issued=(p.part_history||p.parts).some(x=>normalise(x.name)===k&&Number(x.issued)>0);
    return !issued||(p.reorder_available||[]).some(x=>normalise(x.name)===k&&Number(x.quantity)>0);
  }
  function choiceCell(kind, options, selected, data={}) {
    return `<div class="lab-choice" data-choice="${kind}"><div class="lab-choice-row"><select data-lab-options-deferred><option value="">${kind==='part'?'Select part':'Select service'}</option></select><button type="button" data-add-choice="${kind}" title="Add">+</button></div><div class="lab-choice-tags">${unique(selected).map(value=>draftChoice(kind,value,data)).join('')}</div></div>`;
  }
  function expandLabOptions(event){
    const select=event.target.closest?.('select[data-lab-options-deferred]');if(!select||select.disabled)return;
    const holder=select.closest('[data-choice]'),kind=holder?.dataset.choice,row=rowData(select.closest('tr'));if(!row)return;
    const value=select.value,choices=kind==='part'?unique([...partOptions,...(row.pf_plan?.part_history||[]).map(p=>p.name)]).filter(name=>canOrderPart(row,name)):standardServices;
    select.innerHTML=optionsMarkup(rankChoices(kind,choices),kind==='part'?'Select part':'Select service');
    if(value&&![...select.options].some(o=>o.value===value))select.insertAdjacentHTML('beforeend',`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`);select.value=value;delete select.dataset.labOptionsDeferred;
  }
  for(const event of ['focusin','pointerdown','keydown'])technicianWorkRows.addEventListener(event,expandLabOptions);
  function selectedChoices(row, kind) {
    const tags = [...row.querySelectorAll(`[data-choice="${kind}"] [data-remove-choice]`)].map((button) => button.dataset.value);
    const currentSelection = row.querySelector(`[data-choice="${kind}"] select`)?.value || "";
    return unique([...tags, currentSelection]);
  }
  function rememberLineDraft(row, kind) {
    if (!row?.dataset.stepId) return;
    const id=String(row.dataset.stepId),old=lineDrafts.get(id)||{};
    lineDrafts.set(id, {...old,cycle:rowData(row)?.pf_plan?.cycle,modeLocked:additionalMode(rowData(row)),
      ...(kind==='part'?{parts:selectedChoices(row,'part'),quantities:Object.fromEntries([...row.querySelectorAll('[data-part-quantity]')].map(e=>[e.dataset.name,e.value])),damaged:Object.fromEntries([...row.querySelectorAll('[data-part-damaged]')].map(e=>[e.dataset.name,e.checked])),damageReasons:Object.fromEntries([...row.querySelectorAll('[data-part-damage-reason]')].map(e=>[e.dataset.name,e.value])),partsDirty:true}:{}),
      ...(kind==='service'?{services:selectedChoices(row,'service'),servicesDirty:true}:{})});
  }
  function clearDraftKind(id,kind){const d=lineDrafts.get(String(id));if(!d)return;delete d[kind+'Dirty'];delete d[kind==='parts'?'parts':'services'];if(kind==='parts'){delete d.quantities;delete d.damaged;delete d.damageReasons;delete d.damageAction;}if(!d.partsDirty&&!d.servicesDirty)lineDrafts.delete(String(id));}
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
    const p=row.pf_plan||{},st=lineWorkflowState(row),d=lineDrafts.get(String(row.step_id))||{},servicesReady=p.services_saved||!p.services?.length,ready=!row.handover_unverified&&st.allIssued&&!st.pendingReturns.length&&servicesReady&&!d.partsDirty&&!d.servicesDirty;
    const send=st.hasParts||st.submitted||d.partsDirty;
    return `${additionalMode(row)?`<button type="button" class="line-save order-parts" data-order-parts="${escapeHtml(row.step_id)}" ${d.partsDirty&&d.parts?.length?'':'disabled'}>Order Additional Parts</button>`:send?`<button type="button" class="line-save order-parts" data-order-parts="${escapeHtml(row.step_id)}">${st.submitted?'Update Parts list':'Send to Parts'}</button>`:''}<button type="button" class="line-save job-completed" data-complete-lab="${escapeHtml(row.step_id)}" ${ready?'':'disabled'}>Job Completed</button><small class="line-status" data-line-status>${row.handover_unverified?'Readiness not verified. Refresh this phone before transfer.':d.partsDirty||d.servicesDirty?'Save the changed list before completing the job':st.pendingReturns.length?'Waiting for Parts return review':!servicesReady?'Save the Lab services list':ready?'Ready to send to Final QC':!st.submitted?'Send the parts list to Parts':'Waiting for required parts'}</small>`;
  }
  function activePartList(row){const parts=row.pf_plan?.parts||[];return parts.length?'<ul class="pp-active-parts">'+parts.map(p=>`<li><span>${escapeHtml(p.name)} × ${escapeHtml(p.quantity)} ${damageBadge(p)} <small>${Number(p.issued)>=Number(p.quantity)?'Issued':'Awaiting issue'}</small></span>${p.can_cancel?`<button type="button" data-cancel-part="${escapeHtml(p.request_id)}" aria-label="Remove unissued ${escapeHtml(p.name)}">Remove</button>`:''}</li>`).join('')+'</ul>':'<small>No active parts.</small>';}
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
  function phoneCardHeader(row,status,serial) {
    const active=String(row.step_id)===activePhoneStepId;
    return `<header class="lab-card-header"><div class="lab-card-identity"><span class="lab-card-kicker">S.No ${serial} · IMEI</span><h3 id="lab-phone-${escapeHtml(row.step_id)}" class="lab-card-imei"><bdi>${escapeHtml(row.imei||"—")}</bdi>${row.returned_from_final_qc===true?'<strong class="lab-final-qc-return">Failed &amp; Returned from Final QC</strong>':''}</h3><p class="lab-card-model">${escapeHtml(row.model||"—")}</p></div><div class="lab-card-meta">${phoneTime(row)}<div class="lab-card-status"><span>${escapeHtml(status)}</span></div><span class="lab-active-indicator" ${active?'':'hidden'}>Active phone</span></div></header>`;
  }
  function activatePhoneCard(event) {
    if(isFrameMode||event.type==='pointerdown'&&event.button!==0)return;
    const row=event.target.closest?.('.lab-phone-row[data-step-id]');if(!row||!technicianWorkRows.contains(row))return;
    activePhoneStepId=String(row.dataset.stepId);
    for(const item of technicianWorkRows.querySelectorAll('.lab-phone-row')){const active=item.dataset.stepId===activePhoneStepId;item.querySelector('.lab-phone-card')?.classList.toggle('is-active',active);const badge=item.querySelector('.lab-active-indicator');if(badge)badge.hidden=!active;}
  }
  function renderTechnicianLines() {
    technicianWorkRows.closest("table").classList.toggle("lab-separated-phones",!isFrameMode);
    const selectedTech = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    const assignedRows = technicianRows.filter((row) => isFrameMode ? String(row.department) === "frame" : ["laboratory", "glass"].includes(String(row.department)));
    const filtered = assignedRows.filter(row => !focusedImei || (String(row.imei) === focusedImei && (!focusedStepId || String(row.step_id) === focusedStepId)));
    technicianLinesCount.textContent = focusedImei ? `${filtered.length} matching phone${filtered.length === 1 ? "" : "s"}` : `${filtered.length} phone${filtered.length === 1 ? "" : "s"}`;
    if (!activeTechnicianId) { technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">Select a technician.</td></tr>'; return; }
    if (!filtered.length) {
      technicianWorkRows.innerHTML = `<tr><td colspan="12" class="technician-lines-empty">${focusedImei ? `No pending line for IMEI ${escapeHtml(focusedImei)}. Use Show all to return to this technician’s phones.` : `${escapeHtml(selectedTech?.full_name || "This technician")} has no ${isFrameMode ? "B-DEPT" : "Laboratory"} phones pending.`}</td></tr>`;
      return;
    }
    if(focusedStepId&&filtered.some(row=>String(row.step_id)===String(focusedStepId)))activePhoneStepId=String(focusedStepId);
    technicianWorkRows.innerHTML = filtered.map((row,index) => {
      const qcParts = initialNames(row.initial_parts);
      const qcServices = initialServiceNames(row);
      const supplier = typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
        ? GREENLOOP_RECEIPTS.label(isFrameMode?"frame_department":"lab_glass",row.imei,row.supplier_code,row.planned_quantity,row.supplier_name,"—")
        : (row.supplier_code || "—");
      const saveCell = isFrameMode
        ? `<button class="line-save frame" type="button" data-complete-frame="${escapeHtml(row.step_id)}">Complete B-DEPT</button><small class="line-status">Returns to Final QC</small>`
        : actionCell(row);
      if (isFrameMode) {
        return `<tr data-step-id="${escapeHtml(row.step_id)}"><td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong><small class="line-supplier">${escapeHtml(supplier)}</small></td><td>${escapeHtml(row.model || "—")}</td><td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td><td>${escapeHtml(row.color || "—")}</td><td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td><td>${readOnlyList(qcParts)}</td><td>${readOnlyList(qcServices)}</td><td>${readOnlyList(labPartNames(row))}</td><td>${readOnlyList(labServiceNames(row))}</td><td>—</td><td>—</td><td>${saveCell}</td></tr>`;
      }
      const staticLine = [
        labelledStatic("IMEI", `<strong class="line-imei">${escapeHtml(row.imei || "—")}</strong>`, "imei"),
        ...(bulkWorkbenchImeis?[labelledStatic("Technician",escapeHtml(row.bulk_technician_name||"Unassigned"))]:[]),
        labelledStatic("Model", escapeHtml(row.model || "—")),
        labelledStatic("GB", escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)),
        labelledStatic("Color", escapeHtml(row.color || "—")),
        labelledStatic("BH", escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)),
        labelledStatic("Supplier Code", escapeHtml(supplier), "supplier"),
        labelledStatic("Initial QC Parts", readOnlyList(qcParts)),
        labelledStatic("Initial QC Service", readOnlyList(qcServices))
      ].join("");
      if(row.unassigned){return `<tr class="lab-phone-row unassigned-phone" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card${String(row.step_id)===activePhoneStepId?' is-active':''}" aria-labelledby="lab-phone-${escapeHtml(row.step_id)}">${phoneCardHeader(row,"Awaiting employee assignment",index+1)}<div class="lab-static-grid">${staticLine}</div><div class="employee-assignment"><label>Assign employee<select data-assign-employee data-capability="entry" data-capability-page="lab_glass"><option value="">Choose employee</option>${technicians.filter(t=>!t.unassigned).map(t=>`<option value="${escapeHtml(t.id)}">${escapeHtml(t.full_name)}</option>`).join('')}</select></label><button type="button" class="line-save" data-assign-employee-save data-capability="entry" data-capability-page="lab_glass">Assign employee</button></div></article></td></tr>`;}
      const visual = linePartVisual(row);
      const draft = lineDrafts.get(String(row.step_id));
      const displayedParts = draft?.partsDirty ? draft.parts : additionalMode(row)?[]:labPartNames(row);
      const displayedServices = draft?.servicesDirty ? draft.services : labServiceNames(row);
      return `<tr class="lab-phone-row ${visual.className}" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card${String(row.step_id)===activePhoneStepId?' is-active':''}" aria-labelledby="lab-phone-${escapeHtml(row.step_id)}">${phoneCardHeader(row,visual.label,index+1)}<div class="lab-static-grid">${staticLine}</div><div class="lab-edit-grid"><fieldset class="pf-lab-choices"><div class="lab-edit-field lab-parts-field"><span class="lab-field-label">${additionalMode(row)?"Required parts":usesManualParts(row)?"Parts added in Lab":"Final parts required"}</span>${additionalMode(row)?(row.pf_plan?.qc_parts_sent?'<small class="pf-lab-lock">Initial QC parts sent directly to Parts.</small>':'')+activePartList(row)+'<span class="lab-field-label">Order additional parts</span>':''}${choiceCell("part",unique([...partOptions,...(row.pf_plan?.part_history||[]).map(p=>p.name)]),displayedParts,row)}</div></fieldset><div class="lab-edit-field pf-lab-services"><span class="lab-field-label">Lab &amp; Glass services</span>${choiceCell("service", standardServices, displayedServices,row)}<button type="button" class="line-save" data-save-services="${escapeHtml(row.step_id)}" ${row.pf_plan?.services_saved&&!draft?.servicesDirty?'disabled':''}>Save Services</button><small>${draft?.servicesDirty?'Unsaved service changes':row.pf_plan?.services_saved?'Saved in Lab &amp; Glass':'Managed in Lab &amp; Glass'}</small></div><div class="lab-line-actions">${saveCell}${issuedPartTools(row)}</div></div></article></td></tr>`;
    }).join("");
  }

  function frameLabMarkup(selected='') {
    return '<option value="">Choose Lab technician</option>'+frameLabTechnicians.map(t=>`<option value="${escapeHtml(t.id)}" ${String(t.id)===String(selected)?'selected':''}>${escapeHtml(String(t.name).toUpperCase())}</option>`).join('');
  }
  function setFrameLabOptions(data) {
    if(!Array.isArray(data?.technicians)||!Array.isArray(data?.defaults)||!Array.isArray(data?.parts)||!Array.isArray(data?.services))throw Error('Lab technician choices could not be verified. Refresh B-DEPT.');
    frameLabTechnicians=data.technicians;frameLabDefaults=new Map(data.defaults.map(x=>[String(x.step_id),String(x.technician_id)]));
  }
  const frameDestinationNames = {
    ready_stock: 'Ready Stock', lab_glass: 'Lab & Glass', final_qc: 'Final QC',
    initial_qc: 'Initial QC', issuance: 'Lab & Glass Issuance'
  };

  function carryFrameSelection(control) {
    if (!editable() || !window.GREENLOOP_CAN?.('entry', 'frame_department') || control.disabled) return;
    const source = control.closest('tr[data-step-id]');
    if (!source) return;
    const result = control.dataset.frameResult;
    const selector = ['[data-frame-result]', '[data-frame-final-grade]', '[data-frame-destination]', '[data-frame-lab-technician]'].find(key => control.matches(key));
    for (let row = source; row; row = row.nextElementSibling) {
      if (!row.dataset.stepId || row.dataset.busy === 'yes' || row.dataset.saved === 'yes' ||
          row.hidden || row.style.display === 'none') continue;
      if (result) {
        for (const box of row.querySelectorAll(selector)) {
          if (box.dataset.frameResult === result) box.checked = control.checked;
          else if (control.checked) box.checked = false;
        }
      } else {
        const field = row.querySelector(selector);
        if (field && (selector !== '[data-frame-lab-technician]' || !field.disabled)) field.value = control.value;
      }
      if (selector !== '[data-frame-final-grade]') updateFrameRoute(row);
    }
  }

  function updateFrameRoute(row) {
    const result=row.querySelector('[data-frame-result]:checked')?.dataset.frameResult||'',route=row.querySelector('[data-frame-destination]'),lab=result==='pass'&&route.value==='lab_glass';
    route.disabled=result!=='pass'||!editable();row.querySelector('[data-frame-lab-wrap]').hidden=!lab;row.querySelector('[data-frame-lab-technician]').disabled=!lab||!editable();
    row.querySelector('[data-frame-final-grade]').disabled=route.value!=='ready_stock'||!editable();row.querySelector('[data-complete-frame]').disabled=!result||!editable();
    row.querySelector('.line-status').textContent=result==='pass'?(lab?'Choose technician, then transfer to Lab & Glass':route.value==='ready_stock'?'Select Final Grade, then move to Ready Stock':'Transfer to '+frameDestinationNames[route.value]):result==='fail'?'Will stay in B-DEPT':'Select Pass or Fail';
  }
  for(const event of ['greenloop:office-locked','greenloop:signed-out'])window.addEventListener(event,()=>frameDrafts.clear());
  function captureFrameDrafts(){
    for(const row of technicianWorkRows.querySelectorAll('tr[data-step-id]')){
      if(row.dataset.saved==='yes')continue;
      const values={};for(const key of ['data-b-dept-bh','data-b-dept-unavailable','data-frame-final-grade','data-frame-destination','data-frame-lab-technician']){const el=row.querySelector('['+key+']');if(el)values[key]=el.type==='checkbox'?el.checked:el.value;}
      values.result=row.querySelector('[data-frame-result]:checked')?.dataset.frameResult||'';frameDrafts.set(String(row.dataset.stepId),values);
    }
  }
  function restoreFrameDrafts(){
    for(const row of technicianWorkRows.querySelectorAll('tr[data-step-id]')){
      const values=frameDrafts.get(String(row.dataset.stepId));if(values){for(const [key,value]of Object.entries(values)){if(key==='result'){const el=row.querySelector('[data-frame-result="'+value+'"]');if(el)el.checked=true;}else{const el=row.querySelector('['+key+']');if(el){if(el.type==='checkbox')el.checked=value;else el.value=value;}}}}
      updateFrameRoute(row);const bh=row.querySelector('[data-b-dept-bh]');bh.disabled=!editable()||row.querySelector('[data-b-dept-unavailable]').checked;
    }
  }
  function renderFrameLines() {
    captureFrameDrafts();
    technicianLinesCount.textContent = `${technicianRows.length} waiting`;
    document.querySelector("#frame-pending-tab-count").textContent = technicianRows.length;
    const visible=frameScan?frameScan.select(technicianRows):technicianRows;
    if (!visible.length) {
      technicianWorkRows.innerHTML = '<tr><td colspan="13" class="technician-lines-empty">No phones are waiting in B-DEPT.</td></tr>';
      return;
    }
    technicianWorkRows.innerHTML = visible.map((row) => {
      if(row.scan_issue||row.scan_empty)return frameScan.issueMarkup(row);
      const supplier = typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
        ? GREENLOOP_RECEIPTS.label(isFrameMode?"frame_department":"lab_glass",row.imei,row.supplier_code,row.planned_quantity,row.supplier_name,"—")
        : (row.supplier_code || "—");
      return `<tr data-step-id="${escapeHtml(row.step_id)}">
        <td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong></td>
        <td>${escapeHtml(row.model || "—")}</td>
        <td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td>
        <td>${escapeHtml(row.color || "—")}</td>
        <td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td>
        <td class="b-dept-final-bh"><input type="number" min="0" max="100" step="1" inputmode="numeric" data-b-dept-bh aria-label="Final Battery Health" placeholder="BH %" value="${escapeHtml(row.final_battery_health == null ? "" : row.final_battery_health)}" ${row.final_battery_health_unavailable?'disabled':''}><label ${row.device_platform==='android'?'':'hidden'}><input type="checkbox" data-b-dept-unavailable aria-label="Final Battery Health not available" ${row.final_battery_health_unavailable?'checked':''}>Not available</label><small>${escapeHtml(row.battery_source || 'Initial BH')}</small></td>
        <td class="frame-supplier">${escapeHtml(supplier)}</td>
        <td>${escapeHtml(row.supplier_grade || "—")}</td>
        <td>${escapeHtml(row.initial_grade || "—")}</td>
        <td><select class="frame-final-grade" data-frame-final-grade aria-label="Final Grade">${frameGradeMarkup()}</select></td>
        <td><label class="frame-pass-check"><input type="checkbox" data-frame-result="pass"><span>Pass</span></label></td>
        <td><label class="frame-fail-check"><input type="checkbox" data-frame-result="fail"><span>Fail</span></label></td>
        <td class="b-dept-route-cell"><label class="b-dept-route">After Pass<select data-frame-destination aria-label="Pass destination" data-capability="entry" data-capability-page="frame_department" disabled><option value="ready_stock">Ready Stock</option><option value="lab_glass">Lab &amp; Glass</option><option value="final_qc">Final QC</option><option value="initial_qc">Initial QC</option><option value="issuance">Lab &amp; Glass Issuance</option></select></label><label class="b-dept-route" data-frame-lab-wrap hidden>Lab technician<select data-frame-lab-technician aria-label="Lab technician" data-capability="entry" data-capability-page="frame_department" disabled>${frameLabMarkup(frameLabDefaults.get(String(row.step_id)))}</select></label><button class="line-save frame-ready" type="button" data-complete-frame="${escapeHtml(row.step_id)}" disabled>Save</button><small class="line-status">Select Pass or Fail</small></td>
      </tr>`;
    }).join("");
    restoreFrameDrafts();
    window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(framePendingPanel);
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
    frameReportRows.innerHTML = rows.length ? rows.map((row) => `<tr><td>${escapeHtml(formatDateTime(row.reviewed_at))}</td><td><strong>${escapeHtml(row.imei || "—")}</strong></td><td>${escapeHtml(row.supplier_code || "—")}</td><td>${escapeHtml(row.model || "—")}</td><td><span class="frame-result ${escapeHtml(row.result)}">${escapeHtml(String(row.result || "").toUpperCase())}</span></td><td>${escapeHtml(row.reviewed_by_name || "System")}</td></tr>`).join("") : '<tr><td colspan="6" class="technician-lines-empty">No B-DEPT results recorded yet.</td></tr>';
    },onError:()=>{frameReportRows.innerHTML='<tr><td colspan="6">B-DEPT results unavailable.</td></tr>';framePassCount.textContent=frameFailCount.textContent='Unavailable';}
  });
  async function loadFrameReport(){return frameFilters.load();}

  let workOptionsFingerprint='';
  function applyWorkOptions(data){const fingerprint=JSON.stringify(data);if(fingerprint===workOptionsFingerprint)return;workOptionsFingerprint=fingerprint;for(const [kind,list] of [['part',data.parts],['service',data.services]])usageCounts[kind]=new Map(list.map(o=>[normalise(o.name),Number(o.usage_count)||0]));partOptions=data.parts.map(o=>o.name);standardServices=data.services.map(o=>o.name);initialQcServices.clear();for(const service of data.services)if(service.initial_qc)initialQcServices.add(normalise(service.name));
    for(const holder of technicianWorkRows.querySelectorAll('[data-choice]')){const select=holder.querySelector('select');if(!select)continue;const value=select.value;select.innerHTML=optionsMarkup([],holder.dataset.choice==='part'?'Select part':'Select service');select.dataset.labOptionsDeferred='';if(value&&![...select.options].some(o=>o.value===value))select.insertAdjacentHTML('beforeend',`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`);select.value=value;}
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
      const request=labRead(getClient().rpc('get_lab_damage_workbench_v1',args)).then(({data,error})=>{if(error)throw error;if(!data||data.damage_version!=='20261117-parts-request-damage-1'||!Array.isArray(data.rows)||!data.rows.every(row=>typeof row.returned_from_final_qc==='boolean'&&typeof row.step_id==='string'&&row.step_id&&typeof row.job_id==='string'&&/^[0-9]{15}$/.test(row.imei)&&['laboratory','glass'].includes(row.department))||new Set(data.rows.map(row=>row.step_id)).size!==data.rows.length||new Set(data.rows.map(row=>row.imei)).size!==data.rows.length||!Number.isFinite(Date.parse(data.server_now))||!Array.isArray(data.work_options?.parts)||!Array.isArray(data.work_options?.services)||![...data.work_options.parts,...data.work_options.services].every(o=>typeof o.name==='string'&&o.name.trim()))throw new Error('Phone lines could not be verified.');return data;}).finally(()=>workbenchReads.delete(key));
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
  function alignSelectedCounter(){
    if(isFrameMode||focusedImei||bulkWorkbenchImeis||window.GREENLOOP_LAB_PENDING_CONTEXT?.hasDrafts())return;
    const selected=technicians.find(t=>String(t.id)===String(activeTechnicianId));if(!selected)return;
    const count=new Set(technicianRows.map(row=>row.imei)).size;
    if(selected.pending_count!==count){selected.pending_count=count;renderTechnicianCards();}
  }
  async function loadTechnicianRows({quiet=false}={}) {
    if(window.GREENLOOP_BULK_IMEI?.busy)return;
    if(bulkWorkbenchImeis){await loadBulkWorkbench(bulkWorkbenchImeis,{replace:true});return;}
    if(!app.isConnected)return;
    const version=++rowLoadVersion,technicianId=activeTechnicianId,editsAtStart=editVersion,scan=focusedImei;
    if(!quiet)setBoardMessage();
    if(!technicianId){technicianRows=[];renderTechnicianLines();return;}
    const employee=technicians.find(t=>String(t.id)===String(technicianId));
    const data=await readWorkbench({p_employee_id:employee?.unassigned?null:technicianId,p_imei:scan||null});
    if(labStopped||window.GREENLOOP_CAN?.('view','lab_glass')!==true||version!==rowLoadVersion||technicianId!==activeTechnicianId||editsAtStart!==editVersion||scan!==focusedImei)return;
    if(scan&&String(data.employee_id)!==String(technicianId)){setBoardMessage('Phone assignment changed. Scan the IMEI again.');return;}
    applyWorkbenchRows(data.rows,{quiet,serverTime:data.server_now,workOptions:data.work_options});alignSelectedCounter();return true;
  }
  async function loadFrameRows(skipHistory=false) {
    setBoardMessage();
    const [{ data, error }, choices] = await Promise.all([getClient().rpc("get_b_dept_rows_v1"),getClient().rpc("get_b_dept_lab_options_v1")]);
    if(!window.document||!app.isConnected||window.GREENLOOP_PAGE_ACCESS?.pageKey!=="frame_department"||window.GREENLOOP_CAN?.("view","frame_department")!==true)return;
    if(choices.error)throw choices.error;setFrameLabOptions(choices.data);
    if (error) throw error;
    const rows = data || [];
    await GREENLOOP_RECEIPTS.load("frame_department",rows.map(r=>r.imei));
    technicianRows = rows;
    frameScan?.refresh();
    renderFrameLines();
    if(!skipHistory)await loadFrameReport();
  }
  async function loadTechnicians(preferredId = activeTechnicianId) {
    const selectionAtStart=activeTechnicianId,renderAtStart=JSON.stringify([technicians,activeTechnicianId,[...hiddenTechnicianIds],visibilityReady]);
    if(!boardRead){const revision=visibilityRevision;boardRead=Promise.all([labRead(getClient().rpc('get_lab_employee_board_v1')),labRead(getClient().rpc('get_lab_technician_visibility_v1')).catch(error=>({error}))]).then(([board,visibility])=>{
      if(!visibility.error && Array.isArray(visibility.data?.hidden_ids) && revision===visibilityRevision && !visibilityBusy)applyVisibility(visibility.data);
      return board;
    }).finally(()=>boardRead=null);}
    const {data,error}=await boardRead;if(error)throw error;if(labStopped||window.GREENLOOP_CAN?.('view','lab_glass')!==true)return;
    if(activeTechnicianId!==selectionAtStart)preferredId=activeTechnicianId;
    if(!Array.isArray(data)||!data.every(t=>typeof t.id==='string'&&t.id&&typeof t.full_name==='string'&&Number.isSafeInteger(t.pending_count)&&t.pending_count>=0)||new Set(data.map(t=>t.id)).size!==data.length)throw new Error('Technician counts could not be verified. Select Refresh to retry.');
    const next=data;technicians=next;
    activeTechnicianId = technicians.some((item) => String(item.id) === String(preferredId)) ? String(preferredId) : String(technicians.find((item) => !isHiddenTechnician(item) && Number(item.pending_count || 0) > 0)?.id || technicians.find(item=>!isHiddenTechnician(item))?.id || "");
    if(hiddenTechnicianIds.has(activeTechnicianId)&&!showHiddenTechnicians&&!focusedImei&&!window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts())activeTechnicianId=String(technicians.find(t=>!isHiddenTechnician(t))?.id||'');
    if(renderAtStart!==JSON.stringify([technicians,activeTechnicianId,[...hiddenTechnicianIds],visibilityReady])||document.querySelector('#lab-total-pending-count').textContent==='…')renderTechnicianCards();
    for(const select of technicianWorkRows.querySelectorAll('[data-assign-employee]')){
      if(select===document.activeElement)continue;
      const choices=technicians.filter(t=>!t.unassigned),current=select.value;
      if(JSON.stringify([...select.options].slice(1).map(o=>[o.value,o.text]))!==JSON.stringify(choices.map(t=>[String(t.id),t.full_name]))){
        select.innerHTML='<option value="">Choose employee</option>'+choices.map(t=>`<option value="${escapeHtml(t.id)}">${escapeHtml(t.full_name)}</option>`).join('');
        select.value=choices.some(t=>String(t.id)===current)?current:'';
      }
    }
  }
  window.GREENLOOP_LAB_PENDING_CONTEXT = Object.freeze({
    hasDrafts: () => [...lineDrafts.values()].some(d => d.partsDirty || d.servicesDirty) || !!technicianWorkRows.querySelector('tr[data-dirty="true"], tr[data-editing="true"], tr[data-busy="yes"]'),
    onTransferred: () => refreshAll()
  });
  async function refreshAll() {
    if (isFrameMode) { await loadFrameRows(); return; }
    const previous=activeTechnicianId;
    if(previous){const results=await Promise.all([loadTechnicians(previous),loadTechnicianRows({quiet:true})]);if(previous!==activeTechnicianId)await loadTechnicianRows();else if(results[1]===true)alignSelectedCounter();}
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
    const parts=selectedChoices(row,'part').map(name=>({name,quantity:Number([...row.querySelectorAll('[data-part-quantity]')].find(e=>normalise(e.dataset.name)===normalise(name))?.value||1),damaged:[...row.querySelectorAll('[data-part-damaged]')].find(e=>normalise(e.dataset.name)===normalise(name))?.checked===true,damage_reason:[...row.querySelectorAll('[data-part-damage-reason]')].find(e=>normalise(e.dataset.name)===normalise(name))?.value.trim()||null}));
    const draft=lineDrafts.get(String(data.step_id))||{},key=JSON.stringify([p.revision,parts,additionalMode(data)]);if(draft.damageAction?.key!==key)draft.damageAction={key,id:crypto.randomUUID()};lineDrafts.set(String(data.step_id),draft);
    const {error}=await getClient().rpc('order_lab_parts_damage_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_parts:parts,p_additional:additionalMode(data),p_action_id:draft.damageAction.id});
    if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';clearDraftKind(row.dataset.stepId,'parts');showToast(additionalMode(data)?'Additional parts ordered.':'Parts list sent to Parts.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();
  }
  async function saveServices(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const {error}=await getClient().rpc('save_lab_services_v1',{p_step_id:row.dataset.stepId,p_services_revision:p.services_revision??0,p_services:selectedChoices(row,'service')});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';clearDraftKind(row.dataset.stepId,'services');showToast('Services saved in Lab & Glass.');await refreshAll();}
  async function assignEmployee(button){const row=button.closest('tr'),employeeId=row.querySelector('[data-assign-employee]').value;if(!employeeId){setBoardMessage('Choose an employee for this phone.');return;}const {data,error}=await getClient().rpc('assign_lab_employee_v1',{p_step_id:row.dataset.stepId,p_employee_id:employeeId});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';activeTechnicianId=String(data.employee_id);await refreshAll();showToast('Phone assigned to '+data.employee_name+'.');document.dispatchEvent(new Event('greenloop:notifications-changed'));}
  async function cancelPart(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const {error}=await getClient().rpc('cancel_lab_part_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_request_id:button.dataset.cancelPart});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';showToast('Unissued part removed.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();}
  async function submitPartReturn(button){const row=button.closest('tr'),p=rowData(row)?.pf_plan;if(!p)return;const issueId=row.querySelector('[data-pf-return-issue]').value;if(!issueId){setBoardMessage('Select the part to return.');return;}const quantity=Number(row.querySelector('[data-pf-return-qty]').value);if(!Number.isInteger(quantity)||quantity<1){setBoardMessage('Enter a valid return quantity.');return;}const {error}=await getClient().rpc('request_parts_flow_return_v1',{p_step_id:row.dataset.stepId,p_revision:p.revision,p_issue_id:issueId,p_quantity:quantity,p_notes:null});if(error){setBoardMessage(error.message);return;}row.dataset.saved='yes';showToast('Return sent to Parts for classification.');document.dispatchEvent(new Event('greenloop:notifications-changed'));await refreshAll();}
  async function completeLab(button) {
    if (!editable()) return;
    const line=button.closest('tr'),saved=rowData(line),current=()=>!labStopped&&line.isConnected&&window.GREENLOOP_CAN?.('entry','lab_glass')===true;
    try{
      const phone=await transferReadiness().check(saved.imei,current);if(!phone||!current())return;
      if(!phone.ready||phone.step_id!==button.dataset.completeLab){await transferReadiness().show([phone.ready?{imei:phone.imei,stage:phone.current_stage,reason:'The Lab assignment changed. Refresh this phone before transfer.'}:transferReadiness().issue(phone,saved.imei)],{input:technicianImeiScan,isCurrent:current});return;}
    }catch(error){if(current())await transferReadiness().show([transferReadiness().errorIssue(saved.imei,error)],{input:technicianImeiScan,isCurrent:current});return;}
    setSubmitting(button, true, "Completing...");
    const { error } = await getClient().rpc("complete_parts_only_lab_v1", { p_step_id: button.dataset.completeLab,p_revision:rowData(button.closest("tr"))?.pf_plan?.revision??0,p_services_revision:rowData(button.closest("tr"))?.pf_plan?.services_revision??0 });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message);await transferReadiness().show([transferReadiness().errorIssue(saved.imei,error)],{input:technicianImeiScan,isCurrent:current,title:'Transfer not completed',summary:'The transfer was not confirmed. Refresh this phone and check its current stage before another attempt.'});return; }
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
    bulkWorkbenchImeis=null; cancelImeiLookup(); focusedImei = ""; focusedStepId = ""; technicianImeiScan.value = "";
    clearTechnicianImei.hidden = true; setBoardMessage(); if(render)renderTechnicianLines();
  }
  const transferReadiness=()=>window.GREENLOOP_LAB_TRANSFER;
  const mayPrepareHandover=()=>editable()&&window.GREENLOOP_CAN?.('entry','lab_glass')===true;
  async function checkedWorkbench(imei,current){
    const preview=mayPrepareHandover()?await transferReadiness().check(imei,current):null;
    if(!current())return null;
    if(preview&&!preview.ready)return{issue:transferReadiness().issue(preview,imei)};
    const canonical=preview?.imei||imei,data=await readWorkbench({p_employee_id:null,p_imei:canonical});
    if(!current())return null;
    const matched=data.rows.filter(row=>row.imei===canonical&&(!preview||row.step_id===preview.step_id));
    if(matched.length!==1)return{issue:{imei:canonical,stage:transferReadiness().stage(data.identity?.current_stage),reason:matched.length?'Multiple active work lines need review.':'This phone is not in the current Lab & Glass work queue. Scan again to check its current assignment.'}};
    return{data,row:{...matched[0],handover_prepared:!!preview},imei:canonical};
  }
  async function loadBulkWorkbench(imeis,options={}){
    if(!searchable())return;
    if(window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()||technicianEditorIsActive()){
      await transferReadiness().show([{imei:'Prepared work',stage:'Lab & Glass',reason:'Save or cancel changed Lab work before loading pasted phones.'}],{input:technicianImeiScan});return;
    }
    cancelImeiLookup();
    const version=++rowLoadVersion,ticket=++imeiLookupVersion,edits=editVersion,loaded=[],issues=(options.rejected||[]).map(r=>({imei:r.imei,reason:r.message,stage:'Not checked'}));let next=0,last;
    const current=()=>!labStopped&&version===rowLoadVersion&&ticket===imeiLookupVersion&&edits===editVersion&&searchable()&&app.isConnected;
    const prepared=bulkWorkbenchImeis?technicianRows.slice():focusedImei?technicianRows.filter(row=>row.imei===focusedImei):[];
    imeis=[...new Set([...prepared.map(row=>row.imei),...imeis])];
    mainScanReads++;
    try{
      async function worker(){while(next<imeis.length&&current()){const imei=imeis[next++];try{
        const result=await checkedWorkbench(imei,current);if(!result||!current())return;if(result.issue){issues.push(result.issue);continue;}
        last=result.data;loaded.push({...result.row,bulk_technician_name:result.data.employee_name||'Unassigned'});
      }catch(error){if(current()){issues.push(transferReadiness().errorIssue(imei,error));const prior=prepared.find(row=>row.imei===imei);if(prior)loaded.push({...prior,handover_unverified:true});}}}}
      await Promise.all(Array.from({length:Math.min(4,imeis.length)},worker));if(!current())return;
      if(loaded.length||options.replace||prepared.length){
        const combined=[...new Map(loaded.map(row=>[row.imei,row])).values()];
        bulkWorkbenchImeis=combined.map(row=>row.imei);focusedImei='';focusedStepId='';activeTechnicianId='__bulk__';clearTechnicianImei.hidden=false;
        renderTechnicianCards();if(last)applyWorkbenchRows(combined,{serverTime:last.server_now,workOptions:last.work_options});else{technicianRows=combined;renderTechnicianLines();}
        setBoardMessage(loaded.length+(mayPrepareHandover()?' ready phone lines loaded.':' phone lines loaded.'),true);
      }
      if(issues.length)await transferReadiness().show(issues,{input:technicianImeiScan,isCurrent:current});
      else if(current())technicianImeiScan.focus({preventScroll:true});
    }finally{mainScanReads--;}
  }
  technicianImeiScan.addEventListener('paste',event=>{
    const text=event.clipboardData?.getData('text')||'';if(!/[\s,;]+/.test(text.trim()))return;
    event.preventDefault();window.clearTimeout(imeiTimer);
    const parsed=window.GREENLOOP_BULK_IMEI.parse(text);technicianImeiScan.value='';
    void loadBulkWorkbench(parsed.valid,{rejected:parsed.rejected}).catch(error=>transferReadiness().show([transferReadiness().errorIssue('Pasted list',error)],{input:technicianImeiScan}));
  });
  async function scanTechnicianImei() {
    if(!searchable())return;
    const imei=technicianImeiScan.value.trim();if(!/^\d{15}$/.test(imei)){setBoardMessage('Enter or scan a valid 15-digit IMEI.');return;}
    if(pendingImei===imei)return;
    if(window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()){
      technicianImeiScan.value='';await transferReadiness().show([{imei,stage:'Lab & Glass',reason:'Save or cancel changed Lab work before opening another phone.'}],{input:technicianImeiScan});return;
    }
    const ticket=++imeiLookupVersion,edits=editVersion,rowTicket=++rowLoadVersion;
    const current=()=>!labStopped&&ticket===imeiLookupVersion&&rowTicket===rowLoadVersion&&technicianImeiScan.value.trim()===imei&&edits===editVersion&&searchable()&&app.isConnected;
    pendingImei=imei;mainScanReads++;
    technicianImeiScanWrap.setAttribute('aria-busy','true');checkTechnicianImei.textContent='Checking…';
    try{
      const result=await checkedWorkbench(imei,current);if(!result||!current())return;
      if(result.issue){
        technicianImeiScan.value='';setBoardMessage('Phone not added. See the readiness message.');
        await transferReadiness().show([result.issue],{input:technicianImeiScan,isCurrent:()=>!labStopped&&ticket===imeiLookupVersion&&searchable()&&technicianImeiScan.value===''});return;
      }
      const {data,row,imei:canonical}=result;
      if(bulkWorkbenchImeis){
        const combined=[...new Map([...technicianRows,{...row,bulk_technician_name:data.employee_name||'Unassigned'}].map(r=>[r.imei,r])).values()];
        bulkWorkbenchImeis=combined.map(r=>r.imei);renderTechnicianCards();applyWorkbenchRows(combined,{serverTime:data.server_now,workOptions:data.work_options});
      }else{
        const technician=technicians.find(t=>String(t.id)===String(data.employee_id))||{id:data.employee_id,full_name:data.employee_name,pending_count:1,unassigned:data.unassigned};
        if(!technicians.some(t=>String(t.id)===String(technician.id)))technicians.push(technician);
        activeTechnicianId=String(technician.id);focusedImei=canonical;focusedStepId=String(row.step_id);clearTechnicianImei.hidden=false;
        renderTechnicianCards();await workFilters.clear();if(!current())return;
        applyWorkbenchRows([row],{serverTime:data.server_now,workOptions:data.work_options});
      }
      setBoardMessage('IMEI '+canonical+(row.handover_prepared?' · Ready for Final QC':' · Lab & Glass work details'),true);technicianImeiScan.value='';
      if(document.activeElement===technicianImeiScan||document.activeElement===checkTechnicianImei)technicianImeiScan.focus({preventScroll:true});
    }catch(error){if(current()){
      technicianImeiScan.value='';await transferReadiness().show([transferReadiness().errorIssue(imei,error)],{input:technicianImeiScan,isCurrent:()=>!labStopped&&ticket===imeiLookupVersion&&searchable()&&technicianImeiScan.value===''});
    }}finally{
      mainScanReads--;if(ticket===imeiLookupVersion){pendingImei='';technicianImeiScanWrap.removeAttribute('aria-busy');checkTechnicianImei.textContent='Open phone';}
    }
  }
  async function completeFrame(button) {
    if (!editable()) return;
    const row = button.closest("tr");
    const result = row.querySelector("[data-frame-result]:checked")?.dataset.frameResult || "";
    if (!result) return;
    const finalGrade = row.querySelector("[data-frame-final-grade]")?.value || "";
    const destination = row.querySelector("[data-frame-destination]").value;
    const labTechnician = row.querySelector("[data-frame-lab-technician]").value;
    if (result === "pass" && destination === "lab_glass" && !labTechnician) {setBoardMessage("Select the Lab technician before transferring this phone.");row.querySelector("[data-frame-lab-technician]").focus();return;}
    if (result === "pass" && destination === "ready_stock" && !finalGrade) {
      setBoardMessage("Select the Final Grade before passing this B-DEPT phone to Ready Stock.");
      row.querySelector("[data-frame-final-grade]")?.focus();
      return;
    }
    const bhInput = row.querySelector('[data-b-dept-bh]');
    const unavailable = row.querySelector('[data-b-dept-unavailable]').checked;
    const bhText = bhInput.value.trim(), bh = bhText === "" ? null : Number(bhText);
    if ((!unavailable && result === "pass" && bh === null) || bh !== null && (!Number.isInteger(bh) || bh < 0 || bh > 100)) {
      setBoardMessage("Enter Final Battery Health from 0 to 100 before passing this phone."); bhInput.focus(); return;
    }
    setSubmitting(button, true, "Saving...");
    const { error } = await getClient().rpc("record_b_dept_result_v2", {
      p_work_order_step_id: button.dataset.completeFrame,
      p_result: result,
      p_final_grade: result === "pass" && destination === "ready_stock" ? finalGrade : null,
      p_final_battery_health: unavailable ? null : bh,
      p_battery_health_unavailable: unavailable,
      p_notes: result === "pass" ? "B-DEPT work passed" : "B-DEPT work failed; remains pending",
      p_destination: result === "pass" ? destination : "ready_stock",
      p_technician_roster_id: result === "pass" && destination === "lab_glass" ? labTechnician : null,
      p_parts: [],
      p_services: []
    });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    row.dataset.saved = "yes";
    frameDrafts.delete(String(button.dataset.completeFrame));
    const destinationName = frameDestinationNames[destination];
    if (result === 'pass') frameScan?.complete(row.querySelector('.line-imei').textContent.trim(), 'Passed — transferred to ' + destinationName + '.');
    showToast(result === 'pass' ? 'B-DEPT passed. Phone sent to ' + destinationName + '.' : 'B-DEPT failed. Phone remains in B-DEPT.');
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }

  function scheduleBackgroundRefresh(){
    backgroundQueued=true;
    if(labStopped||isFrameMode||document.hidden||app.hidden||!app.isConnected||backgroundRead||backgroundTimer)return;
    backgroundTimer=setTimeout(runBackgroundRefresh,180);
  }
  async function runBackgroundRefresh(){
    backgroundTimer=null;if(labStopped||document.hidden||app.hidden||backgroundRead)return;
    if(mainScanReads||technicianEditorIsActive()||window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()||window.GREENLOOP_BULK_IMEI?.busy){backgroundQueued=true;backgroundTimer=setTimeout(runBackgroundRefresh,1000);return;}
    backgroundQueued=false;
    backgroundRead=refreshAll();
    try{await backgroundRead;}catch(error){if(!labStopped)setBoardMessage(error.message||'Phone details could not refresh. Use Refresh to retry.');}
    finally{backgroundRead=null;if(backgroundQueued&&!labStopped){clearTimeout(backgroundTimer);backgroundTimer=setTimeout(runBackgroundRefresh,1000);}}
  }
  function stopLabReads(){labStopped=true;++rowLoadVersion;++imeiLookupVersion;clearTimeout(backgroundTimer);backgroundQueued=false;technicianRows=[];technicians=[];lineDrafts.clear();technicianWorkRows.replaceChildren();technicianCards.replaceChildren();app.hidden=true;}
  for(const event of ['greenloop:office-locked','greenloop:signed-out','pagehide'])window.addEventListener(event,stopLabReads);
  window.addEventListener('greenloop:permissions-changed',()=>{if(window.GREENLOOP_CAN?.('view',isFrameMode?'frame_department':'lab_glass')!==true)stopLabReads();else{++rowLoadVersion;workbenchReads.clear();scheduleBackgroundRefresh();}});
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
    if (!isFrameMode) {await refreshAll();}
    else {await loadFrameGrades();await refreshAll();}
    if (!isFrameMode) {
      window.GREENLOOP_EMPLOYEES?.watch(scheduleBackgroundRefresh);
      // One fallback refresh; workflow signals/focus remain immediate. A signal
      // arriving during a request is queued, never silently consumed.
      document.addEventListener('greenloop:workflow-notifications-refreshed',scheduleBackgroundRefresh);
      window.addEventListener('storage',e=>{if(e.key==='greenloop-qc-work-options-changed')scheduleBackgroundRefresh();});
      window.setInterval(scheduleBackgroundRefresh,30000);
      window.setInterval(updatePhoneAges,60000);
      document.addEventListener('visibilitychange',()=>{updatePhoneAges();if(!document.hidden)scheduleBackgroundRefresh();});
      window.addEventListener('focus',()=>{updatePhoneAges();scheduleBackgroundRefresh();});
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
  document.querySelector("#refresh-lab").addEventListener("click", () => {setBoardMessage();refreshAll().catch((error) => setBoardMessage(error.message));});
  refreshFrameButton.addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  addTechnicianButton.addEventListener("click", () => addTechnician().catch((error) => setBoardMessage(error.message)));
  removeTechnicianButton.addEventListener("click", () => removeTechnician().catch((error) => setBoardMessage(error.message)));
  hideTechnicianButton.addEventListener('click',()=>changeTechnicianVisibility().catch(error=>setBoardMessage(error.message)));
  showHiddenButton.addEventListener('click',async()=>{
    if(!visibilityReady || visibilityBusy)return;
    if(window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()){setBoardMessage('Save or cancel your phone changes before changing the visible technician cards.');return;}
    showHiddenTechnicians=!showHiddenTechnicians;
    if(!showHiddenTechnicians && hiddenTechnicianIds.has(activeTechnicianId)){
      clearImeiFocus(false);activeTechnicianId=String(technicians.find(t=>!isHiddenTechnician(t))?.id||'');technicianRows=[];
      await loadTechnicianRows().catch(e=>setBoardMessage(e.message));
    }
    renderTechnicianCards();
  });
  document.addEventListener('greenloop:permissions-changed',()=>{if(!isFrameMode)renderTechnicianCards();});
  technicianCards.addEventListener("click", (event) => {
    const card = event.target.closest("[data-technician-id]"); if (!card) return;
    if(card.dataset.technicianId===activeTechnicianId&&!focusedImei)return;
    bulkWorkbenchImeis=null; clearImeiFocus(false); activePhoneStepId=""; activeTechnicianId = card.dataset.technicianId; technicianRows = [];
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
  clearTechnicianImei.addEventListener("click", async () => {
    if(!searchable())return;
    if(window.GREENLOOP_LAB_PENDING_CONTEXT.hasDrafts()){setBoardMessage('Save or cancel your phone changes before showing all phones.');return;}
    clearImeiFocus();technicianImeiScan.focus();
    try{await loadTechnicianRows();}catch(error){setBoardMessage(error.message);}
  });
  technicianWorkRows.addEventListener("pointerdown",activatePhoneCard);
  technicianWorkRows.addEventListener("focusin",activatePhoneCard);
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
  technicianWorkRows.addEventListener('input',event=>{if(editable()&&event.target.matches('[data-part-damage-reason]')){rememberLineDraft(event.target.closest('tr'),'part');markLineChanged(event.target.closest('tr'),'part');}});
  technicianWorkRows.addEventListener("change", (event) => {
    if (!editable()) return;
    if(event.target.matches('[data-pf-return-issue]')){const row=event.target.closest('tr'),available=Number(event.target.selectedOptions[0]?.dataset.available||1),qty=row.querySelector('[data-pf-return-qty]');qty.max=available;qty.value='1';row.querySelector('[data-pf-return-qty-wrap]').hidden=available<=1;return;}
    if(event.target.matches('[data-part-damaged]')){const tag=event.target.closest('.pf-lab-part-tag');tag.querySelector('[data-part-damage-reason]').hidden=!event.target.checked;rememberLineDraft(event.target.closest('tr'),'part');markLineChanged(event.target.closest('tr'),'part');return;}
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
    if (event.target.matches('[data-frame-destination], [data-frame-final-grade], [data-frame-result], [data-frame-lab-technician]')) {
      carryFrameSelection(event.target);
      return;
    }
    if (event.target.matches('[data-b-dept-unavailable]')) {
      const input = event.target.closest('tr').querySelector('[data-b-dept-bh]');
      input.disabled = event.target.checked; if (event.target.checked) input.value = "";
      return;
    }

  });
  document.querySelector('#open-lab-bulk')?.addEventListener('click',event=>{
    if([...lineDrafts.values()].some(d=>d.partsDirty||d.servicesDirty)||technicianWorkRows.querySelector('tr[data-busy="yes"]')){
      event.preventDefault();setBoardMessage('Save or discard the changed Lab lines before opening Bulk Transfer to Final QC.');
    }
  });
  window.addEventListener('pageshow',event=>{if(event.persisted)window.location.reload();});
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
