(() => {
  "use strict";
  const escape = (v) => String(v ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const labels = { requested: "Requested", approved: "Return Pending", returned: "Returned to Supplier", rejected: "Rejected", cancelled: "Cancelled", dead: "Dead phone", icloud_locked: "iCloud locked", other: "Other" };
  const label = v => labels[v] || String(v || "—").replaceAll("_", " ");
  const statusLabel = r => r.archived_at ? `Archived audit · ${label(r.status)}` : label(r.status);
  const date = v => v ? new Date(v).toLocaleString() : "—";
  const supplier = r => [r.supplier_code, window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? r.supplier_name : ""].filter(Boolean).join(" · ") || "—";
  const rid = r => r.id || r.return_id;
  const imei = r => r.imei_1 || r.imei || "Without IMEI";
  const button = (text, attrs = "") => `<button type="button" class="secondary-button sr-button" ${attrs}>${escape(text)}</button>`;
  let context, dialog, modalGeneration = 0, modalBusy = false, reportRoot, reportGeneration = 0;
  const retries = new Map();
  async function rpc(name, args = {}) {
    await window.GREENLOOP_ACCESS_READY;
    const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc(name, args);
    if (error) throw new Error(error.code === "PGRST202" ? "Install the Supplier Returns database update first." : error.message || "The request could not be completed.");
    return data;
  }
  async function getContext() { return context = await rpc("get_supplier_return_context"); }
  function allowed(key) { return Boolean(window.GREENLOOP_PAGE_ACCESS?.canEdit && context?.permissions?.[key]); }
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
    finally { modalBusy = false; controls.forEach(([el, disabled]) => { if (el.isConnected) el.disabled = disabled; }); }
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
      if (r.status === "returned" && !r.settled_at && !r.settlement_type && allowed("handover")) actions.push(["settlement","Record settlement"]);
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
    modal(titles[action], `<p><strong>${escape(r.return_number)}</strong> · ${escape(imei(r))} · ${escape(supplier(r))}</p><form class="sr-form" data-sr-action-form>
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
  const showDate = value => value ? new Date(value).toLocaleDateString([], {day:"2-digit",month:"short",year:"numeric"}) : "—";
  const receiptLabel = r => [r.invoice_number || r.batch_number, showDate(r.received_at), r.received_quantity + " received"].filter(Boolean).join(" · ");
  function simpleMessage(message, error = false) {
    const el = reportRoot?.querySelector("[data-sr-simple-message]");
    if (el) { el.textContent = message; el.classList.toggle("sr-error", error); }
  }
  async function refreshReport() {
    const root = reportRoot; if (!root?.isConnected) return;
    const generation = ++simpleGeneration;
    root.querySelector("[data-sr-refresh]").disabled = true;
    try {
      const [next, rows] = await Promise.all([rpc("get_simple_stock_return_context"), rpc("list_simple_stock_returns", {p_from:null,p_to:null})]);
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
        root.querySelector("[data-sr-total]").textContent = "";
        simpleMessage((lastSaved ? lastSaved + " " : "") + e.message, true);
      }
    } finally { if (root === reportRoot && generation === simpleGeneration) root.querySelector("[data-sr-refresh]").disabled = false; }
  }
  function renderSimpleReport() {
    const root = reportRoot, value = root.querySelector("[data-sr-report-search]").value.trim().toLowerCase();
    const rows = simpleRows.filter(r => [r.return_reference,r.supplier_code,window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? r.supplier_name : "",r.invoice_number,r.batch_number,r.reason,r.model,...(r.imeis || [])].filter(Boolean).join(" ").toLowerCase().includes(value));
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
    let scanned = [], selectedBatch = "";
    host.innerHTML = '<form class="sr-form sr-simple-form">' +
      '<div class="sr-request-start"><label>Supplier / supplier code<select name="supplier" required><option value="">Select supplier</option></select></label><label>Received stock<select name="batch" required disabled><option value="">Select received stock</option></select></label></div>' +
      '<dl class="sr-receipt-summary" data-sr-receipt hidden></dl>' +
      '<fieldset data-sr-inputs disabled><div class="sr-request-start"><label>Return quantity<input name="quantity" type="number" min="1" max="1000" step="1" required placeholder="Enter return quantity"></label><label>Reason<select name="reason" required><option value="">Select reason</option><option>Dead phone</option><option>iCloud locked</option><option>Other</option></select></label></div>' +
      '<label data-sr-other hidden>Return reason<input name="other_reason" maxlength="500" disabled placeholder="Describe the issue"></label>' +
      '<div class="sr-optional-fields"><label>Model <span class="sr-optional">Optional</span><input name="model" list="sr-model-options" maxlength="100" placeholder="e.g. 15 Pro"><datalist id="sr-model-options"></datalist></label><label>GB <span class="sr-optional">Optional</span><input name="storage_gb" type="number" min="1" max="16384" step="1" placeholder="e.g. 128"></label><label>Scan IMEI <span class="sr-optional">Optional</span><span class="sr-scan-line"><input name="imei" inputmode="numeric" maxlength="15" autocomplete="off" placeholder="Scan or enter IMEI">' + button("Add", 'data-sr-add-imei') + '</span></label></div>' +
      '<div class="sr-scanned" data-sr-scanned hidden></div><p class="sr-hint" data-sr-scan-message role="status" hidden></p>' +
      '<button type="submit" class="primary-button">Stock Return</button></fieldset></form>';
    const form = host.querySelector("form"), get = name => form.elements.namedItem(name), q = selector => host.querySelector(selector);
    const batch = () => simpleContext?.receipts.find(r => r.batch_id === get("batch").value && r.supplier_id === get("supplier").value);
    function showScanned() {
      q("[data-sr-scanned]").hidden = !scanned.length;
      q("[data-sr-scanned]").innerHTML = scanned.map((v,i) => '<span class="sr-imei-chip">' + escape(v) + button("×", 'data-sr-remove-imei="' + i + '" aria-label="Remove IMEI ' + escape(v) + '"') + '</span>').join("");
      host.querySelectorAll("[data-sr-remove-imei]").forEach(el => { el.onclick = () => { scanned.splice(Number(el.dataset.srRemoveImei),1); showScanned(); }; });
    }
    function scanNotice(message, error = false) {
      const el = q("[data-sr-scan-message]"); el.textContent = message; el.hidden = !message; el.classList.toggle("sr-error",error);
    }
    function addImei() {
      const value = get("imei").value.trim();
      if (!/^\d{15}$/.test(value)) { scanNotice("Enter a complete 15-digit IMEI.",true); return false; }
      if (scanned.includes(value)) { get("imei").value = ""; scanNotice("This IMEI has already been added.",true); return false; }
      if (scanned.length >= 1000) { scanNotice("A return can contain up to 1000 phones.",true); return false; }
      scanned.push(value); get("imei").value = ""; showScanned(); scanNotice(scanned.length + " IMEI(s) added.");
      return true;
    }
    function updateReceipt() {
      const receipt = batch(), changed = selectedBatch !== (receipt?.batch_id || "");
      selectedBatch = receipt?.batch_id || "";
      q("[data-sr-inputs]").disabled = !receipt;
      q("[data-sr-receipt]").hidden = !receipt;
      if (changed) { scanned = []; showScanned(); scanNotice(""); get("imei").value = ""; get("quantity").value = ""; get("model").value = ""; get("storage_gb").value = ""; get("reason").value = ""; get("other_reason").value = ""; updateReason(); }
      if (!receipt) return;
      q("[data-sr-receipt]").innerHTML = [["Received",showDate(receipt.received_at)],["Supplier code",receipt.supplier_code],["Quantity received",receipt.received_quantity],["Return Stock",receipt.returned_quantity]].map(([k,v]) => '<div><dt>' + escape(k) + '</dt><dd>' + escape(v) + '</dd></div>').join("");
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
      get("supplier").innerHTML = '<option value="">Select supplier</option>' + suppliers.map(r => '<option value="' + escape(r.supplier_id) + '">' + escape(supplier(r)) + '</option>').join("");
      get("supplier").value = suppliers.some(r => r.supplier_id === chosen) ? chosen : "";
      updateSupplier(receiptId);
    }
    function updateReason() {
      const other = get("reason").value === "Other";
      q("[data-sr-other]").hidden = !other; get("other_reason").disabled = !other; get("other_reason").required = other;
    }
    updateSuppliers();
    form.addEventListener("receipt-refresh",updateSuppliers);
    get("supplier").onchange = () => { lastSaved = ""; simpleMessage(""); updateSupplier(); };
    get("batch").onchange = () => { lastSaved = ""; simpleMessage(""); updateReceipt(); };
    get("reason").onchange = updateReason;
    q("[data-sr-add-imei]").onclick = () => { if (addImei()) get("imei").focus(); };
    get("imei").oninput = () => { get("imei").value = get("imei").value.replace(/\D/g,""); if (get("imei").value.length === 15) addImei(); };
    get("imei").onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); if (get("imei").value) addImei(); } };
    form.onsubmit = async e => {
      e.preventDefault();
      if (modalBusy || !window.GREENLOOP_PAGE_ACCESS?.canEdit || !simpleContext?.permissions?.can_return) return;
      if (get("imei").value.trim() && !addImei()) return;
      const receipt = batch(), quantity = Number(get("quantity").value), storage = get("storage_gb").value.trim();
      if (!receipt || !Number.isInteger(quantity) || quantity < 1 || quantity > Number(get("quantity").max)) { simpleMessage("Select the received stock and enter a valid return quantity.",true); return; }
      if (scanned.length > quantity) { simpleMessage("Return quantity must be at least the number of added IMEIs.",true); return; }
      const reason = (get("reason").value === "Other" ? get("other_reason").value : get("reason").value).trim();
      if (!reason || storage && (!Number.isInteger(Number(storage)) || Number(storage)<1)) { simpleMessage("Enter the return reason and a valid GB value, or leave GB blank.",true); return; }
      const payload = {batch_id:receipt.batch_id,quantity,reason,imeis:[...scanned]};
      if (get("model").value.trim()) payload.model = get("model").value.trim();
      if (storage) payload.storage_gb = Number(storage);
      const signature = JSON.stringify(["record_simple_stock_return",payload]);
      if (!retries.has(signature)) retries.set(signature,crypto.randomUUID());
      const controls = [...form.querySelectorAll("button,input,select")].map(el => [el,el.disabled]);
      modalBusy = true; controls.forEach(([el]) => { el.disabled = true; }); reportRoot.querySelector("[data-sr-refresh]").disabled = true;
      simpleMessage("Saving stock return…");
      try {
        const result = await rpc("record_simple_stock_return",{p_payload:payload,p_idempotency_key:retries.get(signature)});
        retries.delete(signature);
        lastSaved = "Stock return saved: " + (result.return_reference || "") + " · " + quantity + " phone(s).";
        const selectedSupplier = get("supplier").value, selectedReceipt = get("batch").value;
        scanned = []; showScanned(); scanNotice(""); get("quantity").value = ""; get("imei").value = ""; get("model").value = ""; get("storage_gb").value = ""; get("reason").value = ""; get("other_reason").value = ""; updateReason();
        // A completed return must never leave a filled form available to repeat.
        simpleContext = null;
        await refreshReport();
        const nextForm = host.querySelector("form");
        if (nextForm === form) { get("supplier").value = selectedSupplier; updateSupplier(selectedReceipt); }
        document.dispatchEvent(new CustomEvent("greenloop:supplier-return-changed",{detail:result}));
      } catch(e) { simpleMessage(e.message + " If the connection was interrupted, retry the same details to check the saved result.",true); }
      finally {
        modalBusy = false;
        controls.forEach(([el,disabled]) => { if (el.isConnected) el.disabled = disabled; });
        if (form.isConnected) { updateReason(); get("batch").disabled = !(simpleContext?.receipts || []).some(r => r.supplier_id === get("supplier").value); }
        if (reportRoot?.isConnected) reportRoot.querySelector("[data-sr-refresh]").disabled = false;
      }
    };
  }
  function mount(root) {
    reportRoot = root;
    root.innerHTML = '<div class="sr-simple-toolbar">' + button("Refresh", 'data-sr-refresh') + '</div><p data-sr-simple-message role="status" aria-live="polite"></p>' +
      '<section class="sr-card sr-report" data-sr-create><header><h2>Return stock</h2><p>Select the supplier and received stock, enter quantity and reason, then save.</p></header><div data-sr-simple-form></div></section>' +
      '<section class="sr-card sr-report"><header class="sr-heading"><div><h2>Stock Return report</h2><p data-sr-total></p></div><a class="secondary-button sr-report-link" href="reports.html?report=stock_returns">Open in Reports</a></header><label class="sr-report-search">Find return<input data-sr-report-search type="search" placeholder="Supplier, receipt, model or IMEI"></label><div class="sr-table-wrap" data-sr-simple-table></div></section>' +
      '<details class="sr-card sr-report sr-legacy" data-sr-legacy hidden></details>';
    root.querySelector("[data-sr-refresh]").onclick = () => { if (!modalBusy) refreshReport(); };
    root.querySelector("[data-sr-report-search]").oninput = renderSimpleReport;
    refreshReport();
  }
  function unmount() { reportRoot = null; simpleContext = null; simpleRows = []; ++simpleGeneration; }
  window.GREENLOOP_SUPPLIER_RETURNS = {mount,unmount};
  const root = document.querySelector("#stock-return-app");
  if (root) {
    const sidebar = document.querySelector("#sidebar"), backdrop = document.querySelector("#menu-backdrop");
    const setMenu = open => { sidebar?.classList.toggle("is-open", open); if (backdrop) backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); };
    document.querySelector("#open-menu")?.addEventListener("click", () => setMenu(true));
    document.querySelector("#close-menu")?.addEventListener("click", () => setMenu(false));
    backdrop?.addEventListener("click", () => setMenu(false));
    document.addEventListener("keydown",event => { if (event.key === "Escape" && !dialog?.open) setMenu(false); });
    Promise.resolve(window.GREENLOOP_ACCESS_READY).then(() => {
      if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "supplier_returns") return;
      root.hidden = false; mount(root);
    });
  }
})();
