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
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let requests = [];
  let inventory = [];
  let partNames = [];
  let toastTimer;

  const getClient = () => (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
  const money = (value) => `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const jobOf = (request) => Array.isArray(request.job) ? request.job[0] : request.job;
  const deviceOf = (request) => { const job = jobOf(request) || {}; return Array.isArray(job.device) ? job.device[0] : job.device; };
  const supplierOf = (request) => { const job = jobOf(request) || {}; return Array.isArray(job.supplier) ? job.supplier[0] : job.supplier; };
  const supplierLabel = (supplier) => [supplier?.supplier_code, supplier?.company_name].filter((value) => String(value || "").trim()).join(" - ") || "—";
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
    requestCount.textContent = `${requests.length} waiting`;
    queueList.innerHTML = requests.length ? requests.map((request) => {
      const job = jobOf(request) || {};
      const device = deviceOf(request) || {};
      const supplier = supplierOf(request) || {};
      const remaining = Number(request.quantity_requested) - Number(request.quantity_issued);
      return `<tr><td>${escapeHtml(device.imei_1 || "—")}</td><td>${escapeHtml(device.device_number || "—")}<small>${escapeHtml(device.model || "")}</small></td><td>${escapeHtml(job.job_number || "—")}</td><td>${escapeHtml(supplierLabel(supplier))}</td><td><strong>${escapeHtml(request.part_name)}</strong><small>${request.request_source === "technician_additional" ? "Additional technician request" : "Initial QC request"}</small></td><td>${request.quantity_requested}</td><td>${remaining}</td><td><select data-inventory-request="${request.id}">${inventoryOptions()}</select></td><td><input data-quantity-request="${request.id}" type="number" min="1" max="${remaining}" step="1" value="${Math.max(1, remaining)}"></td><td><button class="issue-row-button" type="button" data-issue-request="${request.id}">Issue</button></td></tr>`;
    }).join("") : '<tr><td colspan="10">No part requests are waiting.</td></tr>';
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

  async function loadData() {
    const [requestResponse, inventoryResponse] = await Promise.all([
      getClient().from("job_part_requests").select("id, part_name, quantity_requested, quantity_issued, request_source, notes, status, job:jobs!inner(job_number, supplier:suppliers(supplier_code, company_name), device:devices(device_number, imei_1, model))").in("status", ["requested", "partially_issued"]).order("requested_at", { ascending: true }),
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
    app.hidden = false;
    await Promise.all([loadPartNames(), loadData()]);
  }

  queueList.addEventListener("click", (event) => { const button = event.target.closest("[data-issue-request]"); if (button) issueRequest(button); });
  inventoryForm.addEventListener("submit", saveInventory);
  document.querySelector("#add-part-name").addEventListener("click", addPartName);
  document.querySelector("#remove-part-name").addEventListener("click", removePartName);
  document.querySelector("#refresh-parts").addEventListener("click", () => loadData().catch((error) => toastMessage(error.message || "Parts data could not be refreshed.")));
  document.querySelector("#open-menu").addEventListener("click", () => { sidebar.classList.add("is-open"); backdrop.hidden = false; });
  document.querySelector("#close-menu").addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
  backdrop.addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Parts could not be loaded."; permissionMessage.hidden = false; });
})();
