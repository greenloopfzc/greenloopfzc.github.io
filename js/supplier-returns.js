(() => {
  "use strict";
  const escape = (v) => String(v ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const labels = { requested: "Requested", approved: "Return Pending", returned: "Returned to Supplier", rejected: "Rejected", cancelled: "Cancelled", dead: "Dead phone", icloud_locked: "iCloud locked", other: "Other" };
  const label = v => labels[v] || String(v || "—").replaceAll("_", " ");
  const statusLabel = r => r.archived_at ? `Archived audit · ${label(r.status)}` : label(r.status);
  const date = v => v ? new Date(v).toLocaleString("en-GB", { hour12: true }) : "—";
  const supplier = r => [r.supplier_code, window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? r.supplier_name : ""].filter(Boolean).join(" · ") || "—";
  const supplierIdentity = r => [String(r.supplier_code || '').trim().replace(/-\(\d+\)$/,''), window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? r.supplier_name : ''].filter(Boolean).join(' · ') || '—';
  const receiptCode = r => {const code=String(r.supplier_code || '').trim().replace(/-\(\d+\)$/,'');const qty=r.received_quantity;return code+(qty!==null&&qty!==undefined&&qty!==''&&Number.isSafeInteger(Number(qty))&&Number(qty)>=0?'-('+Number(qty)+')':'');};
  const rid = r => r.id || r.return_id;
  const imei = r => r.imei_1 || r.imei || "Without IMEI";
  const button = (text, attrs = "") => `<button type="button" class="secondary-button sr-button" ${attrs}>${escape(text)}</button>`;
  let context, dialog, modalGeneration = 0, modalBusy = false, reportRoot, reportGeneration = 0;
  const retries = new Map();
  async function rpc(name, args = {}) {
    await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();
    const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc(name, args);
    if (error) throw Object.assign(new Error(error.code === "PGRST202" ? "Install the Supplier Returns database update first." : error.message || "The request could not be completed."), { code: error.code });
    return data;
  }
  async function getContext() { return context = await rpc("get_supplier_return_context"); }
  function allowed(key) { const cap=key==="request"?"entry":key; const page=key==="approve"?"supplier_return_approval":key==="handover"||key==="settle"?"supplier_return_handover":"supplier_returns"; return Boolean(window.GREENLOOP_CAN?.(cap,page) && context?.permissions?.[key]); }
  function fields(entries) { return `<dl class="sr-details">${entries.map(([k,v]) => `<div><dt>${escape(k)}</dt><dd>${escape(v ?? "—")}</dd></div>`).join("")}</dl>`; }
  function notify(message, error = false) {
    const el = dialog?.open ? dialog.querySelector("[data-sr-message]") : reportRoot?.querySelector("[data-sr-message]");
    if (el) { el.textContent = message; el.classList.toggle("sr-error", error); }
  }
  function modal(title, body) {
    if (modalBusy) return null;
    if (!dialog) {
      dialog = document.createElement("dialog"); dialog.className = "sr-dialog";
      document.body.append(dialog);
      dialog.addEventListener("cancel", e => { if (modalBusy) e.preventDefault(); });
      dialog.addEventListener("close", () => { ++modalGeneration; });
    }
    ++modalGeneration;
    dialog.innerHTML = `<header class="sr-heading"><h2 id="sr-dialog-title">${escape(title)}</h2>${button("Close", 'data-sr-close aria-label="Close supplier return"')}</header>${body}<p data-sr-message role="status" aria-live="polite"></p>`;
    dialog.setAttribute("aria-labelledby", "sr-dialog-title");
    dialog.querySelector("[data-sr-close]").onclick = () => { if (!modalBusy) dialog.close(); };
    if (!dialog.open) dialog.showModal();
    return dialog;
  }
  async function mutate(name, args, control, done, feedback = notify) {
    if (modalBusy) return;
    const signature = JSON.stringify([name, args]);
    if (!retries.has(signature)) retries.set(signature, crypto.randomUUID());
    modalBusy = true;
    simpleGeneration += 1;
    const scope = dialog?.open ? dialog : control?.closest("form") || reportRoot;
    const controls = [...scope.querySelectorAll("button,input,select,textarea")].map(el => [el, el.disabled]);
    controls.forEach(([el]) => { el.disabled = true; });
    feedback("Saving…");
    try {
      const result = await rpc(name, { ...args, p_idempotency_key: retries.get(signature) });
      retries.delete(signature);
      document.dispatchEvent(new CustomEvent("greenloop:supplier-return-changed", { detail: result }));
      modalBusy = false;
      await done(result);
    } catch (e) { feedback(`${e.message} If the connection was interrupted, retry the same action to check its saved result.`, true); }
    finally { modalBusy = false; controls.forEach(([el, disabled]) => { if (el.isConnected) el.disabled = disabled; }); if (reportRoot?.isConnected) reportRoot.querySelector("[data-sr-refresh]").disabled = false; if (externalRefreshPending) queueCurrentRefresh(); }
  }
  function recordFields(r) {
    return fields([["Return ID",r.return_number],["Status",statusLabel(r)],["IMEI",imei(r)],["Serial",r.serial_number],["Model",r.model],["Supplier",supplier(r)],["Batch",r.batch_number],["Reason",label(r.reason)],["Notes",r.notes],["Handover reference",r.slip_reference],["Settlement",r.settlement_type ? label(r.settlement_type) : "Open"],["Settlement reference",r.settlement_reference],["Amount",r.settlement_amount],...(r.archived_at ? [["Archived after authorized data deletion",date(r.archived_at)]] : [])]);
  }
  async function detail(id) {
    if (!modal("Supplier return details", "<p>Loading saved return…</p>")) return;
    const generation = modalGeneration;
    try {
      const [data] = await Promise.all([rpc("get_supplier_return_detail", { p_return_id: id }), getContext()]);
      if (generation !== modalGeneration || !dialog.open) return;
      const r = data.return, actions = [];
      if (r.status === "requested" && allowed("approve")) actions.push(["approve","Approve return"],["reject","Reject return"]);
      if ((r.status === "requested" || r.status === "approved" && allowed("approve")) && allowed("request")) actions.push(["cancel","Cancel return"]);
      if (r.status === "approved" && allowed("handover")) actions.push(["handover","Record physical handover"]);
      if (r.status === "returned" && !r.settled_at && !r.settlement_type && window.GREENLOOP_CAN?.("settle","supplier_return_handover")) actions.push(["settlement","Record settlement"]);
      if (r.archived_at) actions.length = 0;
      const parts = r.archived_at ? [] : data.parts || [], events = (data.events || []).map(ev => ({ ...ev, details: ev.event_data || ev.details || {} }));
      modal(r.return_number || "Return details", `${recordFields(r)}
        ${parts.length ? `<h3>Parts reconciliation</h3><p>Unused issued parts must be returned through Parts before approval / handover. Installed parts and their costs stay in history.</p>${parts.map(p => `<div class="sr-part"><strong>${escape(p.part_name)}</strong><span>Unused: ${escape(p.unused_quantity)} · Return pending: ${escape(p.pending_return_quantity)}</span>${r.status === "requested" && allowed("request") && Number(p.unused_quantity) > Number(p.pending_return_quantity) ? button("Request unused parts return", `data-sr-part="${escape(p.part_request_id)}"`) : ""}</div>`).join("")}` : ""}
        <div class="sr-actions">${actions.map(([action,title]) => button(title, `data-sr-action="${action}"`)).join("")}</div>
        <h3>Permanent return history</h3><ol class="sr-history">${events.map(ev => `<li><strong>${escape(label(ev.action || ev.event_type))}</strong><span>${escape(date(ev.created_at || ev.occurred_at))} · ${escape(ev.actor_name || ev.actor || ev.created_by_name || "Recorded user")}</span><p>${escape(ev.notes || ev.details?.notes || "")}</p>${ev.details?.slip_reference ? `<p>Handover: ${escape(ev.details.slip_reference)}</p>` : ""}${ev.details?.settlement_reference ? `<p>Settlement: ${escape(ev.details.settlement_reference)}</p>` : ""}</li>`).join("") || "<li>No events available.</li>"}</ol>`);
      dialog.querySelectorAll("[data-sr-action]").forEach(el => { el.onclick = () => actionForm(r, el.dataset.srAction); });
      dialog.querySelectorAll("[data-sr-part]").forEach(el => { el.onclick = () => actionForm(r, "request_part_return", el.dataset.srPart); });
    } catch(e) { if (generation === modalGeneration) notify(e.message, true); }
  }
  function actionForm(r, action, partId) {
    const titles = { approve:"Approve return", reject:"Reject return", cancel:"Cancel return", handover:"Record physical handover", settlement:"Record settlement", request_part_return:"Request unused parts return" };
    modal(titles[action], `<p><strong>${escape(r.return_number)}</strong> · ${escape(imei(r))} · ${escape(supplier(r))}</p><form class="sr-form" data-sr-action-form data-capability="${["approve","reject"].includes(action)?"approve":action==="handover"?"handover":action==="settlement"?"settle":"entry"}" data-capability-page="${["approve","reject"].includes(action)?"supplier_return_approval":["handover","settlement"].includes(action)?"supplier_return_handover":"supplier_returns"}">
      ${action === "handover" ? '<p>Confirm the phone has physically been handed to the supplier. This completes the return.</p><label>Return slip / handover reference<input name="slip_reference" required maxlength="200"></label>' : ""}
      ${action === "settlement" ? '<label>Settlement type<select name="settlement_type"><option value="replacement">Replacement</option><option value="credit">Credit</option><option value="refund">Refund</option></select></label><label>Replacement receipt / credit / refund reference<input name="settlement_reference" required maxlength="200"></label><label>Amount (optional, AED)<input name="amount" type="number" min="0" step="0.01"></label><p>Record the supplier agreement here. Receive replacement phones as a new stock receipt and use that receipt number above.</p>' : ""}
      ${action === "request_part_return" ? '<label>Part return reason<select name="return_reason"><option value="not_needed">Not needed</option><option value="faulty">Faulty</option><option value="damaged">Damaged</option></select></label><p>Parts Department must review and receive these parts before they return to stock.</p>' : ""}
      <label>Notes<textarea name="notes" rows="3" maxlength="2000" ${["cancel","reject"].includes(action) ? "required" : ""}></textarea></label>
      <label class="sr-check"><input name="confirm" type="checkbox" required> I confirm this action for this return.</label>
      <div class="sr-actions"><button class="primary-button" type="submit">${escape(titles[action])}</button>${button("Back", "data-sr-back")}</div></form>`);
    dialog.querySelector("[data-sr-back]").onclick = () => detail(rid(r));
    dialog.querySelector("form").onsubmit = e => {
      e.preventDefault(); const form = e.currentTarget;
      if (!form.reportValidity()) return;
      const payload = Object.fromEntries(new FormData(form)); delete payload.confirm;
      if (payload.amount === "") delete payload.amount; else if (payload.amount !== undefined) payload.amount = Number(payload.amount);
      if (partId) payload.part_request_id = partId;
      mutate("transition_supplier_return", { p_return_id: rid(r), p_action: action, p_payload: payload }, e.submitter, async () => {
        await detail(rid(r)); if (reportRoot?.isConnected) await refreshReport();
      });
    };
  }
  let simpleContext = null, simpleRows = [], simpleGeneration = 0, lastSaved = "";
  let externalRefreshPending = false, externalRefreshTimer, closeStaleDetails = false;
  function queueCurrentRefresh(deletion = false) {
    externalRefreshPending = true;
    closeStaleDetails ||= deletion;
    window.clearTimeout(externalRefreshTimer);
    if (!reportRoot?.isConnected || document.visibilityState === "hidden" || modalBusy) return;
    externalRefreshTimer = window.setTimeout(() => {
      if (!reportRoot?.isConnected || document.visibilityState === "hidden" || modalBusy) return;
      externalRefreshPending = false;
      lastSaved = "";
      if (closeStaleDetails && dialog?.open) dialog.close();
      closeStaleDetails = false;
      refreshReport();
    }, 80);
  }
  const showDate = value => value ? new Date(value).toLocaleDateString([], {day:"2-digit",month:"short",year:"numeric"}) : "—";
  const receiptLabel = r => {const qty=r.received_quantity;const batch=String(r.batch_number || '').replace(/-\(\d+\)$/,'')+(r.batch_number&&qty!==null&&qty!==undefined&&qty!==''&&Number.isSafeInteger(Number(qty))&&Number(qty)>=0?'-('+Number(qty)+')':'');return [r.invoice_number,batch,showDate(r.received_at)].filter(Boolean).join(' · ');};
  function simpleMessage(message, error = false) {
    const el = reportRoot?.querySelector("[data-sr-simple-message]");
    if (el) { el.textContent = message; el.classList.toggle("sr-error", error); }
  }
  async function refreshReport() {
    const root = reportRoot; if (!root?.isConnected) return;
    const generation = ++simpleGeneration;
    root.querySelector("[data-sr-refresh]").disabled = true;
    try {
      const [next, rows] = await Promise.all([rpc("get_simple_stock_return_context"), rpc("list_active_stock_returns", {p_from:null,p_to:null})]);
      if (root !== reportRoot || generation !== simpleGeneration) return;
      if (!Array.isArray(next?.receipts) || !Array.isArray(rows)) throw new Error("Stock Return data could not be loaded. Try Refresh.");
      simpleContext = next; simpleRows = rows;
      const canReturn = Boolean(window.GREENLOOP_PAGE_ACCESS?.canEdit && next.permissions?.can_return);
      const host = root.querySelector("[data-sr-simple-form]");
      root.querySelector("[data-sr-create]").hidden = !canReturn;
      if (canReturn && !host.querySelector("form")) renderSimpleForm(host);
      if (canReturn && host.querySelector("form")) host.querySelector("form").dispatchEvent(new CustomEvent("receipt-refresh"));
      renderSimpleReport(); simpleMessage(lastSaved);
      refreshLegacy(generation);
    } catch(e) {
      if (root === reportRoot && generation === simpleGeneration) {
        simpleContext = null; simpleRows = [];
        root.querySelector("[data-sr-simple-form]").innerHTML = "";
        root.querySelector("[data-sr-simple-table]").innerHTML = "";
        window.GREENLOOP_STOCK?.mount(root,[]);
    root.querySelector("[data-sr-total]").textContent = "";
        const legacy = root.querySelector("[data-sr-legacy]");
        legacy.hidden = true; legacy.innerHTML = "";
        simpleMessage((lastSaved ? lastSaved + " " : "") + e.message, true);
      }
    } finally { if (root === reportRoot && generation === simpleGeneration) root.querySelector("[data-sr-refresh]").disabled = false; }
  }
  function returnSearchItems(){return simpleRows.map(row=>({...row,kind:"return",id:row.return_reference,identifier:row.return_reference,title:row.return_reference,imei_1:(row.imeis || []).join(" · "),search_values:[row.reason,...(row.imeis || [])]}));}
  function renderSimpleReport() {
    const root = reportRoot, value = root.querySelector("[data-sr-report-search]").value.trim().toLowerCase();
    const rows = window.GREENLOOP_FILTERS.use('stock-return-filters', value ? window.GREENLOOP_RECORD_SEARCH.localLookup(returnSearchItems(),value).items : simpleRows, {before:root.querySelector('[data-sr-simple-table]'),fields:[['supplier_code','Supplier code'],['model','Model'],['reason','Reason']],onChange:()=>renderSimpleReport(),search:false,highlightQuery:()=>root.querySelector('[data-sr-report-search]').value,dateKey:'returned_at',dateLabel:'Returned'});
    window.GREENLOOP_STOCK?.mount(root,rows);
    root.querySelector("[data-sr-total]").textContent = rows.length + " returns · " + rows.reduce((n,r) => n + Number(r.returned_quantity || 0),0) + " phones";
    root.querySelector("[data-sr-simple-table]").innerHTML = rows.length ? '<table class="sr-table sr-simple-table"><thead><tr><th>Stock received</th><th>Supplier / code</th><th>Received qty</th><th>Return Stock</th><th>Returned</th><th>Reason</th><th>Model / GB</th><th>IMEIs</th><th>Recorded by</th></tr></thead><tbody>' +
      rows.map(r => '<tr><td>' + escape(showDate(r.received_at)) + '<small>' + escape(r.invoice_number || r.batch_number || "—") + '</small></td><td>' + escape(supplier(r)) + '</td><td>' + escape(r.received_quantity ?? "—") + '</td><td><strong>' + escape(r.returned_quantity) + '</strong></td><td>' + escape(date(r.returned_at)) + '<small>' + escape(r.return_reference || "—") + '</small>' + (r.archived ? '<small>Archived history</small>' : "") + '</td><td>' + escape(r.reason || "—") + (r.notes ? '<small>' + escape(r.notes) + '</small>' : "") + '</td><td>' + escape([r.model, r.storage_gb ? r.storage_gb + " GB" : ""].filter(Boolean).join(" · ") || "—") + '</td><td>' + ((r.imeis || []).length ? '<details><summary>' + escape(r.imeis.length) + ' IMEI(s)</summary>' + (r.imeis || []).map(v => '<small>' + escape(v) + '</small>').join("") + '</details>' : "—") + '</td><td>' + escape(r.returned_by_name || "—") + '</td></tr>').join("") + '</tbody></table>' : '<p class="sr-empty">No stock returns to show.</p>';
  }
  async function refreshLegacy(generation) {
    const root = reportRoot;
    try {
      const results = await Promise.all(["requested","approved"].map(status => rpc("list_supplier_returns", {p_status:status,p_search:null})));
      if (root !== reportRoot || generation !== simpleGeneration) return;
      const rows = results.flat().filter(r => !r.archived_at);
      const section = root.querySelector("[data-sr-legacy]");
      section.hidden = !rows.length;
      section.innerHTML = '<summary>Earlier pending returns · ' + rows.length + '</summary><p>Complete or cancel returns created with the previous workflow here.</p><div class="sr-table-wrap"><table class="sr-table"><thead><tr><th>Return</th><th>Supplier</th><th>Phone</th><th>Status</th><th>Details</th></tr></thead><tbody>' + rows.map(r => '<tr><td>' + escape(r.return_number) + '</td><td>' + escape(supplier(r)) + '</td><td>' + escape(imei(r)) + '</td><td>' + escape(statusLabel(r)) + '</td><td>' + button("View", 'data-sr-detail="' + escape(rid(r)) + '"') + '</td></tr>').join("") + '</tbody></table></div>';
      section.querySelectorAll("[data-sr-detail]").forEach(el => { el.onclick = () => detail(el.dataset.srDetail); });
    } catch(e) {
      if (root === reportRoot && generation === simpleGeneration) {
        const section = root.querySelector("[data-sr-legacy]");
        section.hidden = false; section.innerHTML = '<summary>Earlier pending returns</summary><p class="sr-error">' + escape(e.message) + '</p>';
      }
    }
  }
  function renderSimpleForm(host) {
    let scanned = [], selectedBatch = "", pasteIssues = [], lastAutoQuantity = "";
    const imeiErrors = new Map(), stockChecks = new Map();
    let checkEpoch=0, checkRevision=0, checkRunning=false, checkTimer;
    host.innerHTML = '<form class="sr-form sr-simple-form">' +
      '<div class="sr-request-start"><label>Supplier / supplier code<select name="supplier" required><option value="">Select supplier</option></select></label><label>Received stock<select name="batch" required disabled><option value="">Select received stock</option></select></label></div>' +
      '<dl class="sr-receipt-summary" data-sr-receipt hidden></dl>' +
      '<fieldset data-sr-inputs disabled><div class="sr-request-start"><label>Return quantity<input name="quantity" type="number" min="1" max="1000" step="1" required placeholder="Enter return quantity"></label><label>Reason <span class="sr-optional">Optional</span><select name="reason"><option value="">Not specified</option><option>Dead phone</option><option>iCloud locked</option><option>Other</option></select></label></div>' +
      '<label data-sr-other hidden>Return reason<input name="other_reason" maxlength="500" disabled placeholder="Describe the issue"></label>' +
      '<div class="sr-optional-fields"><label>Model <span class="sr-optional">Optional</span><input name="model" list="sr-model-options" maxlength="100" placeholder="e.g. 15 Pro"><datalist id="sr-model-options"></datalist></label><label>GB <span class="sr-optional">Optional</span><input name="storage_gb" type="number" min="1" max="16384" step="1" placeholder="e.g. 128"></label><label>Scan IMEI <span class="sr-optional">Optional</span><span class="sr-scan-line" data-multiple-imeis><input name="imei" inputmode="numeric" maxlength="15" autocomplete="off" placeholder="Scan or enter IMEI">' + button("Add", 'data-sr-add-imei') + '</span></label></div>' +
      '<div class="sr-bulk-toolbar">' + button('Bulk IMEIs','data-sr-bulk-toggle aria-expanded="false" aria-controls="sr-bulk-imei-panel"') + '<span class="sr-hint">Paste an IMEI column from Excel, or keep scanning one phone at a time.</span></div>' +
      '<section id="sr-bulk-imei-panel" class="sr-bulk-panel" data-sr-bulk-panel hidden><label>Bulk IMEIs<textarea name="bulk_imeis" rows="4" spellcheck="false" autocomplete="off" placeholder="Paste IMEIs here, one per line"></textarea></label><div class="sr-bulk-toolbar">' + button('Add IMEIs','data-sr-add-bulk') + button('Clear text','data-sr-clear-bulk') + '</div></section>' +
      button('Check stock again','data-sr-recheck hidden') + '<div class="sr-scanned" data-sr-scanned hidden></div><p class="sr-hint" data-sr-scan-message role="status" hidden></p>' +
      '<button type="submit" class="primary-button">Stock Return</button></fieldset></form>';
    const form = host.querySelector("form"), get = name => form.elements.namedItem(name), q = selector => host.querySelector(selector);
    const batch = () => simpleContext?.receipts.find(r => r.batch_id === get("batch").value && r.supplier_id === get("supplier").value);
    const canPrepare = () => form.isConnected && !modalBusy && window.GREENLOOP_PAGE_ACCESS?.canEdit === true && simpleContext?.permissions?.can_return === true && Boolean(batch()) && (typeof window.GREENLOOP_CAN!=='function'||window.GREENLOOP_CAN('entry','supplier_returns'));
    function syncQuantity(){const control=get('quantity');if(control.value===''||control.value===lastAutoQuantity){control.value=scanned.length?String(scanned.length):'';lastAutoQuantity=control.value;}}
    function showScanned() {
      q('[data-sr-scanned]').hidden = !scanned.length && !pasteIssues.length;
      const rows=scanned.map((v,i)=>{const check=stockChecks.get(v);const failed=imeiErrors.has(v)||check?.allowed===false;const receipt=check?.batch_number?{batch_number:check.batch_number,received_quantity:check.received_quantity}:null;
        return '<tr data-sr-scan-row="'+escape(v)+'"'+(failed?' class="sr-imei-error"':check?.status==='unrecorded'?' class="sr-imei-warning"':'')+'><td class="gl-serial">'+(i+1)+'</td><td>'+escape(v)+'</td><td>'+escape(receipt?receiptLabel(receipt).replace(/ · —$/,''):check?.status==='checking'?'Checking…':'Not recorded')+'</td><td>'+escape(imeiErrors.get(v)||check?.reason||'Checking stock…')+'</td><td>'+button('Remove','data-sr-remove-imei="'+i+'" aria-label="Remove IMEI '+escape(v)+'"')+'</td></tr>';});
      rows.push(...pasteIssues.map((issue,i)=>'<tr class="sr-imei-error" data-sr-paste-issue><td class="gl-serial">'+(scanned.length+i+1)+'</td><td>'+escape(issue.value)+'</td><td>—</td><td>'+escape(issue.message)+'</td><td>'+button('Remove','data-sr-remove-issue="'+i+'" aria-label="Remove issue"')+'</td></tr>'));
      q('[data-sr-scanned]').innerHTML='<table class="sr-imei-list" data-no-table-filters><thead><tr><th class="gl-serial">S.No</th><th>IMEI</th><th>Stock / Batch No</th><th>Status / reason</th><th>Remove</th></tr></thead><tbody>'+rows.join('')+'</tbody></table>';
      q('[data-sr-recheck]').hidden=!scanned.length;
      host.querySelectorAll('[data-sr-remove-imei]').forEach(el=>{el.onclick=()=>{if(!canPrepare())return;imeiErrors.delete(scanned[Number(el.dataset.srRemoveImei)]);stockChecks.delete(scanned[Number(el.dataset.srRemoveImei)]);scanned.splice(Number(el.dataset.srRemoveImei),1);syncQuantity();showScanned();queueStockCheck(scanned);scanNotice(scanned.length+' IMEI(s) added.');};});
      host.querySelectorAll('[data-sr-remove-issue]').forEach(el=>{el.onclick=()=>{if(!canPrepare())return;pasteIssues.splice(Number(el.dataset.srRemoveIssue),1);showScanned();};});
    }
    function queueStockCheck(values){
      checkRevision++;
      for(const v of values)if(scanned.includes(v)){stockChecks.set(v,{status:'checking',reason:'Checking stock…'});imeiErrors.delete(v);}
      showScanned();clearTimeout(checkTimer);checkTimer=setTimeout(runStockCheck,0);
    }
    async function runStockCheck(){
      if(checkRunning||!canPrepare())return;
      const values=scanned.filter(v=>stockChecks.get(v)?.status==='checking');if(!values.length)return;
      checkRunning=true;const epoch=checkEpoch,revision=checkRevision,selected=batch().batch_id;let timer;
      try{
        // One read for the prepared list; no per-phone saves or return mutations.
        const data=await Promise.race([rpc('check_stock_return_imeis_v1',{p_batch_id:selected,p_imeis:values}),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Stock check timed out. Click Check stock again.')),20000);})]);
        if(epoch!==checkEpoch||revision!==checkRevision||!canPrepare()||batch().batch_id!==selected)return;
        if(data?.batch_id!==selected||!Array.isArray(data.rows)||data.rows.length!==values.length)throw new Error('Incomplete stock check response. Click Check stock again.');
        const mapped=new Map();for(const row of data.rows){if(!values.includes(row.imei)||mapped.has(row.imei)||typeof row.allowed!=='boolean'||!['matched','unrecorded','blocked','wrong_stock'].includes(row.status)||typeof row.reason!=='string'||row.allowed!==['matched','unrecorded'].includes(row.status)||row.status==='matched'&&row.batch_id!==selected)throw new Error('Invalid stock check response. Click Check stock again.');mapped.set(row.imei,row);}
        for(const v of values)if(scanned.includes(v))stockChecks.set(v,mapped.get(v));
      }catch(e){if(epoch===checkEpoch&&revision===checkRevision&&canPrepare())for(const v of values)if(scanned.includes(v))stockChecks.set(v,{status:'error',allowed:false,reason:'Stock check unavailable. '+e.message});}
      finally{clearTimeout(timer);if(epoch===checkEpoch&&form.isConnected){checkRunning=false;showScanned();if(scanned.some(v=>stockChecks.get(v)?.status==='checking'))checkTimer=setTimeout(runStockCheck,0);}}
    }
    function addBulk(text){
      if(!canPrepare())return false;
      const values=String(text||'').split(/[\s,;]+/).map(v=>v.replace(/^["']|["']$/g,'').replace(/[\u0660-\u0669\u06f0-\u06f9]/g,c=>String(c.charCodeAt(0)-(c.charCodeAt(0)>=0x6f0?0x6f0:0x660)))).filter(v=>v&&!/^imei(?:[ _-]?1)?$/i.test(v));
      if(!values.length){scanNotice('Paste the IMEIs to add.',true);return false;}
      const seen=new Set(scanned),added=[],issues=[];
      for(const value of values){if(!/^\d{15}$/.test(value)){issues.push({value,message:'Use a complete 15-digit IMEI.',blocking:true});continue;}if(seen.has(value)){issues.push({value,message:'Duplicate IMEI — already added; ignored.',blocking:false});continue;}seen.add(value);added.push(value);}
      // Preserve the complete input rather than silently truncating the existing atomic return limit.
      if(scanned.length+added.length>1000){get('bulk_imeis').value=text;q('[data-sr-bulk-panel]').hidden=false;q('[data-sr-bulk-toggle]').setAttribute('aria-expanded','true');scanNotice('A return supports up to 1000 phones. The complete list is still in Bulk IMEIs; split it before adding.',true);return false;}
      scanned.push(...added);pasteIssues.push(...issues);get('bulk_imeis').value='';syncQuantity();queueStockCheck(scanned);
      scanNotice(added.length+' new IMEI(s) added · '+scanned.length+' total'+(issues.length?' · '+issues.length+' need checking.':'.'),issues.length>0);
      return true;
    }
    function scanNotice(message, error = false) {
      const el = q("[data-sr-scan-message]"); el.textContent = message; el.hidden = !message; el.classList.toggle("sr-error",error);
    }
    function addImei() {
      if(!canPrepare())return false;
      const value = get("imei").value.trim().replace(/[\u0660-\u0669\u06f0-\u06f9]/g,c=>String(c.charCodeAt(0)-(c.charCodeAt(0)>=0x6f0?0x6f0:0x660)));
      if (!/^\d{15}$/.test(value)) { scanNotice("Enter a complete 15-digit IMEI.",true); return false; }
      if (scanned.includes(value)) {
        get("imei").value = ""; scanNotice("This IMEI has already been added.",true);
        const generation = simpleGeneration, receiptId = selectedBatch;
        window.GREENLOOP_IMEI_STAGE_NOTICE?.show({
          imei: value, title: "Duplicate phone", message: "This IMEI has already been added to this Stock Return.", onlyIfFound: false,
          isCurrent: () => form.isConnected && simpleGeneration === generation && selectedBatch === receiptId && scanned.includes(value)
        });
        return false;
      }
      if (scanned.length >= 1000) { scanNotice("A return can contain up to 1000 phones.",true); return false; }
      scanned.push(value); get("imei").value = ""; syncQuantity(); queueStockCheck(scanned); scanNotice(scanned.length + " IMEI(s) added.");
      return true;
    }
    function updateReceipt() {
      const receipt = batch(), changed = selectedBatch !== (receipt?.batch_id || "");
      selectedBatch = receipt?.batch_id || "";
      q("[data-sr-inputs]").disabled = !receipt;
      q("[data-sr-receipt]").hidden = !receipt;
      if (changed) { checkEpoch++;clearTimeout(checkTimer);checkRunning=false;stockChecks.clear();scanned = []; pasteIssues=[];imeiErrors.clear();lastAutoQuantity="";get("bulk_imeis").value=""; showScanned(); scanNotice(""); get("imei").value = ""; get("quantity").value = ""; get("model").value = ""; get("storage_gb").value = ""; get("reason").value = ""; get("other_reason").value = ""; updateReason(); }
      if (!receipt) return;
      q("[data-sr-receipt]").innerHTML = [["Received",showDate(receipt.received_at)],["Supplier code",receiptCode(receipt)],["Quantity received",receipt.received_quantity],["Return Stock",receipt.returned_quantity]].map(([k,v]) => '<div><dt>' + escape(k) + '</dt><dd>' + escape(v) + '</dd></div>').join("");
      get("quantity").max = String(Math.min(1000, Math.max(0, Number(receipt.received_quantity)-Number(receipt.returned_quantity))));
      q("#sr-model-options").innerHTML = [...new Set((receipt.model_options || []).map(p => p.model).filter(Boolean))].map(v => '<option value="' + escape(v) + '"></option>').join("");
    }
    function updateSupplier(preserveBatch = "") {
      const receipts = (simpleContext?.receipts || []).filter(r => r.supplier_id === get("supplier").value);
      get("batch").innerHTML = '<option value="">Select received stock</option>' + receipts.map(r => '<option value="' + escape(r.batch_id) + '">' + escape(receiptLabel(r)) + '</option>').join("");
      get("batch").disabled = !receipts.length;
      get("batch").value = receipts.some(r => r.batch_id === preserveBatch) ? preserveBatch : receipts.length === 1 ? receipts[0].batch_id : "";
      updateReceipt();
    }
    function updateSuppliers() {
      const chosen = get("supplier").value, receiptId = get("batch").value;
      const suppliers = [...new Map((simpleContext?.receipts || []).map(r => [r.supplier_id,r])).values()];
      get("supplier").innerHTML = '<option value="">Select supplier</option>' + suppliers.map(r => '<option value="' + escape(r.supplier_id) + '">' + escape(supplierIdentity(r)) + '</option>').join("");
      get("supplier").value = suppliers.some(r => r.supplier_id === chosen) ? chosen : "";
      updateSupplier(receiptId);
    }
    function updateReason() {
      const other = get("reason").value === "Other";
      q("[data-sr-other]").hidden = !other; get("other_reason").disabled = !other; get("other_reason").required = false;
    }
    updateSuppliers();
    form.addEventListener("receipt-refresh",updateSuppliers);
    get("supplier").onchange = () => { lastSaved = ""; simpleMessage(""); updateSupplier(); };
    get("batch").onchange = () => { lastSaved = ""; simpleMessage(""); updateReceipt(); };
    get("reason").onchange = updateReason;
    q("[data-sr-add-imei]").onclick = () => { if (addImei()) get("imei").focus(); };
    get('quantity').addEventListener('input',()=>{lastAutoQuantity=null;});
    q('[data-sr-bulk-toggle]').onclick=()=>{if(!canPrepare())return;const panel=q('[data-sr-bulk-panel]');panel.hidden=!panel.hidden;q('[data-sr-bulk-toggle]').setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden)get('bulk_imeis').focus();};
    q('[data-sr-add-bulk]').onclick=()=>{addBulk(get('bulk_imeis').value);};
    q('[data-sr-recheck]').onclick=()=>{if(canPrepare())queueStockCheck(scanned);};
    q('[data-sr-clear-bulk]').onclick=()=>{if(canPrepare())get('bulk_imeis').value='';};
    get('imei').addEventListener('paste',event=>{const text=event.clipboardData?.getData('text/plain')||event.clipboardData?.getData('text')||'';if(!text)return;event.preventDefault();if(!canPrepare())return;if(/[\r\n\t ,;]/.test(text.trim())){addBulk(text);get('imei').value='';}else{get('imei').value=text.trim();addImei();}});

    get("imei").oninput = () => { get("imei").value = get("imei").value.replace(/\D/g,""); if (get("imei").value.length === 15) addImei(); };
    get("imei").onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); if (get("imei").value) addImei(); } };
    form.onsubmit = async e => {
      e.preventDefault();
      if (modalBusy || !window.GREENLOOP_PAGE_ACCESS?.canEdit || !simpleContext?.permissions?.can_return) return;
      if(typeof window.GREENLOOP_CAN==='function'&&!window.GREENLOOP_CAN('entry','supplier_returns'))return;
      if(get('bulk_imeis').value.trim()){simpleMessage('Click Add IMEIs to add the pasted list before saving.',true);return;}
      if(pasteIssues.some(issue=>issue.blocking)){simpleMessage('Remove or correct the invalid IMEI lines before saving.',true);return;}
      if (get("imei").value.trim() && !addImei()) return;
      if(scanned.some(v=>!stockChecks.has(v)||stockChecks.get(v).status==='checking')){simpleMessage('Wait for the IMEI stock checks to finish before saving.',true);return;}
      if(scanned.some(v=>stockChecks.get(v)?.allowed!==true||imeiErrors.has(v))){simpleMessage('Remove the red IMEI lines or check stock again before saving.',true);return;}
      const receipt = batch(), quantity = Number(get("quantity").value), storage = get("storage_gb").value.trim();
      if (!receipt || !Number.isInteger(quantity) || quantity < 1 || quantity > Number(get("quantity").max)) { simpleMessage("Select the received stock and enter a valid return quantity.",true); return; }
      if (scanned.length > quantity) { simpleMessage("Return quantity must be at least the number of added IMEIs.",true); return; }
      const reason = (get("reason").value === "Other" ? get("other_reason").value : get("reason").value).trim() || "Not specified";
      if (storage && (!Number.isInteger(Number(storage)) || Number(storage)<1)) { simpleMessage("Enter a valid GB value, or leave GB blank.",true); return; }
      const payload = {batch_id:receipt.batch_id,quantity,reason,imeis:[...scanned]};
      if (get("model").value.trim()) payload.model = get("model").value.trim();
      if (storage) payload.storage_gb = Number(storage);
      const signature = JSON.stringify(["record_simple_stock_return",payload]);
      if (!retries.has(signature)) retries.set(signature,crypto.randomUUID());
      const controls = [...form.querySelectorAll("button,input,select,textarea")].map(el => [el,el.disabled]);
      modalBusy = true; simpleGeneration += 1; controls.forEach(([el]) => { el.disabled = true; }); reportRoot.querySelector("[data-sr-refresh]").disabled = true;
      simpleMessage("Saving stock return…");
      try {
        const result = await rpc("record_simple_stock_return",{p_payload:payload,p_idempotency_key:retries.get(signature)});
        retries.delete(signature);
        lastSaved = "Stock return saved: " + (result.return_reference || "") + " · " + quantity + " phone(s).";
        const selectedSupplier = get("supplier").value, selectedReceipt = get("batch").value;
        checkEpoch++;clearTimeout(checkTimer);checkRunning=false;stockChecks.clear();scanned = []; pasteIssues=[];imeiErrors.clear();lastAutoQuantity="";get("bulk_imeis").value=""; showScanned(); scanNotice(""); get("quantity").value = ""; get("imei").value = ""; get("model").value = ""; get("storage_gb").value = ""; get("reason").value = ""; get("other_reason").value = ""; updateReason();
        // A completed return must never leave a filled form available to repeat.
        simpleContext = null;
        await refreshReport();
        const nextForm = host.querySelector("form");
        if (nextForm === form) { get("supplier").value = selectedSupplier; updateSupplier(selectedReceipt); }
        document.dispatchEvent(new CustomEvent("greenloop:supplier-return-changed",{detail:result}));
      } catch(e) {
        simpleMessage(e.message + " If the connection was interrupted, retry the same details to check the saved result.",true);
        const rejectedImei = String(e.message || "").match(/\bIMEI\s+(\d{15})\b/i)?.[1];
        if (["22023", "55000", "23505"].includes(e.code) && rejectedImei && payload.imeis.includes(rejectedImei)) {
          imeiErrors.set(rejectedImei,e.message);showScanned();
          const generation = simpleGeneration;
          window.GREENLOOP_IMEI_STAGE_NOTICE?.show({
            imei: rejectedImei, title: "Phone unavailable here", message: e.message, onlyIfFound: true,
            isCurrent: () => form.isConnected && simpleGeneration === generation && selectedBatch === payload.batch_id && scanned.includes(rejectedImei)
          });
        }
      }
      finally {
        modalBusy = false;
        controls.forEach(([el,disabled]) => { if (el.isConnected) el.disabled = disabled; });
        if (form.isConnected) { updateReason(); get("batch").disabled = !(simpleContext?.receipts || []).some(r => r.supplier_id === get("supplier").value); }
        if (reportRoot?.isConnected) reportRoot.querySelector("[data-sr-refresh]").disabled = false;
        if (externalRefreshPending) queueCurrentRefresh();
      }
    };
  }
  let returnSearchWidget;
  function mount(root) {
    returnSearchWidget?.destroy();
    reportRoot = root;
    root.innerHTML = '<div class="sr-simple-toolbar">' + button("Refresh", 'data-sr-refresh') + '</div><p data-sr-simple-message role="status" aria-live="polite"></p>' +
      '<section class="sr-card sr-report"><header class="sr-heading"><div><h2>Stock Return report</h2><p data-sr-total></p></div><a class="secondary-button sr-report-link" href="reports.html?report=stock_returns">Open in Reports</a></header><label class="sr-report-search">Find return<input data-sr-report-search type="search" placeholder="Supplier, receipt, model or IMEI"></label><div class="sr-table-wrap" data-sr-simple-table></div></section>' +
      '<section class="sr-card sr-report" data-sr-create><header><h2>Return stock</h2><p>Select the supplier and received stock, enter quantity and reason, then save.</p></header><div data-sr-simple-form></div></section>' +
      '<details class="sr-card sr-report sr-legacy" data-sr-legacy hidden></details>';
    root.querySelector("[data-sr-refresh]").onclick = () => { if (!modalBusy) refreshReport(); };
    root.querySelector("[data-sr-report-search]").oninput = renderSimpleReport;
    const input=root.querySelector("[data-sr-report-search]");
    returnSearchWidget=window.GREENLOOP_RECORD_SEARCH.attach(input,{
      lookup:term=>window.GREENLOOP_RECORD_SEARCH.localLookup(returnSearchItems(),term),
      onSelect:item=>{input.value=item.identifier;renderSimpleReport();root.querySelectorAll('[data-sr-simple-table] details').forEach(detail=>{detail.open=true;});}
    });
    refreshReport();
  }
  function unmount() { returnSearchWidget?.destroy();returnSearchWidget=null; reportRoot = null; simpleContext = null; simpleRows = []; ++simpleGeneration; window.clearTimeout(externalRefreshTimer); externalRefreshPending = false; closeStaleDetails = false; }
  window.GREENLOOP_SUPPLIER_RETURNS = {mount,unmount};
  const root = document.querySelector("#stock-return-app");
  if (root) {
    window.addEventListener("storage", event => {
      if (event.key === "greenloop-operational-data-change" && event.newValue) queueCurrentRefresh(true);
    });
    window.addEventListener("focus", () => { if (reportRoot) queueCurrentRefresh(); });
    document.addEventListener("visibilitychange", () => { if (reportRoot && document.visibilityState === "visible") queueCurrentRefresh(); });
    const sidebar = document.querySelector("#sidebar"), backdrop = document.querySelector("#menu-backdrop");
    const setMenu = open => { sidebar?.classList.toggle("is-open", open); if (backdrop) backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); };
    document.querySelector("#open-menu")?.addEventListener("click", () => setMenu(true));
    document.querySelector("#close-menu")?.addEventListener("click", () => setMenu(false));
    backdrop?.addEventListener("click", () => setMenu(false));
    document.addEventListener("keydown",event => { if (event.key === "Escape" && !dialog?.open) setMenu(false); });
    Promise.resolve(window.GREENLOOP_ACCESS_READY).then(() => {
      if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "supplier_returns") return;
      if (!document.querySelector("#return-replacement-home")) { root.hidden = false; mount(root); }
    });
  }
})();
