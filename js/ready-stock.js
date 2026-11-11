(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#ready-stock-app");
  const permissionMessage = document.querySelector("#permission-message");
  const total = document.querySelector("#ready-stock-total");
  const totalView = document.querySelector("#ready-stock-total-view");
  const gradeSummary = document.querySelector("#ready-stock-grades");
  const stockGrades = ["A", "B", "D", "BA", "BB", "RMA"];
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
  const stockView = document.querySelector("#ready-stock-view");
  const reworkView = document.querySelector("#ready-stock-rework-view");
  const pageTitle = document.querySelector("#ready-stock-title");
  const pageSubtitle = document.querySelector("#ready-stock-subtitle");
  const singleModeButton = document.querySelector("#ready-rework-single-mode");
  const bulkModeButton = document.querySelector("#ready-rework-bulk-mode");
  const bulkInput = document.querySelector("#ready-rework-imeis");
  const bulkCount = document.querySelector("#ready-rework-count");
  const bulkResults = document.querySelector("#ready-rework-results");
  const bulkRows = document.querySelector("#ready-rework-result-rows");
  const bulkProgress = document.querySelector("#ready-rework-progress");
  const bulkNote = document.querySelector("#ready-rework-result-note");
  const bulkStop = document.querySelector("#ready-rework-stop");
  let reworkMode = "single";
  let bulkDraft = { rows: [], phones: [], tooLarge: false };
  let bulkBatch = null;
  let stopRequested = false;
  let techniciansAvailable = false;
  const unconfirmedImeis = new Set();
  let unconfirmedStorageKey;
  let client;
  let toastTimer;
  let sendingForRework = false;
  let readyGeneration = 0;
  let quantityScopes=[],phoneUser=null;
  function stockGroup(row){return {m:String(row.model||'Unknown model').trim()||'Unknown model',g:normalize(row.final_grade||'Unspecified')};}
  function registerScope(label,rows,quantity){const groups=[...new Map(rows.map(row=>{const g=stockGroup(row);return[JSON.stringify(g),g];})).values()];return quantityScopes.push({label,groups,quantity})-1;}

  function getClient() {
    if (!client) client = window.GREENLOOP_GET_CLIENT();
    return client;
  }

  function showReadyStockView(moveFocus = false) {
    if (app.hidden) return;
    const isRework = window.location.hash === "#rework";
    stockView.hidden = isRework;
    reworkView.hidden = !isRework;
    document.querySelector("#open-ready-stock-rework").hidden = isRework;
    document.querySelector("#back-to-ready-stock").hidden = !isRework;
    document.querySelector("#ready-stock-table-actions").hidden = isRework;
    document.querySelector("#ready-stock-summary").hidden = isRework;
    document.querySelector(".ready-stock-actions-menu").open = false;
    pageTitle.textContent = isRework ? "Send for rework" : "Ready Stock";
    // Keep the range status node in place while navigating to the rework form.
    rangeLabel.hidden = isRework;
    let reworkHelp = pageSubtitle.querySelector('.ready-stock-rework-help');
    if (!reworkHelp) { reworkHelp = document.createElement('span'); reworkHelp.className = 'ready-stock-rework-help'; reworkHelp.textContent = 'Send one or more phones to Laboratory or B-DEPT.'; pageSubtitle.append(reworkHelp); }
    reworkHelp.hidden = !isRework;
    document.querySelector("#ready-stock-breadcrumb").textContent = isRework ? "Send for rework" : "Ready Stock";
    document.title = isRework ? "Send for rework | Greenloop" : "Ready Stock | Greenloop";
    if (moveFocus) {
      window.scrollTo({ top: 0, behavior: "auto" });
      (isRework ? (reworkMode === "bulk" ? bulkInput : reworkImei) : pageTitle).focus({ preventScroll: true });
    }
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function normalize(value) {
    return String(value || "").trim().replace(/\s+/g, " ").toLocaleLowerCase("en");
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

  function render(data) {
    quantityScopes=[];
    // Cards use the complete aggregate response; phone rows are fetched only in the popup.
    const flatRows=Array.isArray(data?.rows)?data.rows:[];
    const totalQty=flatRows.reduce((sum,row)=>sum+Number(row.quantity||0),0);
    gradeSummary.innerHTML=stockGrades.map(grade=>{
      const gradeRows=flatRows.filter(row=>stockGroup(row).g===normalize(grade));
      const quantity=gradeRows.reduce((sum,row)=>sum+Number(row.quantity||0),0);
      const label=grade==='RMA'?'RMA Stock':'Grade '+grade;
      const scope=registerScope(label+' · Ready Stock',gradeRows,quantity);
      return `<button class="ready-stock-grade-card" type="button" data-ready-grade="${grade}" data-ready-imeis="${scope}" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-haspopup="dialog" aria-expanded="false" aria-label="${escapeHtml('View phones: '+label)}"><span>${label}</span><strong class="ready-stock-grade-count${quantity?'':' ready-stock-zero'}">${escapeHtml(quantity)}</strong><small>phones</small><span class="ready-stock-grade-view">View phones <span aria-hidden="true">→</span></span></button>`;
    }).join('');
    total.textContent=`${totalQty} phone${totalQty===1?'':'s'}`;
    totalView.dataset.readyImeis=registerScope('Total Ready Stock',flatRows,totalQty);
    totalView.disabled=false;
    rangeLabel.textContent='All current Ready Stock';
  }

  async function loadReadyStock() {
    const refresh = document.querySelector("#refresh-ready-stock");
    refresh.disabled = true;
    refresh.textContent = "Loading...";
    const generation = ++readyGeneration;
    try {
    const { data, error } = await getClient().rpc("get_ready_stock_final_grade_table", {
      p_date_from: null,
      p_date_to: null
    });
    if (generation !== readyGeneration) return;
    if (error) throw error;
    render(Array.isArray(data) ? data[0] : data);
    window.dispatchEvent(new CustomEvent('greenloop:ready-stock-refreshed'));
    } finally { if (generation === readyGeneration) { refresh.disabled = false; refresh.textContent = "Refresh stock"; } }
  }

  function renderUnconfirmedPhones() {
    document.querySelector("#ready-rework-unconfirmed").hidden = !unconfirmedImeis.size;
    document.querySelector("#ready-rework-unconfirmed-list").innerHTML = [...unconfirmedImeis].map((imei) => `<li><strong>${imei}</strong><a class="secondary-button" href="imei-search.html?q=${imei}">View device history</a><button class="secondary-button" type="button" data-checked-imei="${imei}" ${sendingForRework ? "disabled" : ""}>History checked — allow retry</button></li>`).join("");
    try { if (unconfirmedStorageKey) sessionStorage.setItem(unconfirmedStorageKey, JSON.stringify([...unconfirmedImeis])); } catch (_) { /* The visible list still protects this open page. */ }
  }

  function unconfirmedResult(imei) {
    unconfirmedImeis.add(imei);
    renderUnconfirmedPhones();
    return { state: "unknown", detail: "Not confirmed. Check the device history before allowing a retry." };
  }

  function parseBulkImeis(text) {
    const seen = new Set();
    const phones = [];
    const rows = text.trim().split(/[\s,;]+/).filter(Boolean).map((value) => {
      if (!/^\d{15}$/.test(value)) return { imei: value, state: "invalid", detail: "Enter exactly 15 digits." };
      if (seen.has(value)) return { imei: value, state: "duplicate", detail: "Duplicate IMEI — counted once." };
      seen.add(value);
      if (unconfirmedImeis.has(value)) return { imei: value, state: "unknown", detail: "Check this phone in the Check before retrying list first." };
      const row = { imei: value, state: "pending", detail: "Ready to send. Stock eligibility is checked when sending." };
      phones.push(row);
      return row;
    });
    return { rows, phones, tooLarge: false };
  }

  const bulkStateLabels = { pending: "Pending", sending: "Sending", sent: "Sent", failed: "Failed", unknown: "Not confirmed", "not-sent": "Not sent", invalid: "Invalid", duplicate: "Duplicate" };

  function renderBulkRows(rows) {
    bulkRows.innerHTML = rows.map((row, index) => `<tr><td>${escapeHtml(row.imei.length > 80 ? row.imei.slice(0, 80) + "…" : row.imei)}</td><td><span class="ready-rework-status" data-state="${row.state}">${bulkStateLabels[row.state]}</span></td><td>${escapeHtml(row.detail)}${["duplicate", "failed"].includes(row.state) && /^\d{15}$/.test(row.imei) ? ` <button type="button" class="secondary-button" data-view-imei-stage="${index}" data-search-read-only>View current stage</button>` : ""}</td></tr>`).join("");
  }

  function updateBatchProgress() {
    const count = (state) => bulkBatch.phones.filter((row) => row.state === state).length;
    bulkProgress.textContent = `${count("sent")} sent · ${count("failed")} failed · ${count("unknown")} not confirmed · ${count("pending") + count("sending") + count("not-sent")} remaining`;
  }

  function updateBulkDraft(showList = true) {
    bulkDraft = parseBulkImeis(bulkInput.value);
    const duplicates = bulkDraft.rows.filter((row) => row.state === "duplicate").length;
    const invalid = bulkDraft.rows.filter((row) => row.state === "invalid").length;
    const unconfirmed = bulkDraft.rows.filter((row) => row.state === "unknown").length;
    bulkCount.textContent = bulkDraft.tooLarge ? `Check the pasted IMEI list.` : `${bulkDraft.phones.length} phones · ${duplicates} duplicates · ${invalid} invalid${unconfirmed ? ` · ${unconfirmed} awaiting status check` : ""}`;
    if (showList) {
      bulkBatch = null;
      bulkNote.hidden = true;
      document.querySelector("#ready-rework-results-title").textContent = "Phone list";
      bulkProgress.textContent = bulkDraft.tooLarge ? "Reduce the list before sending." : "Duplicates and invalid entries will not be sent.";
      renderBulkRows(bulkDraft.tooLarge ? [] : bulkDraft.rows);
    }
    bulkResults.hidden = reworkMode !== "bulk" || (!bulkDraft.rows.length && !bulkBatch && !bulkDraft.tooLarge);
    syncReworkControls();
  }

  function syncReworkControls() {
    const isBulk = reworkMode === "bulk";
    document.querySelector("#ready-rework-single-field").hidden = isBulk;
    document.querySelector("#ready-rework-bulk-field").hidden = !isBulk;
    singleModeButton.setAttribute("aria-pressed", String(!isBulk));
    bulkModeButton.setAttribute("aria-pressed", String(isBulk));
    reworkForm.querySelectorAll("input,textarea,select,button").forEach((control) => { control.disabled = sendingForRework; });
    reworkImei.disabled = sendingForRework || isBulk;
    reworkImei.required = !isBulk;
    bulkInput.disabled = sendingForRework || !isBulk;
    bulkInput.required = isBulk;
    reworkTechnician.disabled = sendingForRework || !techniciansAvailable;
    reworkSubmit.disabled = sendingForRework || (isBulk && (bulkDraft.tooLarge || !bulkDraft.phones.length));
    reworkSubmit.textContent = sendingForRework ? "Sending..." : isBulk ? `Send ${bulkDraft.phones.length} phones for rework` : "Send for rework";
    bulkStop.hidden = !sendingForRework || !isBulk;
    bulkStop.disabled = stopRequested;
    bulkStop.textContent = stopRequested ? "Stopping after current phone..." : "Stop after current phone";
    renderUnconfirmedPhones();
  }

  function setReworkMode(mode) {
    if (sendingForRework) return;
    reworkMode = mode;
    updateBulkDraft(false);
    (mode === "bulk" ? bulkInput : reworkImei).focus();
  }

  function reworkErrorMessage(error) {
    if (error?.code === "PGRST202") return "Run the latest Greenloop database update before sending Ready Stock for rework.";
    if (String(error?.message || "").includes("not currently available in Ready Stock")) return "This mobile is not in Ready Stock.";
    return error?.message || "Phone could not be sent for rework.";
  }

  async function requestRework(imei, destination) {
    let timeout;
    try {
      const result = await Promise.race([
        getClient().rpc("send_ready_stock_for_rework_atomic_v2", { p_imei: imei, p_department: destination.department, p_customer_reason: destination.reason || null, p_technician_id: destination.department === "laboratory" ? destination.technician : null }),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error("Phone response timed out.")), 45000); })
      ]);
      if (result.error) {
        // A missing response may hide a committed change. Do not automatically retry.
        if (!result.error.code || result.status >= 500) return unconfirmedResult(imei);
        return { state: "failed", detail: reworkErrorMessage(result.error), stageUnavailable: /not currently available in Ready Stock/i.test(result.error.message || ""), stop: ["42501", "PGRST202", "PGRST301", "PGRST302"].includes(result.error.code) };
      }
      return { state: "sent", detail: `Sent to ${destination.name}. Journey updated.` };
    } catch (_) {
      return unconfirmedResult(imei);
    } finally { clearTimeout(timeout); }
  }

  async function sendBulkForRework(destination) {
    // Keep the batch and destination fixed even if the user navigates between views.
    bulkBatch = { rows: bulkDraft.rows.map((row) => ({ ...row })), phones: [] };
    bulkBatch.phones = bulkBatch.rows.filter((row) => row.state === "pending");
    bulkResults.hidden = false;
    bulkNote.hidden = true;
    document.querySelector("#ready-rework-results-title").textContent = "Batch results";
    renderBulkRows(bulkBatch.rows);
    updateBatchProgress();
    for (let index = 0; index < bulkBatch.phones.length; index++) {
      if (stopRequested) break;
      const row = bulkBatch.phones[index];
      row.state = "sending";
      row.detail = `Sending to ${destination.name}...`;
      renderBulkRows(bulkBatch.rows);
      const result = await requestRework(row.imei, destination);
      Object.assign(row, result);
      updateBatchProgress();
      renderBulkRows(bulkBatch.rows);
      if (result.state === "unknown" || result.stop) { stopRequested = true; break; }
    }
    bulkBatch.phones.filter((row) => row.state === "pending").forEach((row) => { row.state = "not-sent"; row.detail = "Not sent. Kept in the input list."; });
    // Sent and unconfirmed phones are excluded from a subsequent batch.
    // Unconfirmed IMEIs remain in the result list for journey verification.
    bulkInput.value = bulkBatch.rows.filter((row) => ["failed", "not-sent", "invalid"].includes(row.state)).map((row) => row.imei).join("\n");
    const unknown = bulkBatch.phones.some((row) => row.state === "unknown");
    bulkNote.textContent = unknown ? "Connection or server response was not confirmed, so the batch stopped. Check the device journey for each Not confirmed phone before re-entering it. Failed and not-sent phones remain in the input list." : "Sent phones were removed from the input list. Failed, invalid and not-sent entries remain for correction or retry.";
    bulkNote.hidden = false;
    updateBatchProgress();
    renderBulkRows(bulkBatch.rows);
    updateBulkDraft(false);
    showToast("Bulk rework finished. Check the per-phone results below.");
  }

  async function sendForRework(event) {
    event.preventDefault();
    if (sendingForRework) return;
    if (window.GREENLOOP_PAGE_ACCESS?.canEdit === false) { showToast("Entry Allowed permission is required to send phones for rework."); return; }
    const department = reworkDepartment.value;
    const technician = reworkTechnician.value;
    const imei = reworkImei.value.trim();
    const reason = reworkReason.value.trim();
    const isBulk = reworkMode === "bulk";
    if (isBulk) {
      updateBulkDraft();
      if (bulkDraft.tooLarge || !bulkDraft.phones.length) { showToast("Enter valid unique 15-digit IMEIs."); bulkInput.focus(); return; }
    } else if (!/^\d{15}$/.test(imei)) { showToast("Enter a 15-digit Ready Stock IMEI."); reworkImei.focus(); return; }
    if (!isBulk && unconfirmedImeis.has(imei)) { showToast("Check this phone in the Check before retrying list first."); return; }
    const departmentName = department === "frame" ? "B-DEPT" : "Laboratory";
    if (department === "laboratory" && !technician) { showToast("Select the Laboratory technician."); reworkTechnician.focus(); return; }
    if (!["laboratory", "frame"].includes(department)) { showToast("Select a rework department."); return; }
    if (!window.confirm(`Send ${isBulk ? bulkDraft.phones.length + " phones" : imei} from Ready Stock to ${departmentName}${department === "laboratory" ? " — " + reworkTechnician.selectedOptions[0].textContent : ""}?`)) return;
    sendingForRework = true;
    stopRequested = false;
    syncReworkControls();
    try {
      const destination = { department, technician, reason, name: departmentName };
      if (isBulk) {
        await sendBulkForRework(destination);
      } else {
        const result = await requestRework(imei, destination);
        if (result.state === "unknown") reworkImei.value = "";
        if (result.state === "failed" && result.stageUnavailable) {
          window.GREENLOOP_IMEI_STAGE_NOTICE?.show({
            imei, title: "Phone unavailable here", message: result.detail, onlyIfFound: true,
            isCurrent: () => reworkMode === "single" && !reworkView.hidden && reworkImei.value.trim() === imei
          });
        }
        if (result.state !== "sent") throw new Error(result.detail);
        const bulkText = bulkInput.value;
        reworkForm.reset();
        bulkInput.value = bulkText;
        showToast(`Phone sent to ${departmentName}. Journey updated.`);
        syncReworkTechnician();
      }
      try { await loadReadyStock(); } catch (_) { showToast("Rework results are saved. Refresh Ready Stock to update the table."); }
    } finally { sendingForRework = false; syncReworkControls(); }
  }

  function syncReworkTechnician() { reworkTechnicianWrap.hidden = reworkDepartment.value !== "laboratory"; }
  async function loadReworkTechnicians() {
    const { data, error } = await getClient().rpc("get_ready_stock_rework_technicians");
    if (error) {
      techniciansAvailable = false;
      reworkTechnician.replaceChildren(new Option("Technicians unavailable — run the update", ""));
      reworkTechnician.disabled = true;
      showToast(error.message || "Laboratory technicians could not be loaded.");
      return;
    }
    reworkTechnician.replaceChildren(new Option("Select technician", ""));
    (data || []).forEach((item) => reworkTechnician.add(new Option(item.full_name || item.email || "Technician", item.id)));
    techniciansAvailable = true;
    syncReworkControls();
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
    phoneUser=sessionData.session.user.id;
    getClient().auth.onAuthStateChange?.((event,session)=>{if(event==='SIGNED_OUT'||session?.user?.id&&session.user.id!==phoneUser){quantityScopes=[];}});
    unconfirmedStorageKey = `greenloop-rework-unconfirmed:${sessionData.session.user.id}`;
    try {
      const saved = JSON.parse(sessionStorage.getItem(unconfirmedStorageKey) || "[]");
      if (Array.isArray(saved)) saved.filter((imei) => typeof imei === "string" && /^\d{15}$/.test(imei)).forEach((imei) => unconfirmedImeis.add(imei));
    } catch (_) { /* Invalid browser storage must not stop the page. */ }
    renderUnconfirmedPhones();
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
    showReadyStockView();
    await Promise.all([loadReadyStock(), loadReworkTechnicians()]);
    syncReworkTechnician();
  }

  document.addEventListener('click',event=>{
    const button=event.target.closest('button[data-ready-imeis]');
    if(!button||button.disabled)return;
    const scope=quantityScopes[Number(button.dataset.readyImeis)];
    if(scope)window.GREENLOOP_READY_GROUPS?.open({...scope,mode:'current',source:button});
  });
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-ready-stock").addEventListener("click", () => loadReadyStock().catch((error) => showToast(error.message || "Ready Stock could not be loaded.")));
  reworkImei.addEventListener("input", () => { reworkImei.value = reworkImei.value.replace(/\D/g, "").slice(0, 15); });
  reworkDepartment.addEventListener("change", syncReworkTechnician);
  singleModeButton.addEventListener("click", () => setReworkMode("single"));
  bulkModeButton.addEventListener("click", () => setReworkMode("bulk"));
  bulkInput.addEventListener("input", () => updateBulkDraft());
  bulkRows.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-view-imei-stage]");
    if (!button || sendingForRework) return;
    const rows = bulkBatch?.rows || bulkDraft.rows;
    const row = rows[Number(button.dataset.viewImeiStage)];
    if (!row || !["duplicate", "failed"].includes(row.state) || !/^\d{15}$/.test(row.imei)) return;
    window.GREENLOOP_IMEI_STAGE_NOTICE?.show({
      imei: row.imei, title: row.state === "duplicate" ? "Duplicate phone" : "Phone unavailable here", message: row.detail, onlyIfFound: row.state !== "duplicate",
      isCurrent: () => button.isConnected && reworkMode === "bulk" && !reworkView.hidden && (bulkBatch?.rows || bulkDraft.rows) === rows
    });
  });
  document.querySelector("#ready-rework-unconfirmed-list").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-checked-imei]");
    if (!button || sendingForRework) return;
    unconfirmedImeis.delete(button.dataset.checkedImei);
    renderUnconfirmedPhones();
    updateBulkDraft(false);
  });
  bulkStop.addEventListener("click", () => { stopRequested = true; bulkStop.disabled = true; bulkStop.textContent = "Stopping after current phone..."; });
  window.addEventListener("beforeunload", (event) => { if (sendingForRework) { event.preventDefault(); event.returnValue = ""; } });
  reworkForm.addEventListener("submit", (event) => sendForRework(event).catch((error) => showToast(error.message || "Phone could not be sent for rework.")));
  window.addEventListener("hashchange", () => showReadyStockView(true));
  window.GREENLOOP_EMPLOYEES?.watch(data=>{if(!techniciansAvailable||sendingForRework||document.activeElement===reworkTechnician)return;const next=data.map(e=>[String(e.id),e.full_name]),current=[...reworkTechnician.options].filter(o=>o.value).map(o=>[o.value,o.textContent]);if(JSON.stringify(next)===JSON.stringify(current))return;const selected=reworkTechnician.value;reworkTechnician.replaceChildren(new Option('Select technician',''));for(const e of data)reworkTechnician.add(new Option(e.full_name,e.id));reworkTechnician.value=selected;syncReworkControls();});
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Ready Stock could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
