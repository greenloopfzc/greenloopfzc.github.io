(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#inventory-app");
  const permissionMessage = document.querySelector("#permission-message");
  const form = document.querySelector("#inventory-receipt-form");
  const invoice = document.querySelector("#receipt-invoice");
  const origin = document.querySelector("#receipt-origin");
  const sku = document.querySelector("#receipt-sku");
  const partName = document.querySelector("#receipt-part-name");
  const quantity = document.querySelector("#receipt-quantity");
  const totalCost = document.querySelector("#receipt-total-cost");
  const unitCost = document.querySelector("#receipt-unit-cost");
  const notes = document.querySelector("#receipt-notes");
  const message = document.querySelector("#receipt-message");
  const stockList = document.querySelector("#inventory-stock-list");
  const receiptList = document.querySelector("#inventory-receipt-list");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let toastTimer;

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function money(value) { return `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`; }
  function dateTime(value) { return value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—"; }
  function setMessage(text = "", success = false) { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); message.classList.toggle("is-success", success); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3600); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }

  function updateUnitCost() {
    const receivedQuantity = Number(quantity.value || 0);
    const receivedTotal = Number(totalCost.value || 0);
    unitCost.textContent = receivedQuantity > 0 ? money(receivedTotal / receivedQuantity) : "AED 0.00";
  }

  function automaticSku() {
    const safePart = partName.value.trim().toUpperCase().replace(/[^A-Z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    const safeInvoice = invoice.value.trim().toUpperCase().replace(/[^A-Z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    return `PART-${safePart}-${safeInvoice}`;
  }

  function missingInventoryFunction(error) {
    const text = String(error?.message || "").toLowerCase();
    return error?.code === "PGRST202" || (text.includes("could not find the function public.") && text.includes("part_inventory"));
  }

  function legacyReceiptDetails(row) {
    const notesText = String(row.notes || "");
    const invoiceMatch = notesText.match(/\[Inventory invoice:\s*([^|\]]+)/i);
    const originMatch = notesText.match(/\|\s*Origin:\s*([^\]]+)/i);
    return {
      invoice: invoiceMatch?.[1]?.trim() || "--",
      origin: originMatch?.[1]?.trim() || "--"
    };
  }

  async function loadPartNames(selected = partName.value) {
    const { data, error } = await api().rpc("get_entry_options", { p_option_group: "part_name" });
    if (error) throw error;
    partName.replaceChildren(new Option("Select part name", ""));
    (data || []).forEach((item) => {
      const option = new Option(item.option_value, item.option_value);
      option.dataset.optionId = item.id;
      partName.add(option);
    });
    if ([...partName.options].some((option) => option.value === selected)) partName.value = selected;
  }

  async function addPartName() {
    const value = window.prompt("Enter the new part name:");
    if (!value?.trim()) return;
    const { data, error } = await api().rpc("add_entry_option", { p_option_group: "part_name", p_option_value: value.trim() });
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    await loadPartNames(row?.saved_value || value.trim());
    showToast("Part name saved.");
  }

  async function removePartName() {
    const optionId = partName.selectedOptions[0]?.dataset.optionId;
    if (!optionId) { setMessage("Select a part name before removing it."); return; }
    const code = window.prompt("Enter deletion code to remove this part name:");
    if (code !== "1213") { showToast("Part name was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("delete_entry_option", { p_option_id: optionId, p_deletion_code: code });
    if (error) throw error;
    await loadPartNames();
    showToast("Part name removed.");
  }

  function renderStock(rows) {
    stockList.innerHTML = rows.length
      ? rows.map((row) => `<tr><td>${escapeHtml(row.sku)}</td><td><strong>${escapeHtml(row.part_name)}</strong></td><td>${Number(row.total_received||0).toLocaleString()}</td><td>${Number(row.stock_quantity||0).toLocaleString()}</td><td>${Number(row.used_in_phones||0).toLocaleString()}</td><td>${Number(row.damaged_quantity||0).toLocaleString()}</td><td>${Number(row.faulty_quantity||0).toLocaleString()}</td><td>${Number(row.issued_pending||0).toLocaleString()}</td><td>${money(row.unit_cost)}</td><td>${money(row.stock_value)}</td><td>${escapeHtml(row.last_invoice_number||"—")}</td><td class="history-origin">${escapeHtml(row.last_origin||"—")}</td><td>${dateTime(row.last_received_at)}</td></tr>`).join("")
      : '<tr><td colspan="13" class="inventory-empty">No parts have been received yet.</td></tr>';
    document.querySelector("#stat-part-types").textContent = rows.length.toLocaleString();
    document.querySelector("#stat-units").textContent = rows.reduce((total, row) => total + Number(row.stock_quantity || 0), 0).toLocaleString();
    document.querySelector("#stat-value").textContent = money(rows.reduce((total, row) => total + Number(row.stock_value || 0), 0));
    const latest = [...rows].sort((a, b) => new Date(b.last_received_at || 0) - new Date(a.last_received_at || 0))[0];
    document.querySelector("#stat-latest").textContent = latest ? `${latest.part_name} · ${dateTime(latest.last_received_at)}` : "—";
  }

  function renderReceipts(rows) {
    receiptList.innerHTML = rows.length
      ? rows.map((row) => `<tr><td>${dateTime(row.received_at)}</td><td>${escapeHtml(row.receipt_number)}</td><td>${escapeHtml(row.invoice_number)}</td><td>${escapeHtml(row.sku)}</td><td>${escapeHtml(row.part_name)}</td><td class="history-origin">${escapeHtml(row.source_origin)}</td><td>${Number(row.quantity_received).toLocaleString()}</td><td>${money(row.total_cost)}</td><td>${money(row.unit_cost)}</td></tr>`).join("")
      : '<tr><td colspan="9" class="inventory-empty">No invoice receipt history yet.</td></tr>';
  }

  async function loadData() {
    const [stockResponse, receiptResponse] = await Promise.all([
      api().rpc("get_part_inventory_breakdown"),
      api().rpc("get_part_inventory_receipts", { p_limit: 150 })
    ]);
    if (missingInventoryFunction(stockResponse.error) || missingInventoryFunction(receiptResponse.error)) {
      throw new Error("Run the latest Greenloop database update first. Inventory totals are not shown from an unsafe fallback.");
    }
    if (stockResponse.error) throw stockResponse.error;
    if (receiptResponse.error) throw receiptResponse.error;
    renderStock(stockResponse.data || []);
    renderReceipts(receiptResponse.data || []);
  }

  async function saveThroughExistingParts() {
    const safeSku = (sku.value.trim() || automaticSku()).toUpperCase();
    const receivedQuantity = Number(quantity.value);
    const receivedTotal = Number(totalCost.value);
    const { data: currentRows, error: currentError } = await api()
      .from("part_inventory")
      .select("stock_quantity, unit_cost")
      .eq("sku", safeSku)
      .limit(1);
    if (currentError) throw currentError;
    const current = currentRows?.[0];
    const averageUnitCost = current
      ? ((Number(current.stock_quantity || 0) * Number(current.unit_cost || 0)) + receivedTotal) / (Number(current.stock_quantity || 0) + receivedQuantity)
      : receivedTotal / receivedQuantity;
    const noteText = `[Inventory invoice: ${invoice.value.trim()} | Origin: ${origin.value}]${notes.value.trim() ? ` ${notes.value.trim()}` : ""}`;
    const { error } = await api().rpc("add_part_inventory", {
      p_sku: safeSku,
      p_part_name: partName.value,
      p_stock_quantity: receivedQuantity,
      p_unit_cost: averageUnitCost,
      p_notes: noteText
    });
    if (error) throw error;
    return { part_name: partName.value, stock_quantity: Number(current?.stock_quantity || 0) + receivedQuantity, average_unit_cost: averageUnitCost };
  }

  async function saveReceipt(event) {
    event.preventDefault();
    setMessage();
    if (!form.checkValidity()) { form.reportValidity(); return; }
    const button = document.querySelector("#save-receipt");
    button.disabled = true;
    button.textContent = "Receiving...";
    let data;
    let error;
    ({ data, error } = await api().rpc("receive_part_inventory_with_invoice", {
      p_sku: sku.value.trim() || automaticSku(),
      p_part_name: partName.value,
      p_invoice_number: invoice.value.trim(),
      p_source_origin: origin.value,
      p_quantity_received: Number(quantity.value),
      p_total_cost: Number(totalCost.value),
      p_notes: notes.value.trim() || null
    }));
    if (missingInventoryFunction(error)) error = new Error("Run the latest Greenloop database update before receiving parts.");
    button.disabled = false;
    button.textContent = "Receive parts";
    if (error) { setMessage(error.message || "Inventory receipt could not be saved."); return; }
    const result = Array.isArray(data) ? data[0] : data;
    form.reset();
    origin.value = "local";
    updateUnitCost();
    setMessage(`${result?.part_name || "Part"} received. ${result?.stock_quantity || 0} units are now in stock at ${money(result?.average_unit_cost)} average cost.`, true);
    showToast("Inventory receipt saved. Parts can now be issued to Laboratory jobs.");
    await loadData();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: session } = await api().auth.getSession();
    if (!session.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await api().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "parts"] });
    if (error) throw error;
    if (!allowed) throw new Error("Your account does not have Inventory permission.");
    app.hidden = false;
    await Promise.all([loadPartNames(), loadData()]);
    updateUnitCost();
  }

  quantity.addEventListener("input", updateUnitCost);
  totalCost.addEventListener("input", updateUnitCost);
  form.addEventListener("submit", (event) => saveReceipt(event).catch((error) => setMessage(error.message || "Inventory receipt could not be saved.")));
  document.querySelector("#add-inventory-part-name").addEventListener("click", () => addPartName().catch((error) => setMessage(error.message || "Part name could not be added.")));
  document.querySelector("#remove-inventory-part-name").addEventListener("click", () => removePartName().catch((error) => setMessage(error.message || "Part name could not be removed.")));
  document.querySelector("#refresh-inventory").addEventListener("click", () => loadData().catch((error) => setMessage(error.message || "Inventory could not be refreshed.")));
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Inventory could not be loaded."; permissionMessage.hidden = false; });
})();
