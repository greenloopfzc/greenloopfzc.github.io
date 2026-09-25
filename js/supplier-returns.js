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
  let context, dialog, modalGeneration = 0, modalBusy = false, reportRoot, reportGeneration = 0, selected = new Set(), reportRows = [];
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
  async function mutate(name, args, control, done) {
    if (modalBusy) return;
    const signature = JSON.stringify([name, args]);
    if (!retries.has(signature)) retries.set(signature, crypto.randomUUID());
    modalBusy = true;
    const scope = dialog?.open ? dialog : reportRoot;
    const controls = [...scope.querySelectorAll("button,input,select,textarea")].map(el => [el, el.disabled]);
    controls.forEach(([el]) => { el.disabled = true; });
    notify("Saving…");
    try {
      const result = await rpc(name, { ...args, p_idempotency_key: retries.get(signature) });
      retries.delete(signature); context = null;
      document.dispatchEvent(new CustomEvent("greenloop:supplier-return-changed", { detail: result }));
      modalBusy = false;
      await done(result);
    } catch (e) { notify(`${e.message} If the connection was interrupted, retry the same action to check its saved result.`, true); }
    finally { modalBusy = false; controls.forEach(([el, disabled]) => { if (el.isConnected) el.disabled = disabled; }); }
  }
  async function open(options = {}) {
    const shell = modal("Request supplier return", '<p>Loading return permissions and received batches…</p>');
    if (!shell) return;
    const generation = modalGeneration;
    try {
      await getContext();
      if (generation !== modalGeneration || !dialog.open) return;
      if (!allowed("request")) { notify("You need Entry Allowed on this page and Supplier Returns permission to request a return.", true); return; }
      renderRequest(options);
    } catch (e) { if (generation === modalGeneration) notify(e.message, true); }
  }
  function renderRequest(options) {
    let found = null, lookupGeneration = 0;
    modal("Request supplier return", `<p>Request a return for a saved IMEI, or for unentered units from a received batch. The original receipt and work history remain saved.</p>
      <form data-sr-request class="sr-form">
        <label>Phone identification<select name="mode"><option value="imei">With IMEI</option><option value="batch">Without IMEI / not entered yet</option></select></label>
        <div data-sr-imei><label>IMEI<input name="imei" inputmode="numeric" maxlength="15" autocomplete="off" value="${escape(options.imei || "")}"></label>${button("Find phone", "data-sr-lookup")}<div data-sr-phone></div></div>
        <div data-sr-batch hidden><label>Received batch<select name="batch"><option value="">Select received batch</option>${(context.batches || []).map(b => `<option value="${escape(b.batch_id)}">${escape(b.batch_number)} · ${escape(supplier(b))} · ${escape(b.remaining_quantity)} unentered available</option>`).join("")}</select></label><div data-sr-counts></div><label>Planned model / memory / color<select name="plan"><option value="">No planned line</option></select></label><label>Quantity<input name="quantity" type="number" min="1" step="1" value="1"></label><label>Serial numbers (optional, one per unit)<textarea name="serials" rows="2" placeholder="One per line, in unit order"></textarea></label><p class="sr-hint">Each unit gets its own Return ID. Label the physical phone with that ID. Already entered phones must use With IMEI.</p></div>
        <label>Reason<select name="reason"><option value="dead">Dead phone</option><option value="icloud_locked">iCloud locked</option><option value="other">Other</option></select></label>
        <label>Notes<textarea name="notes" rows="3" maxlength="2000" placeholder="Explain the issue"></textarea></label>
        <label class="sr-check"><input name="confirm" type="checkbox" required> These are the phones to return. Their further processing will be put on hold.</label>
        <button class="primary-button" type="submit">Request supplier return</button>
      </form>`);
    const form = dialog.querySelector("form"), get = name => form.elements.namedItem(name);
    function updateMode() {
      dialog.querySelector("[data-sr-imei]").hidden = get("mode").value !== "imei";
      dialog.querySelector("[data-sr-batch]").hidden = get("mode").value !== "batch";
      get("confirm").checked = false;
    }
    function updateBatch() {
      const b = context.batches.find(b => b.batch_id === get("batch").value);
      get("plan").innerHTML = '<option value="">Select planned line</option>' + (b?.plan_lines || []).map(p => `<option value="${escape(p.plan_line_id)}">${escape([p.model,p.storage_gb ? p.storage_gb + " GB" : "",p.color].filter(Boolean).join(" · "))} · ${escape(p.remaining_quantity)} available</option>`).join("");
      get("plan").disabled = !(b?.plan_lines || []).length;
      get("quantity").max = String(b?.remaining_quantity || 0);
      dialog.querySelector("[data-sr-counts]").innerHTML = b ? fields([["Originally received",b.received_quantity],["IMEIs entered",b.entered_quantity],["Unentered on return hold",b.unentered_reserved],["Returned to supplier",b.returned_quantity ?? b.returned_without_imei],["Retained after returns",b.required_quantity],["Unentered available",b.remaining_quantity]]) : "";
      get("confirm").checked = false;
    }
    async function lookup() {
      const value = get("imei").value.trim(), version = ++lookupGeneration, generation = modalGeneration;
      found = null; dialog.querySelector("[data-sr-phone]").innerHTML = "";
      if (!/^\d{15}$/.test(value)) { notify("Enter a 15-digit IMEI.", true); return; }
      notify("Finding phone…");
      try {
        const result = await rpc("lookup_supplier_return_device", { p_imei: value });
        if (version !== lookupGeneration || generation !== modalGeneration || get("imei").value.trim() !== value) return;
        found = { ...result, lookup_imei: value };
        dialog.querySelector("[data-sr-phone]").innerHTML = fields([["IMEI",result.imei_1],["Model",result.model],["Serial",result.serial_number],["Supplier",supplier(result)],["Current status",label(result.current_status)],["Unused issued parts",result.unreconciled_parts_quantity || 0]]);
        notify(result.eligible ? "Phone found. Review the details before requesting a return." : "This phone cannot be returned now. Check its existing return or current workflow status.", !result.eligible);
      } catch(e) { if (generation === modalGeneration && version === lookupGeneration) notify(e.message, true); }
    }
    get("mode").value = options.mode === "batch" || options.batchId ? "batch" : "imei";
    get("batch").value = options.batchId || ""; updateBatch(); updateMode();
    get("mode").onchange = updateMode; get("batch").onchange = updateBatch;
    get("imei").oninput = () => { found = null; ++lookupGeneration; get("confirm").checked = false; dialog.querySelector("[data-sr-phone]").innerHTML = ""; };
    dialog.querySelector("[data-sr-lookup]").onclick = lookup;
    form.onsubmit = e => {
      e.preventDefault(); if (modalBusy || !allowed("request")) return;
      const payload = { reason: get("reason").value, notes: get("notes").value.trim() };
      if (payload.reason === "other" && !payload.notes) { notify("Describe the reason for this return.", true); return; }
      if (!get("confirm").checked) { notify("Confirm the selected phones first.", true); return; }
      if (get("mode").value === "imei") {
        if (!found?.eligible || found.lookup_imei !== get("imei").value.trim()) { notify("Find an eligible phone first.", true); return; }
        payload.job_id = found.job_id;
      } else {
        const b = context.batches.find(b => b.batch_id === get("batch").value), p = b?.plan_lines?.find(p => p.plan_line_id === get("plan").value);
        const quantity = Number(get("quantity").value), serials = get("serials").value.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
        if (!b || !Number.isInteger(quantity) || quantity < 1 || quantity > Number(p?.remaining_quantity ?? b.remaining_quantity) || ((b.plan_lines || []).length && !p)) { notify("Select a batch / planned line and a quantity within the available unentered units.", true); return; }
        if (serials.length > quantity || new Set(serials).size !== serials.length) { notify("Enter no more than one unique serial number per unit.", true); return; }
        Object.assign(payload, { batch_id: b.batch_id, quantity, serial_numbers: serials });
        if (p) payload.plan_line_id = p.plan_line_id;
      }
      mutate("create_supplier_return", { p_payload: payload }, e.submitter, async result => {
        const rows = result.returns || [];
        modal("Return requested", `<p>The selected units are now on return hold. Record these Return IDs on the phones.</p>${fields(rows.map(r => [r.return_number, imei(r) + (r.serial_number ? " · " + r.serial_number : "")]))}<p>Use Reports → Supplier Returns for approval, unused parts, handover and settlement. Refresh this page before doing more work on these units.</p><a class="primary-button" href="reports.html?report=supplier_returns">Open Supplier Returns</a>`);
        if (reportRoot?.isConnected) await refreshReport();
      });
    };
    if (options.imei) lookup();
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
  async function refreshReport() {
    const root = reportRoot; if (!root?.isConnected) return;
    const generation = ++reportGeneration;
    const status = root.querySelector('[name="status"]').value, search = root.querySelector('[name="search"]').value.trim();
    root.querySelector("[data-sr-message]").textContent = "Loading supplier returns…";
    root.querySelector("[data-sr-print]").disabled = true;
    try {
      const [rows] = await Promise.all([rpc("list_supplier_returns", { p_status: status || null, p_search: search || null }), getContext()]);
      if (generation !== reportGeneration || root !== reportRoot) return;
      if (!Array.isArray(rows)) throw new Error("Supplier return records could not be read.");
      reportRows = rows; selected = new Set();
      root.querySelector("[data-sr-create]").hidden = !allowed("request");
      const batches = (context.batches || []).filter(b => Number(b.unentered_reserved) || Number(b.held_imei_quantity) || Number(b.returned_quantity));
      root.querySelector("[data-sr-balances]").innerHTML = batches.length ? `<details><summary>Receipt quantities · ${batches.length} batches with returns</summary><div class="sr-table-wrap"><table class="sr-table"><thead><tr><th>Supplier / batch</th><th>Originally received</th><th>Returned</th><th>Retained after returns</th><th>IMEIs entered</th><th>Unentered on hold</th><th>IMEIs still to enter</th></tr></thead><tbody>${batches.map(b => `<tr><td>${escape(supplier(b))}<small>${escape(b.batch_number)}</small></td><td>${escape(b.received_quantity)}</td><td>${escape(b.returned_quantity)}</td><td>${escape(b.required_quantity)}</td><td>${escape(b.entered_quantity)}</td><td>${escape(b.unentered_reserved)}</td><td>${escape(b.remaining_quantity)}</td></tr>`).join("")}</tbody></table></div></details>` : "";
      root.querySelector("[data-sr-table]").innerHTML = rows.length ? `<table class="sr-table"><thead><tr><th>Select</th><th>Return / phone</th><th>Supplier / batch</th><th>Reason</th><th>Status</th><th>Requested</th><th>Settlement</th><th>Details</th></tr></thead><tbody>${rows.map(r => `<tr><td><input type="checkbox" data-sr-select="${escape(rid(r))}" aria-label="Select ${escape(r.return_number)}" ${!r.archived_at && ["approved","returned"].includes(r.status) ? "" : "disabled"}></td><td><strong>${escape(r.return_number)}</strong><small>${escape(imei(r))}</small><small>${escape(r.serial_number || "")}</small></td><td>${escape(supplier(r))}<small>${escape(r.batch_number || "")}</small></td><td>${escape(label(r.reason))}</td><td><span class="sr-status sr-${escape(r.status)}">${escape(statusLabel(r))}</span></td><td>${escape(date(r.created_at || r.requested_at))}<small>${escape(r.requested_by_name || "")}</small></td><td>${escape(r.settlement_type ? label(r.settlement_type) : "Open")}</td><td>${button("View", `data-sr-detail="${escape(rid(r))}"`)}</td></tr>`).join("")}</tbody></table>` : '<p class="sr-empty">No supplier returns match these filters.</p>';
      root.querySelector("[data-sr-message]").textContent = `${rows.length} return records. Select Return Pending or Returned phones from one supplier to print a slip.`;
      const count = document.querySelector("#report-row-count"); if (count) count.textContent = `${rows.length} returns`;
      root.querySelectorAll("[data-sr-detail]").forEach(el => { el.onclick = () => detail(el.dataset.srDetail); });
      root.querySelectorAll("[data-sr-select]").forEach(el => { el.onchange = () => { if (el.checked) selected.add(el.dataset.srSelect); else selected.delete(el.dataset.srSelect); root.querySelector("[data-sr-print]").disabled = !selected.size; }; });
    } catch(e) { if (generation === reportGeneration && root === reportRoot) { reportRows = []; selected.clear(); root.querySelector("[data-sr-table]").innerHTML = ""; root.querySelector("[data-sr-balances]").innerHTML = ""; root.querySelector("[data-sr-create]").hidden = true; root.querySelector("[data-sr-message]").textContent = e.message; } }
  }
  function printSlip() {
    const rows = reportRows.filter(r => selected.has(rid(r)));
    if (!rows.length) return;
    if (new Set(rows.map(r => r.supplier_id || r.supplier_code)).size !== 1) { notify("Select phones from one supplier per return slip.", true); return; }
    const popup = window.open("", "_blank"); if (!popup) { notify("Allow the print window, then try again.", true); return; }
    popup.opener = null;
    popup.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Greenloop supplier return slip</title><style>body{font:14px Arial;padding:24px;color:#182a31}table{width:100%;border-collapse:collapse}td,th{border:1px solid #aab5bb;padding:9px;text-align:left}small{display:block}footer{margin-top:45px}@media print{button{display:none}}</style></head><body><h1>Greenloop · Supplier return slip</h1><p>Supplier: ${escape(supplier(rows[0]))} · Units: ${rows.length} · Printed: ${escape(new Date().toLocaleString())}</p><p>Slip reference: __________________ &nbsp; Handover date: __________________</p><table><thead><tr><th>Return ID</th><th>IMEI / serial</th><th>Model / batch</th><th>Reason</th><th>Status / reference</th></tr></thead><tbody>${rows.map(r => `<tr><td>${escape(r.return_number)}</td><td>${escape(imei(r))}<small>${escape(r.serial_number || "")}</small></td><td>${escape(r.model || "—")}<small>${escape(r.batch_number || "")}</small></td><td>${escape(label(r.reason))}<small>${escape(r.notes || "")}</small></td><td>${escape(label(r.status))}<small>${escape(r.slip_reference || "")}</small></td></tr>`).join("")}</tbody></table><footer><p>Handed over by: __________________ &nbsp; Supplier received by: __________________</p><p>Printing does not record handover. Record physical handover in Greenloop using this slip reference.</p></footer><button id="print">Print</button></body></html>`);
    popup.document.close(); popup.document.getElementById("print").onclick = () => popup.print(); popup.focus(); popup.print();
  }
  function mount(root) {
    reportRoot = root; ++reportGeneration;
    root.innerHTML = `<section class="sr-report"><div class="sr-actions">${button("Request supplier return", "data-sr-create hidden")}${button("Print selected return slip", "data-sr-print disabled")}</div><form class="sr-filters"><label>Status<select name="status"><option value="">All statuses</option>${Object.keys(labels).slice(0,5).map(s => `<option value="${s}">${labels[s]}</option>`).join("")}</select></label><label>Find return / IMEI / serial / supplier code<input name="search" type="search" maxlength="100"></label><button class="secondary-button" type="submit">Search / refresh</button></form><p data-sr-message role="status" aria-live="polite"></p><div data-sr-balances></div><div class="sr-table-wrap" data-sr-table></div></section>`;
    root.querySelector("form").onsubmit = e => { e.preventDefault(); refreshReport(); };
    root.querySelector("[data-sr-create]").onclick = () => open(); root.querySelector("[data-sr-print]").onclick = printSlip;
    refreshReport();
  }
  function unmount() { reportRoot = null; reportRows = []; selected.clear(); ++reportGeneration; }
  document.addEventListener("click", e => {
    const el = e.target.closest("[data-supplier-return-open],[data-supplier-return-imei],[data-supplier-return-row],[data-supplier-return-batch]");
    if (!el || el.disabled) return;
    e.preventDefault();
    let phone = el.dataset.supplierReturnImei || "";
    if (el.hasAttribute("data-supplier-return-row")) phone = el.closest("tr")?.querySelector(".qc-bulk-imei,.final-row-imei")?.value.trim() || "";
    open({ imei: phone, mode: el.dataset.supplierReturnOpen, batchId: el.hasAttribute("data-supplier-return-batch") ? document.querySelector("#stock-batch")?.value : "" });
  });
  window.GREENLOOP_SUPPLIER_RETURNS = { open, mount, unmount };
})();
