(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const form = document.querySelector("#stock-entry-form");
  const channel = document.querySelector("#stock-channel");
  const supplier = document.querySelector("#supplier-id");
  const notes = document.querySelector("#receiving-notes");
  const planLines = document.querySelector("#stock-plan-lines");
  const planTotal = document.querySelector("#stock-plan-total");
  const message = document.querySelector("#form-message");
  const submit = document.querySelector("#create-batch");
  const permissionMessage = document.querySelector("#permission-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const supplierDialog = document.querySelector("#supplier-dialog");
  const supplierForm = document.querySelector("#supplier-form");
  const supplierName = document.querySelector("#supplier-name");
  const supplierMessage = document.querySelector("#supplier-message");
  const saveSupplier = document.querySelector("#save-supplier");
  const masterOptions = { model: [], storage_gb: [], color: [] };
  const optionLabels = { model: "model", storage_gb: "GB", color: "color" };
  let client;
  let toastTimer;

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function text(value) { return String(value || "").trim() || null; }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]); }
  function normalized(value) { return String(value || "").trim().replace(/\s+/g, " ").toLowerCase(); }
  function showToast(value) { window.clearTimeout(toastTimer); toast.textContent = value; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200); }
  function setMessage(value = "", type = "error") { message.textContent = value; message.classList.toggle("is-visible", Boolean(value)); message.classList.toggle("is-success", type === "success"); }
  function setSupplierMessage(value = "") { supplierMessage.textContent = value; supplierMessage.classList.toggle("is-visible", Boolean(value)); }
  function setBusy(button, busy, label) { if (busy) button.dataset.label = button.textContent; button.disabled = busy; button.textContent = busy ? label : (button.dataset.label || button.textContent); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }

  async function loadChannels() {
    const previous = channel.value;
    const { data, error } = await api().rpc("get_stock_channels");
    if (error) throw error;
    channel.replaceChildren(new Option("Select stock channel", ""));
    (data || []).forEach((item) => channel.add(new Option(item.channel_name, item.id)));
    if ([...channel.options].some((option) => option.value === previous)) channel.value = previous;
  }

  async function loadSuppliers(selectedId = supplier.value) {
    const { data, error } = await api().from("suppliers").select("id, supplier_code, company_name").eq("is_active", true).is("deleted_at", null).order("supplier_code");
    if (error) throw error;
    supplier.replaceChildren(new Option("Select supplier code", ""));
    (data || []).forEach((item) => supplier.add(new Option(item.supplier_code || item.company_name, item.id)));
    if ([...supplier.options].some((option) => option.value === selectedId)) supplier.value = selectedId;
  }

  async function loadMasterOptions() {
    const groups = Object.keys(masterOptions);
    await Promise.all(groups.map(async (group) => {
      const { data, error } = await api().rpc("get_entry_options", { p_option_group: group });
      if (error) throw error;
      masterOptions[group] = data || [];
    }));
  }

  function readPlanLines() {
    return [...planLines.querySelectorAll("tr[data-plan-line]")].map((row) => ({
      model: row.querySelector("[data-plan-model]").value,
      storage_gb: row.querySelector("[data-plan-storage]").value,
      color: row.querySelector("[data-plan-color]").value,
      quantity: row.querySelector("[data-plan-quantity]").value
    }));
  }

  function optionMarkup(group, selectedValue) {
    const placeholder = group === "storage_gb" ? "Select GB" : `Select ${optionLabels[group]}`;
    const values = masterOptions[group] || [];
    const selectedExists = values.some((item) => String(item.option_value) === String(selectedValue));
    const options = [`<option value="">${placeholder}</option>`];
    if (selectedValue && !selectedExists) options.push(`<option value="${escapeHtml(selectedValue)}" selected>${escapeHtml(selectedValue)}</option>`);
    values.forEach((item) => options.push(`<option value="${escapeHtml(item.option_value)}" data-option-id="${escapeHtml(item.id)}" ${String(item.option_value) === String(selectedValue) ? "selected" : ""}>${escapeHtml(item.option_value)}</option>`));
    return options.join("");
  }

  function optionControl(group, selectedValue, fieldAttribute, required = true) {
    const label = optionLabels[group];
    return `<div class="stock-plan-option-control"><select ${fieldAttribute} ${required ? "required" : ""} aria-label="${label}">${optionMarkup(group, selectedValue)}</select><button class="master-add" type="button" data-action="add-option" data-option-group="${group}" title="Add ${label}">+</button><button class="master-remove" type="button" data-action="remove-option" data-option-group="${group}" title="Remove selected ${label}">−</button></div>`;
  }

  function planRow(line = {}) {
    return `<tr data-plan-line><td>${optionControl("model", line.model || "", "data-plan-model", false)}</td><td>${optionControl("storage_gb", line.storage_gb || "", "data-plan-storage", false)}</td><td>${optionControl("color", line.color || "", "data-plan-color", false)}</td><td><input data-plan-quantity type="number" min="1" step="1" inputmode="numeric" value="${escapeHtml(line.quantity || "")}" placeholder="Total stock" required aria-label="Total stock"></td><td><button class="stock-plan-delete" data-action="delete-line" type="button" title="Remove this line">−</button></td></tr>`;
  }

  function renderPlanLines(lines = [{ quantity: 1 }]) {
    const nextLines = lines.length ? lines : [{ quantity: 1 }];
    planLines.innerHTML = nextLines.map((line) => planRow(line)).join("");
    updatePlanTotal();
  }

  function updatePlanTotal() {
    const total = readPlanLines().reduce((sum, line) => sum + Math.max(0, Number(line.quantity) || 0), 0);
    planTotal.textContent = `Total: ${total} pcs`;
  }

  function validatePlan() {
    const lines = readPlanLines().map((line) => ({
      model: text(line.model),
      storage_gb: line.storage_gb === "" ? null : Number(line.storage_gb),
      color: text(line.color),
      quantity: Number(line.quantity)
    }));
    if (!lines.length || lines.some((line) => (line.storage_gb !== null && (!Number.isInteger(line.storage_gb) || line.storage_gb <= 0)) || !Number.isInteger(line.quantity) || line.quantity <= 0)) {
      throw new Error("Enter Total Stock of at least 1. Model, GB and Color are optional.");
    }
    if (lines.length > 1 && lines.some((line) => !line.model)) {
      throw new Error("For a quantity-only batch, keep one line and leave Model, GB and Color blank. Multiple plan lines require a Model on every line.");
    }
    const combinations = new Set();
    for (const line of lines) {
      const key = `${normalized(line.model)}|${line.storage_gb}|${normalized(line.color)}`;
      if (combinations.has(key)) throw new Error("Do not repeat the same Model, GB, and Color line. Increase its quantity instead.");
      combinations.add(key);
    }
    return lines;
  }

  async function addOrRemoveOption(button) {
    const group = button.dataset.optionGroup;
    const select = button.closest(".stock-plan-option-control").querySelector("select");
    if (button.dataset.action === "add-option") {
      const value = window.prompt(`Enter the new ${optionLabels[group]}:`);
      if (!value?.trim()) return;
      const { data, error } = await api().rpc("add_entry_option", { p_option_group: group, p_option_value: value.trim() });
      if (error) { setMessage(error.message || "The option could not be added."); return; }
      const lines = readPlanLines();
      const rowIndex = [...planLines.querySelectorAll("tr[data-plan-line]")].indexOf(button.closest("tr"));
      if (group === "model") lines[rowIndex].model = data?.[0]?.saved_value || value.trim();
      if (group === "storage_gb") lines[rowIndex].storage_gb = data?.[0]?.saved_value || value.trim();
      if (group === "color") lines[rowIndex].color = data?.[0]?.saved_value || value.trim();
      await loadMasterOptions();
      renderPlanLines(lines);
      showToast("Option saved.");
      return;
    }

    const optionId = select.selectedOptions[0]?.dataset.optionId;
    if (!optionId) { setMessage(`Select a ${optionLabels[group]} before removing it.`); return; }
    const code = window.prompt(`Enter deletion code to remove this ${optionLabels[group]}:`);
    if (code !== "1213") { showToast("Option was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("delete_entry_option", { p_option_id: optionId, p_deletion_code: code });
    if (error) { setMessage(error.message || "The option could not be removed."); return; }
    const lines = readPlanLines();
    await loadMasterOptions();
    renderPlanLines(lines);
    showToast("Option removed.");
  }

  async function addChannel() {
    const value = window.prompt("Enter the new stock channel:");
    if (!value?.trim()) return;
    const { data, error } = await api().rpc("add_stock_channel", { p_channel_name: value.trim() });
    if (error) { setMessage(error.message || "The stock channel could not be added."); return; }
    await loadChannels();
    channel.value = data?.[0]?.id || "";
    showToast("Stock channel saved.");
  }

  async function removeChannel() {
    if (!channel.value) { setMessage("Select a stock channel before removing it."); return; }
    const code = window.prompt("Enter deletion code to remove this stock channel:");
    if (code !== "1213") { showToast("Stock channel was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("delete_stock_channel", { p_channel_id: channel.value, p_deletion_code: code });
    if (error) { setMessage(error.message || "The stock channel could not be removed."); return; }
    await loadChannels();
    showToast("Stock channel removed.");
  }

  function openSupplierDialog() { supplierForm.reset(); setSupplierMessage(); supplierDialog.showModal(); supplierName.focus(); }

  async function saveNewSupplier(event) {
    event.preventDefault();
    if (!supplierForm.checkValidity()) { supplierForm.reportValidity(); return; }
    setBusy(saveSupplier, true, "Saving...");
    const { data, error } = await api().rpc("create_supplier", { p_company_name: supplierName.value, p_contact_name: "", p_phone: "", p_email: "", p_country: "", p_notes: "" });
    setBusy(saveSupplier, false, "Saving...");
    if (error) { setSupplierMessage(error.message || "Supplier could not be saved."); return; }
    const saved = data?.[0];
    await loadSuppliers(saved?.id);
    supplierDialog.close();
    showToast(`Supplier ${saved?.supplier_code || ""} saved.`);
  }

  async function createBatch(event) {
    event.preventDefault();
    setMessage();
    if (!form.checkValidity()) { form.reportValidity(); return; }
    let lines;
    try { lines = validatePlan(); } catch (error) { setMessage(error.message); return; }
    setBusy(submit, true, "Saving stock plan...");
    const { data, error } = await api().rpc("create_stock_entry_batch_with_lines", {
      p_stock_channel_id: channel.value,
      p_supplier_id: supplier.value,
      p_receiving_notes: text(notes.value),
      p_lines: lines
    });
    setBusy(submit, false, "Saving stock plan...");
    if (error) { setMessage(error.message || "The stock plan could not be saved."); return; }
    const batch = data?.[0];
    setMessage(`${batch?.batch_number || "Stock batch"} saved with ${batch?.planned_quantity || 0} devices. Opening IMEI Entry.`, "success");
    window.setTimeout(() => window.location.assign(`imei-entry.html?batch=${encodeURIComponent(batch.batch_id)}`), 450);
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: session } = await api().auth.getSession();
    if (!session.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await api().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "rma"] });
    if (error) throw error;
    if (!allowed) throw new Error("Your account does not have Stock Received permission.");
    await Promise.all([loadChannels(), loadSuppliers(), loadMasterOptions()]);
    renderPlanLines();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#add-stock-channel").addEventListener("click", addChannel);
  document.querySelector("#remove-stock-channel").addEventListener("click", removeChannel);
  document.querySelector("#add-supplier").addEventListener("click", openSupplierDialog);
  document.querySelector("#close-supplier-dialog").addEventListener("click", () => supplierDialog.close());
  document.querySelector("#cancel-supplier").addEventListener("click", () => supplierDialog.close());
  supplierForm.addEventListener("submit", saveNewSupplier);
  document.querySelector("#add-stock-plan-line").addEventListener("click", () => renderPlanLines([...readPlanLines(), { quantity: 1 }]));
  planLines.addEventListener("input", updatePlanTotal);
  planLines.addEventListener("change", updatePlanTotal);
  planLines.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    if (button.dataset.action === "add-option" || button.dataset.action === "remove-option") { addOrRemoveOption(button).catch((error) => setMessage(error.message || "The option could not be updated.")); return; }
    if (button.dataset.action === "delete-line") {
      const rows = [...planLines.querySelectorAll("tr[data-plan-line]")];
      if (rows.length === 1) { setMessage("At least one stock plan line is required."); return; }
      const code = window.prompt("Enter deletion code to remove this stock plan line:");
      if (code !== "1213") { showToast("Stock plan line was not removed. Deletion code is incorrect."); return; }
      button.closest("tr").remove();
      updatePlanTotal();
    }
  });
  form.addEventListener("submit", createBatch);
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Stock Received could not be loaded."; permissionMessage.hidden = false; form.hidden = true; });
})();
