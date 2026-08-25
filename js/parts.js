(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#parts-app");
  const permissionMessage = document.querySelector("#permission-message");
  const requestCount = document.querySelector("#request-count");
  const queueList = document.querySelector("#parts-queue-list");
  const inventoryTable = document.querySelector("#inventory-table");
  const inventoryForm = document.querySelector("#inventory-form");
  const inventoryName = document.querySelector("#inventory-name");
  const issueMessage = document.querySelector("#issue-message");
  const inventoryMessage = document.querySelector("#inventory-message");
  const partReturnReport = document.querySelector("#part-return-report");
  const returnReportMessage = document.querySelector("#return-report-message");
  const returnedPartsCount = document.querySelector("#returned-parts-count");
  const damagedPartsCount = document.querySelector("#damaged-parts-count");
  const faultyPartsCount = document.querySelector("#faulty-parts-count");
  const pendingReturnsCount = document.querySelector("#pending-returns-count");
  const manualLabPartsControl = document.querySelector("#manual-lab-parts-control");
  const manualLabPartsToggle = document.querySelector("#manual-lab-parts-toggle");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let requests = [];
  let inventory = [];
  let partNames = [];
  let partReturns = [];
  let pendingReturns = [];
  let activeReturnCondition = "pending";
  let manualLabPartsMode = false;
  let toastTimer;

  const getClient = () => (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
  const money = (value) => `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const dateTime = (value) => value ? new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  const jobOf = (request) => Array.isArray(request.job) ? request.job[0] : request.job;
  const deviceOf = (request) => { const job = jobOf(request) || {}; return Array.isArray(job.device) ? job.device[0] : job.device; };
  const supplierOf = (request) => { const job = jobOf(request) || {}; return Array.isArray(job.supplier) ? job.supplier[0] : job.supplier; };
  const batchOf = (request) => { const job = jobOf(request) || {}; return Array.isArray(job.receiving_batch) ? job.receiving_batch[0] : job.receiving_batch; };
  const supplierLabel = (supplier, batch) => typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
    ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(supplier?.supplier_code, batch?.planned_quantity, supplier?.company_name, "—")
    : (String(supplier?.supplier_code || "").trim() || "—");
  const normalisePartName = (value) => String(value || "").trim().replace(/\s+/g, " ").toLocaleLowerCase();
  const invoiceDetails = (part) => {
    const notes = String(part?.notes || "");
    const invoice = notes.match(/\[Inventory invoice:\s*([^|\]]+)/i)?.[1]?.trim() || "Legacy stock";
    const origin = notes.match(/\|\s*Origin:\s*([^\]]+)/i)?.[1]?.trim() || "--";
    return { invoice, origin };
  };

  function setMessage(element, text = "", success = false) {
    element.textContent = text;
    element.classList.toggle("is-visible", Boolean(text));
    element.classList.toggle("is-success", success);
  }

  function toastMessage(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400);
  }

  function renderManualLabPartsMode() {
    manualLabPartsToggle.dataset.state = manualLabPartsMode ? "on" : "off";
    manualLabPartsToggle.setAttribute("aria-pressed", String(manualLabPartsMode));
    manualLabPartsToggle.textContent = `Manual Lab Parts: ${manualLabPartsMode ? "ON" : "OFF"}`;
  }

  async function loadManualLabPartsMode() {
    const { data, error } = await getClient().rpc("get_manual_lab_parts_mode");
    if (error) throw error;
    manualLabPartsMode = Boolean(data);
    renderManualLabPartsMode();
  }

  async function toggleManualLabPartsMode() {
    const nextMode = !manualLabPartsMode;
    manualLabPartsToggle.disabled = true;
    const { data, error } = await getClient().rpc("set_manual_lab_parts_mode", { p_enabled: nextMode });
    manualLabPartsToggle.disabled = false;
    if (error) { setMessage(issueMessage, error.message || "Manual Lab Parts Mode could not be changed."); return; }
    manualLabPartsMode = Boolean(data);
    renderManualLabPartsMode();
    toastMessage(manualLabPartsMode ? "Manual Lab Parts Mode is ON. New Lab parts stay outside Parts and Inventory." : "Manual Lab Parts Mode is OFF. Normal Parts and Inventory workflow is active.");
  }

  async function loadPartNames() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "part_name" });
    if (error) throw error;
    partNames = data || [];
    const selected = inventoryName.value;
    inventoryName.replaceChildren(new Option("Select part name", ""));
    partNames.forEach((part) => {
      const option = new Option(part.option_value, part.option_value);
      option.dataset.optionId = part.id;
      inventoryName.add(option);
    });
    if ([...inventoryName.options].some((option) => option.value === selected)) inventoryName.value = selected;
  }

  function inventoryOptions() {
    return [`<option value="">Select inventory part</option>`, ...inventory.filter((part) => part.is_active && Number(part.stock_quantity) > 0).map((part) => `<option value="${escapeHtml(part.id)}">${escapeHtml(part.sku)} · ${escapeHtml(part.part_name)} · ${part.stock_quantity} in stock</option>`)].join("");
  }

  function inventoryOptionsForRequest(requestedPartName) {
    const matchingParts = inventory.filter((part) => part.is_active && Number(part.stock_quantity) > 0 && normalisePartName(part.part_name) === normalisePartName(requestedPartName));
    const firstOption = matchingParts.length ? "Select invoice lot and exact price" : "No matching inventory part in stock";
    return [`<option value="">${firstOption}</option>`, ...matchingParts.map((part) => {
      const lot = invoiceDetails(part);
      return `<option value="${escapeHtml(part.id)}">Invoice ${escapeHtml(lot.invoice)} | ${escapeHtml(part.part_name)} | ${money(part.unit_cost)} each | ${part.stock_quantity} available</option>`;
    })].join("");
  }

  function renderQueue() {
    const waiting = requests.filter((request) => Number(request.quantity_issued || 0) < Number(request.quantity_requested || 0) && request.status !== "issued");
    requestCount.textContent = `${waiting.length} waiting`;
    queueList.innerHTML = requests.length ? requests.map((request) => {
      const job = jobOf(request) || {};
      const device = deviceOf(request) || {};
      const supplier = supplierOf(request) || {};
      const remaining = Number(request.quantity_requested) - Number(request.quantity_issued);
      const issued = remaining <= 0 || request.status === "issued";
      const sourceLabel = request.request_source === "technician_additional"
        ? "Additional Laboratory request"
        : "Laboratory request from Initial QC plan";
      const stockControl = issued
        ? `<span class="part-status-chip issued">Issued</span>`
        : `<select data-inventory-request="${request.id}">${inventoryOptions()}</select>`;
      const quantityControl = issued
        ? `${Number(request.quantity_issued || 0)}`
        : `<input data-quantity-request="${request.id}" type="number" min="1" max="${remaining}" step="1" value="${Math.max(1, remaining)}">`;
      const actionControl = issued
        ? `<span class="part-status-chip issued">✓ Complete</span>`
        : `<div class="request-actions"><button class="issue-row-button" type="button" data-issue-request="${request.id}">Issue</button><button class="cancel-request-button" type="button" data-cancel-request="${request.id}">Cancel</button></div>`;
      return `<tr class="part-request-row ${issued ? "is-issued" : "is-pending"}"><td>${escapeHtml(device.imei_1 || "—")}</td><td>${escapeHtml(device.device_number || "—")}<small>${escapeHtml(device.model || "")}</small></td><td>${escapeHtml(job.job_number || "—")}</td><td>${escapeHtml(supplierLabel(supplier, batchOf(request)))}</td><td><strong>${escapeHtml(request.requested_for_technician || "Unassigned")}</strong><small>Lab request</small></td><td><strong>${escapeHtml(request.part_name)}</strong><small>${sourceLabel}</small></td><td>${request.quantity_requested}</td><td><span class="part-status-chip ${issued ? "issued" : "pending"}">${issued ? "Issued" : `${remaining} pending`}</span></td><td>${stockControl}</td><td>${quantityControl}</td><td>${actionControl}</td></tr>`;
    }).join("") : '<tr><td colspan="11">No part requests are waiting.</td></tr>';
    queueList.querySelectorAll("[data-inventory-request]").forEach((select) => {
      const request = requests.find((item) => item.id === select.dataset.inventoryRequest);
      if (request) select.innerHTML = inventoryOptionsForRequest(request.part_name);
    });
  }

  function renderInventory() {
    inventoryTable.innerHTML = inventory.length ? inventory.map((part) => {
      const lot = invoiceDetails(part);
      return `<tr><td>${escapeHtml(lot.invoice)}</td><td>${escapeHtml(part.sku)}</td><td>${escapeHtml(part.part_name)}</td><td>${part.stock_quantity}</td><td>${money(part.unit_cost)}</td><td>${escapeHtml(lot.origin)}</td></tr>`;
    }).join("") : '<tr><td colspan="6">No inventory has been added yet.</td></tr>';
  }

  function renderPartReturnReport() {
    const condition = (item) => String(item?.return_condition || "").trim().toLowerCase();
    const returned = partReturns.filter((item) => condition(item) === "restocked");
    const damaged = partReturns.filter((item) => condition(item) === "damaged");
    const faulty = partReturns.filter((item) => condition(item) === "faulty");
    pendingReturnsCount.textContent = pendingReturns.reduce((total, item) => total + Number(item.quantity || 0), 0);
    returnedPartsCount.textContent = returned.reduce((total, item) => total + Number(item.quantity || 0), 0);
    damagedPartsCount.textContent = damaged.reduce((total, item) => total + Number(item.quantity || 0), 0);
    faultyPartsCount.textContent = faulty.reduce((total, item) => total + Number(item.quantity || 0), 0);
    document.querySelectorAll("[data-return-report]").forEach((button) => button.classList.toggle("is-active", button.dataset.returnReport === activeReturnCondition));
    if (activeReturnCondition === "pending") {
      partReturnReport.innerHTML = pendingReturns.length ? pendingReturns.map((item) => `<tr>
        <td>${escapeHtml(dateTime(item.requested_at))}</td>
        <td><strong>${escapeHtml(item.imei || "—")}</strong><small>${escapeHtml(item.job_number || item.device_number || "")}</small></td>
        <td>${escapeHtml(item.supplier_code || "—")}</td>
        <td><strong>${escapeHtml(item.part_name || "—")}</strong><small>${escapeHtml(item.technician_name || "")}</small></td>
        <td>${Number(item.quantity || 0)}</td>
        <td>${escapeHtml(String(item.return_reason || "").replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()))}</td>
        <td>Pending inspection</td><td>—</td><td>—</td><td>Laboratory</td>
        <td><div class="return-review-actions"><button type="button" data-review-return="${escapeHtml(item.id)}" data-approve="true">Approve</button><button class="reject-return" type="button" data-review-return="${escapeHtml(item.id)}" data-approve="false">Reject</button></div></td>
      </tr>`).join("") : '<tr><td colspan="11">No part returns are waiting for approval.</td></tr>';
      return;
    }
    const rows = activeReturnCondition === "damaged" ? damaged : activeReturnCondition === "faulty" ? faulty : returned;
    partReturnReport.innerHTML = rows.length ? rows.map((item) => `<tr>
      <td>${escapeHtml(dateTime(item.returned_at))}</td>
      <td><strong>${escapeHtml(item.imei || "—")}</strong><small>${escapeHtml(item.job_number || item.device_number || "")}</small></td>
      <td>${escapeHtml(item.supplier_code || "—")}</td>
      <td><strong>${escapeHtml(item.part_name || "—")}</strong></td>
      <td>${Number(item.quantity || 0)}</td>
      <td>${escapeHtml(item.reason || "—")}</td>
      <td>${escapeHtml(item.invoice_number || "Legacy / unknown")}</td>
      <td>${money(item.unit_cost)}</td>
      <td>${money(item.total_value)}</td>
      <td>${escapeHtml(item.returned_by_name || "System")}</td>
      <td><span class="return-report-status">Approved</span></td>
    </tr>`).join("") : `<tr><td colspan="11">No ${activeReturnCondition} parts have been recorded yet.</td></tr>`;
  }

  async function loadPartReturnReport() {
    setMessage(returnReportMessage);
    const [reportResponse, pendingResponse] = await Promise.all([
      getClient().rpc("get_part_return_report", { p_return_condition: null, p_limit: 500 }),
      getClient().rpc("get_pending_part_return_requests")
    ]);
    if (reportResponse.error || pendingResponse.error) {
      setMessage(returnReportMessage, reportResponse.error?.message || pendingResponse.error?.message || "Part return reports could not be loaded.");
      return;
    }
    partReturns = reportResponse.data || [];
    pendingReturns = pendingResponse.data || [];
    renderPartReturnReport();
  }

  async function loadData() {
    const [requestResponse, inventoryResponse] = await Promise.all([
      getClient().from("job_part_requests").select("id, part_name, quantity_requested, quantity_issued, request_source, requested_for_technician, notes, status, requested_at, job:jobs!inner(job_number, supplier:suppliers(supplier_code, company_name), receiving_batch:receiving_batches(planned_quantity), device:devices(device_number, imei_1, model))").in("status", ["requested", "partially_issued", "issued"]).order("requested_at", { ascending: false }).limit(500),
      getClient().from("part_inventory").select("id, sku, part_name, stock_quantity, unit_cost, is_active, notes").order("part_name")
    ]);
    if (requestResponse.error) throw requestResponse.error;
    if (inventoryResponse.error) throw inventoryResponse.error;
    requests = requestResponse.data || [];
    inventory = inventoryResponse.data || [];
    renderQueue();
    renderInventory();
  }

  async function issueRequest(button) {
    setMessage(issueMessage);
    const requestId = button.dataset.issueRequest;
    const inventoryId = queueList.querySelector(`[data-inventory-request="${requestId}"]`)?.value;
    const quantity = Number(queueList.querySelector(`[data-quantity-request="${requestId}"]`)?.value);
    if (!inventoryId || !Number.isInteger(quantity) || quantity < 1) {
      setMessage(issueMessage, "Select an inventory part and valid quantity first.");
      return;
    }
    button.disabled = true;
    button.textContent = "Issuing...";
    const { data, error } = await getClient().rpc("issue_part_request", {
      p_part_request_id: requestId,
      p_inventory_part_id: inventoryId,
      p_quantity: quantity,
      p_notes: null
    });
    if (error) {
      button.disabled = false;
      button.textContent = "Issue";
      setMessage(issueMessage, error.message || "The part could not be issued.");
      return;
    }
    const result = data?.[0];
    const text = result?.routed_to_laboratory ? "Part issued. The job is also available in Laboratory." : "Part issued successfully.";
    setMessage(issueMessage, text, true);
    toastMessage(text);
    await loadData();
  }

  async function cancelRequest(button) {
    const reason = window.prompt("Enter the reason for cancelling this parts request:");
    if (reason === null) return;
    if (!window.confirm("Cancel this unissued parts request?")) return;
    button.disabled = true;
    button.textContent = "Cancelling...";
    const { error } = await getClient().rpc("cancel_part_request", {
      p_part_request_id: button.dataset.cancelRequest,
      p_notes: reason.trim() || null
    });
    button.disabled = false;
    button.textContent = "Cancel";
    if (error) { setMessage(issueMessage, error.message || "The request could not be cancelled."); return; }
    setMessage(issueMessage, "Parts request cancelled by Parts Department.", true);
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await loadData();
  }

  async function reviewReturn(button) {
    const approve = button.dataset.approve === "true";
    const message = approve
      ? "Approve this returned part after checking its physical condition?"
      : "Reject this returned part request?";
    if (!window.confirm(message)) return;
    button.disabled = true;
    const { data, error } = await getClient().rpc("review_lab_part_return", {
      p_return_request_id: button.dataset.reviewReturn,
      p_approve: approve,
      p_notes: null
    });
    button.disabled = false;
    if (error) { setMessage(returnReportMessage, error.message || "The return could not be reviewed."); return; }
    const text = approve
      ? data?.inventory_updated ? "Return approved and usable stock added to Inventory." : "Return approved and recorded outside usable Inventory."
      : "Return request rejected. Inventory was not changed.";
    setMessage(returnReportMessage, text, true);
    toastMessage(text);
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await Promise.all([loadData(), loadPartReturnReport()]);
  }

  async function addPartName() {
    const value = window.prompt("Enter the new part name:");
    if (!value?.trim()) return;
    const { data, error } = await getClient().rpc("add_entry_option", { p_option_group: "part_name", p_option_value: value.trim() });
    if (error) { setMessage(inventoryMessage, error.message || "Part name could not be added."); return; }
    await loadPartNames();
    inventoryName.value = data?.[0]?.saved_value || value.trim();
    toastMessage("Part name saved.");
  }

  async function removePartName() {
    const optionId = inventoryName.selectedOptions[0]?.dataset.optionId;
    if (!optionId) { setMessage(inventoryMessage, "Select a part name before removing it."); return; }
    const code = window.prompt("Enter deletion code to remove this part name:");
    if (code !== "1213") { toastMessage("Part name was not removed. Deletion code is incorrect."); return; }
    const { error } = await getClient().rpc("delete_entry_option", { p_option_id: optionId, p_deletion_code: code });
    if (error) { setMessage(inventoryMessage, error.message || "Part name could not be removed."); return; }
    await loadPartNames();
    toastMessage("Part name removed.");
  }

  async function saveInventory(event) {
    event.preventDefault();
    setMessage(inventoryMessage);
    if (!inventoryForm.checkValidity()) { inventoryForm.reportValidity(); return; }
    const button = document.querySelector("#inventory-button");
    button.disabled = true;
    button.textContent = "Saving...";
    const { error } = await getClient().rpc("add_part_inventory", {
      p_sku: document.querySelector("#inventory-sku").value,
      p_part_name: inventoryName.value,
      p_stock_quantity: Number(document.querySelector("#inventory-qty").value),
      p_unit_cost: Number(document.querySelector("#inventory-cost").value),
      p_notes: null
    });
    button.disabled = false;
    button.textContent = "Save item";
    if (error) { setMessage(inventoryMessage, error.message || "Inventory could not be saved."); return; }
    inventoryForm.reset();
    document.querySelector("#inventory-qty").value = 0;
    document.querySelector("#inventory-cost").value = 0;
    setMessage(inventoryMessage, "Inventory item saved.", true);
    toastMessage("Inventory item saved.");
    await loadData();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canUse, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "parts"] });
    if (error) throw error;
    if (!canUse) { permissionMessage.textContent = "Your account does not have Parts permission."; permissionMessage.hidden = false; return; }
    const { data: canManageWorkflow, error: workflowRoleError } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner"] });
    if (workflowRoleError) throw workflowRoleError;
    if (canManageWorkflow) {
      manualLabPartsControl.hidden = false;
      await loadManualLabPartsMode();
    }
    app.hidden = false;
    await Promise.all([loadPartNames(), loadData(), loadPartReturnReport()]);
    window.setInterval(() => {
      if (!document.hidden) loadPartReturnReport().catch(() => {});
    }, 15000);
  }

  queueList.addEventListener("click", (event) => {
    const issue = event.target.closest("[data-issue-request]"); if (issue) { issueRequest(issue); return; }
    const cancel = event.target.closest("[data-cancel-request]"); if (cancel) cancelRequest(cancel);
  });
  partReturnReport.addEventListener("click", (event) => {
    const button = event.target.closest("[data-review-return]");
    if (button) reviewReturn(button);
  });
  inventoryForm.addEventListener("submit", saveInventory);
  document.querySelector("#add-part-name").addEventListener("click", addPartName);
  document.querySelector("#remove-part-name").addEventListener("click", removePartName);
  document.querySelector("#refresh-parts").addEventListener("click", () => loadData().catch((error) => toastMessage(error.message || "Parts data could not be refreshed.")));
  document.querySelector("#refresh-return-report").addEventListener("click", () => loadPartReturnReport().catch((error) => setMessage(returnReportMessage, error.message || "Part return reports could not be refreshed.")));
  manualLabPartsToggle.addEventListener("click", () => toggleManualLabPartsMode().catch((error) => setMessage(issueMessage, error.message || "Manual Lab Parts Mode could not be changed.")));
  document.addEventListener("greenloop:notifications-changed", () => loadPartReturnReport().catch(() => {}));
  document.querySelectorAll("[data-return-report]").forEach((button) => button.addEventListener("click", () => {
    activeReturnCondition = button.dataset.returnReport;
    renderPartReturnReport();
  }));
  document.querySelector("#open-menu").addEventListener("click", () => { sidebar.classList.add("is-open"); backdrop.hidden = false; });
  document.querySelector("#close-menu").addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
  backdrop.addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Parts could not be loaded."; permissionMessage.hidden = false; });
})();
