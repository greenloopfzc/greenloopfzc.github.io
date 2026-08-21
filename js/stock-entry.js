(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const form = document.querySelector("#stock-entry-form");
  const channel = document.querySelector("#stock-channel");
  const supplier = document.querySelector("#supplier-id");
  const quantity = document.querySelector("#quantity-received");
  const supplierCodeDisplay = document.querySelector("#supplier-code-display");
  const notes = document.querySelector("#receiving-notes");
  const message = document.querySelector("#form-message");
  const submit = document.querySelector("#create-batch");
  const permissionMessage = document.querySelector("#permission-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const supplierDialog = document.querySelector("#supplier-dialog");
  const supplierForm = document.querySelector("#supplier-form");
  const supplierCompanyName = document.querySelector("#supplier-company-name");
  const supplierMessage = document.querySelector("#supplier-message");
  const saveSupplier = document.querySelector("#save-supplier");
  let supplierRecords = [];
  let client;
  let toastTimer;

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function text(value) { return String(value || "").trim() || null; }
  function setMessage(value = "", type = "error") { message.textContent = value; message.classList.toggle("is-visible", Boolean(value)); message.classList.toggle("is-success", type === "success"); }
  function setSupplierMessage(value = "") { supplierMessage.textContent = value; supplierMessage.classList.toggle("is-visible", Boolean(value)); }
  function setBusy(button, busy, label) { if (busy) button.dataset.label = button.textContent; button.disabled = busy; button.textContent = busy ? label : (button.dataset.label || button.textContent); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(value) { window.clearTimeout(toastTimer); toast.textContent = value; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200); }

  async function loadChannels() {
    const previous = channel.value;
    const { data, error } = await api().rpc("get_stock_channels");
    if (error) throw error;
    channel.replaceChildren(new Option("Select stock channel", ""));
    (data || []).forEach((item) => channel.add(new Option(item.channel_name, item.id)));
    if ([...channel.options].some((option) => option.value === previous)) channel.value = previous;
  }

  function supplierCompanyLabel(record) {
    return text(record.company_name) || record.supplier_code || "Unnamed supplier";
  }

  async function loadSuppliers(selectedId = supplier.value) {
    const { data, error } = await api().from("suppliers").select("id, supplier_code, company_name").eq("is_active", true).is("deleted_at", null).order("company_name");
    if (error) throw error;
    supplierRecords = data || [];
    supplier.replaceChildren(new Option("Select supplier company", ""));
    supplierRecords.forEach((record) => supplier.add(new Option(supplierCompanyLabel(record), record.id)));
    if ([...supplier.options].some((option) => option.value === selectedId)) supplier.value = selectedId;
    updateSupplierCode();
  }

  function updateSupplierCode() {
    const selected = supplierRecords.find((record) => String(record.id) === String(supplier.value));
    const receivedQuantity = Number.parseInt(quantity.value, 10);
    supplierCodeDisplay.value = selected?.supplier_code && Number.isInteger(receivedQuantity) && receivedQuantity > 0
      ? `${selected.supplier_code}-(${receivedQuantity})`
      : "";
  }

  function openSupplierDialog() {
    supplierForm.reset();
    setSupplierMessage();
    supplierDialog.showModal();
    supplierCompanyName.focus();
  }

  async function saveNewSupplier(event) {
    event.preventDefault();
    setSupplierMessage();
    if (!supplierForm.checkValidity()) { supplierForm.reportValidity(); return; }
    setBusy(saveSupplier, true, "Saving...");
    const { data, error } = await api().rpc("create_supplier_from_company", { p_company_name: supplierCompanyName.value });
    setBusy(saveSupplier, false, "Saving...");
    if (error) { setSupplierMessage(error.message || "Supplier company could not be saved."); return; }
    await loadSuppliers(data?.[0]?.id);
    supplierDialog.close();
    showToast("Supplier company saved.");
  }

  async function removeSupplier() {
    if (!supplier.value) { setMessage("Select a supplier company before removing it."); return; }
    const selected = supplierRecords.find((record) => String(record.id) === String(supplier.value));
    const code = window.prompt(`Enter deletion code to remove ${supplierCompanyLabel(selected)}:`);
    if (code !== "1213") { showToast("Supplier company was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("remove_supplier_from_receipts", { p_supplier_id: supplier.value, p_deletion_code: code });
    if (error) { setMessage(error.message || "Supplier company could not be removed."); return; }
    await loadSuppliers();
    showToast("Supplier company removed.");
  }

  async function createBatch(event) {
    event.preventDefault();
    setMessage();
    if (!form.checkValidity()) { form.reportValidity(); return; }

    const receivedQuantity = Number.parseInt(quantity.value, 10);
    if (!Number.isInteger(receivedQuantity) || receivedQuantity < 1) {
      setMessage("Enter a quantity received of at least 1.");
      return;
    }

    setBusy(submit, true, "Saving receipt...");
    const { data, error } = await api().rpc("create_simple_stock_entry_batch", {
      p_stock_channel_id: channel.value,
      p_supplier_id: supplier.value,
      p_quantity: receivedQuantity,
      p_receiving_notes: text(notes.value)
    });
    setBusy(submit, false, "Saving receipt...");
    if (error) { setMessage(error.message || "The receipt could not be saved."); return; }

    const batch = data?.[0];
    const receiptCode = supplierCodeDisplay.value || batch?.supplier_code || "Supplier receipt";
    setMessage(`${receiptCode} saved with ${batch?.planned_quantity || receivedQuantity} devices. Opening IMEI Entry.`, "success");
    window.setTimeout(() => window.location.assign(`imei-entry.html?batch=${encodeURIComponent(batch.batch_id)}`), 450);
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: session } = await api().auth.getSession();
    if (!session.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await api().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "rma"] });
    if (error) throw error;
    if (!allowed) throw new Error("Your account does not have Stock Received permission.");
    if (window.GREENLOOP_ACCESS_READY) await window.GREENLOOP_ACCESS_READY;
    await Promise.all([loadChannels(), loadSuppliers()]);
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#add-supplier").addEventListener("click", openSupplierDialog);
  document.querySelector("#remove-supplier").addEventListener("click", () => removeSupplier().catch((error) => setMessage(error.message || "Supplier company could not be removed.")));
  document.querySelector("#close-supplier-dialog").addEventListener("click", () => supplierDialog.close());
  document.querySelector("#cancel-supplier").addEventListener("click", () => supplierDialog.close());
  supplierForm.addEventListener("submit", saveNewSupplier);
  supplier.addEventListener("change", updateSupplierCode);
  quantity.addEventListener("input", updateSupplierCode);
  form.addEventListener("submit", createBatch);
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Stock Received could not be loaded."; permissionMessage.hidden = false; form.hidden = true; });
})();
