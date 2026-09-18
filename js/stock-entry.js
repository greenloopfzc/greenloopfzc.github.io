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
  let savingReceipt = false;
  let savingSupplier = false;

  function api() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
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
    if (typeof window.GREENLOOP_PARTNER_LABEL === "function") return window.GREENLOOP_PARTNER_LABEL(record?.supplier_code, record?.company_name, "Supplier");
    return record?.supplier_code || "Supplier";
  }

  async function loadSuppliers(selectedId = supplier.value) {
    const { data, error } = await api().from("greenloop_suppliers").select("id, supplier_code, company_name").eq("is_active", true).is("deleted_at", null).order("company_name");
    if (error) throw error;
    supplierRecords = data || [];
    supplier.replaceChildren(new Option("Select supplier company", ""));
    supplierRecords.forEach((record) => supplier.add(new Option(supplierCompanyLabel(record), record.id)));
    if ([...supplier.options].some((option) => option.value === selectedId)) supplier.value = selectedId;
    updateSupplierCode();
  }

  function updateSupplierCode() {
    const selected = supplierRecords.find((record) => String(record.id) === String(supplier.value));
    const receivedQuantity = Number(quantity.value);
    supplierCodeDisplay.value = selected?.supplier_code && Number.isInteger(receivedQuantity) && receivedQuantity > 0
      ? (typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function"
        ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(selected.supplier_code, receivedQuantity, selected.company_name, "")
        : `${selected.supplier_code}-(${receivedQuantity})`)
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
    if (savingSupplier) return;
    setSupplierMessage();
    if (!supplierForm.checkValidity()) { supplierForm.reportValidity(); return; }
    savingSupplier = true;
    setBusy(saveSupplier, true, "Saving...");
    let saved = false;
    try {
    let result = await api().rpc("create_supplier_from_company", { p_company_name: supplierCompanyName.value });
    if (result.error && /create_supplier_from_company|function.*does not exist|PGRST202/i.test(result.error.message || "")) {
      result = await api().rpc("create_supplier", {
        p_company_name: supplierCompanyName.value,
        p_contact_name: "",
        p_phone: "",
        p_email: "",
        p_country: "",
        p_notes: ""
      });
    }
    const { data, error } = result;
    if (error) { setSupplierMessage(error.message || "Supplier company could not be saved."); return; }
    saved = true;
    supplierDialog.close();
    await loadSuppliers(data?.[0]?.id);
    showToast("Supplier company saved.");
    } catch (error) {
      if (saved) setMessage("Supplier company was saved, but the list could not refresh. Refresh this page before continuing.");
      else setSupplierMessage(error.message || "Supplier company could not be saved.");
    } finally {
      savingSupplier = false;
      setBusy(saveSupplier, false, "Saving...");
    }
  }

  async function removeSupplier() {
    if (!supplier.value) { setMessage("Select a supplier company before removing it."); return; }
    const selected = supplierRecords.find((record) => String(record.id) === String(supplier.value));
    const code = window.prompt(`Enter deletion code to remove ${supplierCompanyLabel(selected)}:`);
    if (code !== "1213") { showToast("Supplier company was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("archive_supplier_company", { p_supplier_id: supplier.value, p_deletion_code: code });
    if (error) { setMessage(error.message || "Supplier company could not be removed."); return; }
    await loadSuppliers();
    showToast("Supplier company removed from new receipts. History is retained.");
  }

  async function createBatch(event) {
    event.preventDefault();
    if (savingReceipt) return;
    setMessage();
    if (!form.checkValidity()) { form.reportValidity(); return; }

    const receivedQuantity = Number(quantity.value);
    if (!Number.isInteger(receivedQuantity) || receivedQuantity < 1) {
      setMessage("Enter a quantity received of at least 1.");
      return;
    }

    savingReceipt = true;
    setBusy(submit, true, "Saving receipt...");
    let saved = false;
    try {
    const { data, error } = await api().rpc("create_simple_stock_entry_batch", {
      p_stock_channel_id: channel.value,
      p_supplier_id: supplier.value,
      p_quantity: receivedQuantity,
      p_receiving_notes: text(notes.value)
    });
    if (error) { setMessage(error.message || "The receipt could not be saved."); return; }

    const batch = data?.[0];
    saved = true;
    if (!batch?.batch_id) { setMessage("The receipt was saved, but its reference could not be loaded. Open IMEI Entry to select the receipt; do not save it again.", "success"); return; }
    const receiptCode = supplierCodeDisplay.value || batch?.supplier_code || "Supplier receipt";
    setMessage(`${receiptCode} saved with ${batch?.planned_quantity || receivedQuantity} devices. Invoice ${batch?.invoice_number || "generated"}. Opening IMEI Entry.`, "success");
    window.setTimeout(() => window.location.assign(`imei-entry.html?batch=${encodeURIComponent(batch.batch_id)}`), 450);
    } catch (error) {
      setMessage(error.message || "The receipt could not be saved. Please check your connection.");
    } finally {
      if (!saved) { savingReceipt = false; setBusy(submit, false, "Saving receipt..."); }
    }
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
