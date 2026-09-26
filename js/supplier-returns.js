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
  async function loadRequest(preferredSupplier = "", success = "") {
    const host = reportRoot?.querySelector("[data-sr-request-host]");
    if (!host) return;
    host.innerHTML = '<p>Loading suppliers and received stock…</p>';
    try {
      const [, suppliers] = await Promise.all([getContext(), rpc("get_supplier_return_suppliers")]);
      if (!host.isConnected) return;
      reportRoot.querySelector("[data-sr-create]").hidden = !allowed("request");
      if (!allowed("request")) { host.innerHTML = ""; return; }
      if (!Array.isArray(suppliers)) throw new Error("Supplier list could not be loaded.");
      renderRequest(host, suppliers, preferredSupplier);
      if (success) requestNotice(success);
    } catch (e) {
      if (host.isConnected) {
        host.innerHTML = '<p class="sr-error" role="status">' + escape(success ? success + " Refresh before starting another return. " : "") + escape(e.message) + '</p>' + button("Retry loading suppliers", "data-sr-retry");
        host.querySelector("[data-sr-retry]").onclick = () => loadRequest(preferredSupplier, success);
      }
    }
  }
  function requestNotice(message, error = false) {
    const el = reportRoot?.querySelector("[data-sr-request-message]");
    if (el) { el.textContent = message; el.classList.toggle("sr-error", error); }
  }
  function renderRequest(host, suppliers, preferredSupplier) {
    let found = null, lookupGeneration = 0, matches = [], offset = 0, hasMore = false;
    const pageSize = 25;
    host.innerHTML = '<form data-sr-request class="sr-form">' +
      '<div class="sr-request-start"><label>1. Supplier<select name="supplier" required><option value="">Select supplier</option>' + suppliers.map(s => '<option value="' + escape(s.supplier_id) + '">' + escape(supplier(s)) + '</option>').join("") + '</select></label>' +
      '<label>2. Phone identification<select name="mode" disabled><option value="imei">Saved phone · model or IMEI</option><option value="batch">Without IMEI / not entered yet</option></select></label></div>' +
      '<p data-sr-choose class="sr-hint">Select the supplier who supplied these phones.</p>' +
      '<div data-sr-imei hidden><div class="sr-search-line"><label>Model or IMEI<input name="phone_search" type="search" maxlength="100" autocomplete="off" placeholder="For example: 15 or a 15-digit IMEI"></label>' + button("Search phones", "data-sr-lookup") + '</div>' +
      '<p class="sr-hint">Search this supplier’s saved phones, then select the exact phone below.</p><div class="sr-table-wrap" data-sr-matches></div>' +
      '<div class="sr-paging" hidden>' + button("Previous", "data-sr-prev") + button("Next", "data-sr-next") + '<span data-sr-page></span></div><div data-sr-phone></div></div>' +
      '<div data-sr-batch hidden><div class="sr-request-start"><label>Received batch<select name="batch"><option value="">Select received batch</option></select></label><label>Model / memory / color<select name="plan"><option value="">Select planned line</option></select></label></div>' +
      '<div data-sr-counts></div><div class="sr-request-start"><label>Quantity<input name="quantity" type="number" min="1" step="1" value="1"></label><label>Serial numbers (optional, one per unit)<textarea name="serials" rows="2" placeholder="One per line, in unit order"></textarea></label></div>' +
      '<p class="sr-hint">Use this option for phones not yet entered in IMEI Entry. Each phone gets its own Return ID to attach to the physical phone. Already entered phones must use Saved phone.</p></div>' +
      '<fieldset data-sr-reason disabled><legend>3. Return details</legend><div class="sr-request-start"><label>Reason<select name="reason"><option value="dead">Dead phone</option><option value="icloud_locked">iCloud locked</option><option value="other">Other</option></select></label><label>Notes<textarea name="notes" rows="2" maxlength="2000" placeholder="Explain the issue"></textarea></label></div>' +
      '<label class="sr-check"><input name="confirm" type="checkbox" required> I confirm the selected phone(s) and supplier. These phones will be put on return hold.</label><button class="primary-button" type="submit">Request stock return</button></fieldset>' +
      '<p data-sr-request-message role="status" aria-live="polite"></p></form>';
    const form = host.querySelector("form"), get = name => form.elements.namedItem(name), q = selector => host.querySelector(selector);
    const selectedBatch = () => (context.batches || []).find(b => b.supplier_id === get("supplier").value && b.batch_id === get("batch").value);
    function clearPhone() {
      ++lookupGeneration; found = null; matches = []; offset = 0; hasMore = false;
      get("confirm").checked = false; q("[data-sr-phone]").innerHTML = ""; q("[data-sr-matches]").innerHTML = "";
      q(".sr-paging").hidden = true; q("[data-sr-lookup]").disabled = false;
    }
    function updateMode() {
      clearPhone();
      const chosen = Boolean(get("supplier").value);
      q("[data-sr-choose]").hidden = chosen;
      q("[data-sr-imei]").hidden = !chosen || get("mode").value !== "imei";
      q("[data-sr-batch]").hidden = !chosen || get("mode").value !== "batch";
      q("[data-sr-batch]").querySelectorAll("input,select,textarea").forEach(el => { el.disabled = q("[data-sr-batch]").hidden; });
      get("plan").disabled = q("[data-sr-batch]").hidden || !(selectedBatch()?.plan_lines || []).length;
      get("phone_search").disabled = q("[data-sr-imei]").hidden;
      q("[data-sr-reason]").disabled = !chosen;
      requestNotice("");
    }
    function updateBatch() {
      const b = selectedBatch();
      get("plan").innerHTML = '<option value="">Select planned line</option>' + (b?.plan_lines || []).map(p => '<option value="' + escape(p.plan_line_id) + '">' + escape([p.model,p.storage_gb ? p.storage_gb + " GB" : "",p.color].filter(Boolean).join(" · ")) + ' · ' + escape(p.remaining_quantity) + ' available</option>').join("");
      get("plan").disabled = !(b?.plan_lines || []).length;
      get("quantity").value = "1"; get("quantity").max = String(b?.remaining_quantity || 0); get("serials").value = "";
      q("[data-sr-counts]").innerHTML = b ? fields([["Originally received",b.received_quantity],["IMEIs entered",b.entered_quantity],["Unentered on return hold",b.unentered_reserved],["Returned to supplier",b.returned_quantity ?? b.returned_without_imei],["Retained after returns",b.required_quantity],["Unentered available",b.remaining_quantity]]) : "";
      get("confirm").checked = false;
    }
    function updateSupplier() {
      get("mode").disabled = !get("supplier").value; get("phone_search").value = "";
      const batches = (context.batches || []).filter(b => b.supplier_id === get("supplier").value && Number(b.remaining_quantity) > 0);
      get("batch").innerHTML = '<option value="">Select received batch</option>' + batches.map(b => '<option value="' + escape(b.batch_id) + '">' + escape(b.batch_number) + ' · ' + escape(b.remaining_quantity) + ' unentered available</option>').join("");
      updateBatch(); updateMode();
      if (get("mode").value === "batch" && !batches.length) requestNotice("This supplier has no unentered units available. Search saved phones if their IMEIs were already entered.");
    }
    function showMatches() {
      q("[data-sr-matches]").innerHTML = matches.length ? '<table class="sr-table sr-matches"><thead><tr><th>Phone</th><th>Model</th><th>Batch</th><th>Current status</th><th>Select</th></tr></thead><tbody>' + matches.map((r,i) => '<tr class="' + (found?.job_id === r.job_id ? "sr-chosen" : "") + '"><td><strong>' + escape(r.imei_1 || "No IMEI") + '</strong><small>' + escape(r.serial_number || "") + '</small></td><td>' + escape(r.model || "—") + '<small>' + escape([r.storage_gb ? r.storage_gb + " GB" : "",r.color].filter(Boolean).join(" · ")) + '</small></td><td>' + escape(r.batch_number || "—") + '</td><td>' + escape(label(r.current_status)) + (!r.eligible ? '<small>Unavailable for a new return</small>' : "") + '</td><td>' + button(found?.job_id === r.job_id ? "Selected" : "Select phone", 'data-sr-pick="' + i + '" aria-pressed="' + (found?.job_id === r.job_id) + '" ' + (r.eligible ? "" : "disabled")) + '</td></tr>').join("") + '</tbody></table>' : '<p class="sr-empty">No saved phones match this supplier and search. For phones not entered yet, choose Without IMEI.</p>';
      q(".sr-paging").hidden = !offset && !hasMore;
      q("[data-sr-prev]").disabled = offset === 0; q("[data-sr-next]").disabled = !hasMore;
      q("[data-sr-page]").textContent = matches.length ? 'Showing ' + (offset+1) + '–' + (offset+matches.length) : "";
      host.querySelectorAll("[data-sr-pick]").forEach(el => { el.onclick = () => {
        const result = matches[Number(el.dataset.srPick)];
        if (!result?.eligible || result.supplier_id !== get("supplier").value) return;
        found = result; get("confirm").checked = false; showMatches();
        q("[data-sr-phone]").innerHTML = '<h3>Selected phone</h3>' + fields([["IMEI",result.imei_1],["Model",result.model],["Serial",result.serial_number],["Supplier",supplier(result)],["Current status",label(result.current_status)],["Unused issued parts",result.unreconciled_parts_quantity || 0]]);
        requestNotice("Review this phone, choose the reason and confirm the return request.");
      }; });
    }
    async function lookup(nextOffset = 0) {
      const value = get("phone_search").value.trim(), supplierId = get("supplier").value;
      clearPhone();
      if (!supplierId || !value) { requestNotice("Select a supplier and enter a model or IMEI.", true); return; }
      const version = lookupGeneration;
      q("[data-sr-lookup]").disabled = true; requestNotice("Finding this supplier’s phones…");
      try {
        const result = await rpc("search_supplier_return_devices", { p_supplier_id: supplierId, p_query: value, p_offset: nextOffset, p_limit: pageSize });
        if (!host.isConnected || version !== lookupGeneration || get("supplier").value !== supplierId || get("phone_search").value.trim() !== value) return;
        if (!Array.isArray(result?.items) || result.items.some(r => r.supplier_id !== supplierId)) throw new Error("The phone search returned an invalid supplier result. Search again.");
        matches = result.items; offset = nextOffset; hasMore = Boolean(result.has_more);
        showMatches(); requestNotice(matches.length ? "Select the exact phone to return." : "");
      } catch(e) { if (host.isConnected && version === lookupGeneration) requestNotice(e.message, true); }
      finally { if (host.isConnected && version === lookupGeneration) q("[data-sr-lookup]").disabled = false; }
    }
    get("supplier").value = preferredSupplier || ""; updateSupplier();
    get("supplier").onchange = updateSupplier; get("mode").onchange = updateMode; get("batch").onchange = updateBatch;
    get("plan").onchange = () => { const b = selectedBatch(), p = b?.plan_lines?.find(p => p.plan_line_id === get("plan").value); get("quantity").max = String(p?.remaining_quantity ?? b?.remaining_quantity ?? 0); get("confirm").checked = false; };
    ["quantity","serials"].forEach(name => { get(name).oninput = () => { get("confirm").checked = false; }; });
    get("phone_search").oninput = () => { clearPhone(); requestNotice(""); };
    get("phone_search").onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); lookup(); } };
    q("[data-sr-lookup]").onclick = () => lookup(); q("[data-sr-prev]").onclick = () => lookup(Math.max(0,offset-pageSize)); q("[data-sr-next]").onclick = () => lookup(offset+pageSize);
    form.onsubmit = e => {
      e.preventDefault(); if (modalBusy || !allowed("request")) return;
      const supplierId = get("supplier").value, payload = { reason: get("reason").value, notes: get("notes").value.trim() };
      if (!supplierId) { requestNotice("Select the supplier first.", true); return; }
      if (payload.reason === "other" && !payload.notes) { requestNotice("Describe the reason for this return.", true); return; }
      if (!get("confirm").checked) { requestNotice("Confirm the selected phones first.", true); return; }
      if (get("mode").value === "imei") {
        if (!found?.eligible || found.supplier_id !== supplierId) { requestNotice("Search and select an eligible phone from this supplier first.", true); return; }
        payload.job_id = found.job_id;
      } else {
        const b = selectedBatch(), p = b?.plan_lines?.find(p => p.plan_line_id === get("plan").value);
        const quantity = Number(get("quantity").value), serials = get("serials").value.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
        if (!b || !Number.isInteger(quantity) || quantity < 1 || quantity > Number(p?.remaining_quantity ?? b.remaining_quantity) || ((b.plan_lines || []).length && !p)) { requestNotice("Select a batch / planned model and a quantity within the available unentered units.", true); return; }
        if (serials.length > quantity || new Set(serials).size !== serials.length) { requestNotice("Enter no more than one unique serial number per unit.", true); return; }
        Object.assign(payload, { batch_id: b.batch_id, quantity, serial_numbers: serials });
        if (p) payload.plan_line_id = p.plan_line_id;
      }
      mutate("create_supplier_return", { p_payload: payload }, e.submitter, async result => {
        const ids = (result.returns || []).map(r => r.return_number).join(", ");
        host.innerHTML = "";
        await refreshReport();
        await loadRequest(supplierId, "Return requested: " + ids + ". Label these phones with their Return IDs. Approval, parts reconciliation and handover are in Return history below.");
      }, requestNotice);
    };
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
    root.innerHTML = '<section class="sr-card sr-report" data-sr-create><header><p class="panel-kicker">New return</p><h2>Return phones to a supplier</h2><p>Select a supplier, identify the phones and enter the reason for return.</p></header><div data-sr-request-host></div></section>' +
      '<section class="sr-card sr-report"><header class="sr-heading"><div><p class="panel-kicker">Saved returns</p><h2>Return history &amp; handover</h2></div>' + button("Print selected return slip", "data-sr-print disabled") + '</header>' +
      '<form class="sr-filters"><label>Status<select name="status"><option value="">All statuses</option>' + Object.keys(labels).slice(0,5).map(s => '<option value="' + s + '">' + labels[s] + '</option>').join("") + '</select></label><label>Find return / IMEI / serial / supplier code<input name="search" type="search" maxlength="100"></label><button class="secondary-button" type="submit">Search / refresh</button></form><p data-sr-message role="status" aria-live="polite"></p><div data-sr-balances></div><div class="sr-table-wrap" data-sr-table></div></section>';
    root.querySelector(".sr-filters").onsubmit = e => { e.preventDefault(); refreshReport(); };
    root.querySelector("[data-sr-print]").onclick = printSlip;
    refreshReport(); loadRequest();
  }
  function unmount() { reportRoot = null; reportRows = []; selected.clear(); ++reportGeneration; }
  window.GREENLOOP_SUPPLIER_RETURNS = { mount, unmount };
  const root = document.querySelector("#stock-return-app");
  if (root) {
    const sidebar = document.querySelector("#sidebar"), backdrop = document.querySelector("#menu-backdrop");
    const setMenu = open => { sidebar?.classList.toggle("is-open", open); if (backdrop) backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); };
    document.querySelector("#open-menu")?.addEventListener("click", () => setMenu(true));
    document.querySelector("#close-menu")?.addEventListener("click", () => setMenu(false));
    backdrop?.addEventListener("click", () => setMenu(false));
    document.addEventListener("keydown", event => { if (event.key === "Escape" && !dialog?.open) setMenu(false); });
    Promise.resolve(window.GREENLOOP_ACCESS_READY).then(() => {
      if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "supplier_returns") return;
      root.hidden = false; mount(root);
    }).catch(() => {
      const message = document.querySelector("#permission-message");
      if (message) { message.hidden = false; message.textContent = "Could not load Stock Return permissions. Refresh to try again."; }
    });
  }
})();
