(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const form = document.querySelector("#imei-entry-form");
  const batchSelect = document.querySelector("#stock-batch");
  const batchSummary = document.querySelector("#batch-summary");
  const detailPanel = document.querySelector("#imei-detail-panel");
  const actions = document.querySelector("#imei-actions");
  const imei = document.querySelector("#imei-1");
  const model = document.querySelector("#model");
  const storage = document.querySelector("#storage-gb");
  const color = document.querySelector("#color");
  const battery = document.querySelector("#battery-health");
  const message = document.querySelector("#form-message");
  const submit = document.querySelector("#save-imei");
  const permissionMessage = document.querySelector("#permission-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const autoSaveToggle = document.querySelector("#auto-save-toggle");
  const autoSaveState = document.querySelector("#auto-save-state");
  const readerStatus = document.querySelector("#device-reader-status");
  const requestedBatchId = new URLSearchParams(window.location.search).get("batch");
  let client;
  let toastTimer;
  let batches = [];
  let autoSaveTimer;
  let saving = false;

  function withTimeout(promise, label, milliseconds = 15000) {
    let timeoutId;
    const timeout = new Promise((_, reject) => {
      timeoutId = window.setTimeout(() => reject(new Error(`${label} timed out. Please refresh the page.`)), milliseconds);
    });
    return Promise.race([promise, timeout]).finally(() => window.clearTimeout(timeoutId));
  }

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(value) { window.clearTimeout(toastTimer); toast.textContent = value; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function setMessage(value = "", type = "error") { message.textContent = value; message.classList.toggle("is-visible", Boolean(value)); message.classList.toggle("is-success", type === "success"); }
  function setBusy(button, busy, label) { if (busy) button.dataset.label = button.textContent; button.disabled = busy; button.textContent = busy ? label : (button.dataset.label || button.textContent); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function supplierLabel(batch) {
    const code = String(batch?.supplier_code || "").trim();
    const name = String(batch?.supplier_name || "").trim();
    return (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && name ? [code, name].filter(Boolean).join(" - ") : code) || "No supplier";
  }

  function autoSaveEnabled() { return localStorage.getItem("greenloop-imei-auto-save") === "on"; }
  function syncAutoSaveControl() {
    const enabled = autoSaveEnabled();
    if (autoSaveToggle) autoSaveToggle.checked = enabled;
    if (autoSaveState) autoSaveState.textContent = enabled ? "ON" : "OFF";
  }
  function ensureSelectValue(select, value) {
    const text = String(value ?? "").trim();
    if (!text) return;
    if (![...select.options].some((option) => option.value.toLocaleLowerCase() === text.toLocaleLowerCase())) select.add(new Option(text, text));
    const match = [...select.options].find((option) => option.value.toLocaleLowerCase() === text.toLocaleLowerCase());
    if (match) select.value = match.value;
  }

  const masterFields = [
    ["model", model, "Select model"],
    ["storage_gb", storage, "Select GB"],
    ["color", color, "Select color"]
  ];

  async function loadMaster(group, select, placeholder, selected = select.value) {
    const { data, error } = await api().rpc("get_entry_options", { p_option_group: group });
    if (error) throw error;
    select.replaceChildren(new Option(placeholder, ""));
    (data || []).forEach((item) => { const option = new Option(item.option_value, item.option_value); option.dataset.optionId = item.id; select.add(option); });
    if ([...select.options].some((option) => option.value === String(selected))) select.value = String(selected);
  }

  async function loadAllMaster() { await Promise.all(masterFields.map(([group, select, placeholder]) => loadMaster(group, select, placeholder))); }

  async function addOption(button) {
    const group = button.dataset.optionGroup;
    const target = document.querySelector(`#${button.dataset.optionTarget}`);
    const value = window.prompt(`Enter the new ${group.replaceAll("_", " ")}:`);
    if (!value?.trim()) return;
    const { data, error } = await api().rpc("add_entry_option", { p_option_group: group, p_option_value: value.trim() });
    if (error) { setMessage(error.message || "The option could not be added."); return; }
    const field = masterFields.find(([itemGroup, select]) => itemGroup === group && select === target);
    await loadMaster(group, target, field[2], data?.[0]?.saved_value || value.trim());
    showToast("Option saved.");
  }

  async function removeOption(button) {
    const group = button.dataset.optionGroup;
    const target = document.querySelector(`#${button.dataset.optionTarget}`);
    const optionId = target.selectedOptions[0]?.dataset.optionId;
    if (!optionId) { setMessage("Select an option before removing it."); return; }
    const code = window.prompt("Enter deletion code to remove this option:");
    if (code !== "1213") { showToast("Option was not removed. Deletion code is incorrect."); return; }
    const { error } = await api().rpc("delete_entry_option", { p_option_id: optionId, p_deletion_code: code });
    if (error) { setMessage(error.message || "The option could not be removed."); return; }
    const field = masterFields.find(([itemGroup, select]) => itemGroup === group && select === target);
    await loadMaster(group, target, field[2]);
    showToast("Option removed.");
  }

  async function loadBatches(selected = batchSelect.value || requestedBatchId) {
    batchSelect.disabled = true;
    batchSelect.replaceChildren(new Option("Loading stock batches...", ""));

    let response;
    try {
      response = await withTimeout(
        api().rpc("get_open_stock_entry_batches_with_lines"),
        "Stock batch loading"
      );
    } catch (error) {
      batchSelect.replaceChildren(new Option("Stock batches could not be loaded", ""));
      throw error;
    }

    if (response.error) {
      const fallback = await withTimeout(
        api().rpc("get_open_stock_entry_batches"),
        "Stock batch fallback loading"
      );
      if (fallback.error) {
        batchSelect.replaceChildren(new Option("Stock batches could not be loaded", ""));
        throw response.error;
      }
      batches = (fallback.data || []).map((batch) => ({
        ...batch,
        planned_label: batch.planned_model || "Stock batch",
        planned_lines: []
      }));
    } else {
      batches = response.data || [];
    }

    batchSelect.replaceChildren(new Option(batches.length ? "Select supplier code / batch" : "No incomplete stock batches", ""));
    batches.forEach((batch) => batchSelect.add(new Option(`${supplierLabel(batch)} - ${batch.planned_label} - ${batch.remaining_quantity} remaining`, batch.batch_id)));
    if (batches.some((batch) => batch.batch_id === selected)) batchSelect.value = selected;
    else batchSelect.value = "";
    batchSelect.disabled = false;
    updateBatchView();
  }

  function updateBatchView() {
    const batch = batches.find((item) => item.batch_id === batchSelect.value);
    const available = Boolean(batch);
    detailPanel.hidden = !available;
    actions.hidden = !available;
    batchSummary.hidden = !available;
    if (!batch) return;
    const plannedLines = Array.isArray(batch.planned_lines) ? batch.planned_lines : [];
    const nextLine = plannedLines.find((line) => Number(line.remaining_quantity) > 0) || plannedLines[0];
    const planText = plannedLines.length
      ? plannedLines.map((line) => `${line.model || "Any model"} · ${line.storage_gb ? `${line.storage_gb} GB` : "Any GB"} · ${line.color || "Any color"} (${line.remaining_quantity}/${line.planned_quantity} remaining)`).join(" | ")
      : batch.planned_label;
    batchSummary.innerHTML = [
      ["Supplier code", supplierLabel(batch)], ["Stock channel", batch.stock_channel],
      ["Stock plan", batch.planned_label], ["Progress", `${batch.entered_quantity} / ${batch.planned_quantity}`],
      ["Remaining", batch.remaining_quantity]
    ].map(([label, value]) => `<div><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join("") + `<div class="batch-plan-lines" title="${escapeHtml(planText)}"><span>Model / GB / Color plan</span><strong>${escapeHtml(planText)}</strong></div>`;
    if (nextLine) {
      const setValue = (select, value) => {
        if (![...select.options].some((option) => option.value === String(value))) select.add(new Option(value, value));
        select.value = String(value);
      };
      if (nextLine.model) setValue(model, nextLine.model);
      if (nextLine.storage_gb) setValue(storage, nextLine.storage_gb);
      if (nextLine.color) setValue(color, nextLine.color);
    } else if (batch.planned_label) {
      if (![...model.options].some((option) => option.value === batch.planned_label)) model.add(new Option(batch.planned_label, batch.planned_label));
      model.value = batch.planned_label;
    }
    imei.focus();
    if (window.GREENLOOP_LAST_DEVICE) applyConnectedDevice(window.GREENLOOP_LAST_DEVICE);
  }

  function applyConnectedDevice(device = {}) {
    if (!batchSelect.value) {
      if (readerStatus) readerStatus.textContent = "Phone detected — select a stock batch";
      return;
    }
    imei.value = String(device.imei || "").replace(/\D/g, "").slice(0, 15);
    ensureSelectValue(model, device.model);
    ensureSelectValue(storage, device.storageGb);
    ensureSelectValue(color, device.color);
    if (device.batteryHealth !== "" && Number.isFinite(Number(device.batteryHealth))) {
      battery.value = Number(device.batteryHealth);
    }
    const missing = [
      [/^\d{15}$/.test(imei.value.trim()), "IMEI"],
      [Boolean(model.value), "Model"],
      [Boolean(storage.value), "GB"],
      [Boolean(color.value), "Color"],
      [battery.value !== "" && Number.isFinite(Number(battery.value)), "Battery Health"]
    ].filter(([available]) => !available).map(([, label]) => label);
    if (missing.length) {
      if (readerStatus) readerStatus.textContent = `Cable read incomplete: ${missing.join(", ")}`;
      setMessage(`Connected phone detected, but ${missing.join(", ")} could not be read.`, "error");
      return;
    }
    if (readerStatus) readerStatus.textContent = "Connected phone loaded";
    setMessage("Connected phone data loaded. Review it, then save.", "success");
    if (autoSaveEnabled()) scheduleAutoSave();
  }

  function canAutoSave() {
    return Boolean(
      batches.some((item) => item.batch_id === batchSelect.value) &&
      /^\d{15}$/.test(imei.value.trim()) &&
      model.value && storage.value && color.value &&
      battery.value !== "" && Number(battery.value) >= 0 && Number(battery.value) <= 100
    );
  }

  function scheduleAutoSave() {
    window.clearTimeout(autoSaveTimer);
    if (!autoSaveEnabled()) return;
    if (!canAutoSave() || battery.value.length < 2) return;
    autoSaveTimer = window.setTimeout(() => saveImei(null, true), 650);
  }

  async function saveImei(event, automatic = false) {
    event?.preventDefault();
    window.clearTimeout(autoSaveTimer);
    if (saving) return;
    if (automatic && !canAutoSave()) return;
    setMessage();
    const batch = batches.find((item) => item.batch_id === batchSelect.value);
    if (!batch) { setMessage("Select a supplier-code stock batch first."); return; }
    if (!form.checkValidity()) { form.reportValidity(); return; }
    const scannedImei = imei.value.trim();
    if (!/^\d{15}$/.test(scannedImei)) { setMessage("IMEI must contain exactly 15 digits."); return; }
    saving = true;
    setBusy(submit, true, automatic ? "Saving automatically..." : "Saving IMEI...");
    const { data, error } = await api().rpc("receive_stock_batch_imei_with_plan", {
      p_batch_id: batch.batch_id,
      p_imei_1: scannedImei,
      p_model: model.value,
      p_storage_gb: Number(storage.value),
      p_color: color.value,
      p_battery_health: Number(battery.value)
    });
    setBusy(submit, false, "Saving IMEI...");
    saving = false;
    if (error) { setMessage(error.message || "The IMEI could not be saved."); return; }
    const result = data?.[0];
    setMessage(`IMEI saved. ${result?.entered_quantity || 0} of ${result?.planned_quantity || batch.planned_quantity} devices entered and sent to Initial QC.`, "success");
    sessionStorage.setItem("greenloop-next-initial-qc-imei", scannedImei);
    imei.value = "";
    battery.value = "";
    imei.focus();
    if (Number(result?.remaining_quantity) === 0) showToast("This stock batch is complete. All IMEIs are in Initial QC.");
    await loadBatches(Number(result?.remaining_quantity) === 0 ? "" : batch.batch_id);
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: session } = await withTimeout(api().auth.getSession(), "Login check");
    if (!session.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await withTimeout(
      api().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "rma"] }),
      "Permission check"
    );
    if (error) throw error;
    if (!allowed) throw new Error("Your account does not have IMEI Entry permission.");
    const [masterResult, batchResult] = await Promise.allSettled([
      loadAllMaster(),
      loadBatches(requestedBatchId)
    ]);
    if (batchResult.status === "rejected") throw batchResult.reason;
    if (masterResult.status === "rejected") {
      setMessage(`Stock batches loaded, but dropdown options could not load: ${masterResult.reason?.message || "Unknown error"}`);
    }
    syncAutoSaveControl();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  batchSelect.addEventListener("change", updateBatchView);
  imei.addEventListener("input", () => { imei.value = imei.value.replace(/\D/g, ""); });
  battery.addEventListener("input", scheduleAutoSave);
  battery.addEventListener("change", scheduleAutoSave);
  battery.addEventListener("blur", scheduleAutoSave);
  battery.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      saveImei(null, false);
    }
  });
  document.querySelectorAll(".master-add").forEach((button) => button.addEventListener("click", () => addOption(button)));
  document.querySelectorAll(".master-remove").forEach((button) => button.addEventListener("click", () => removeOption(button)));
  form.addEventListener("submit", saveImei);
  autoSaveToggle?.addEventListener("change", () => {
    localStorage.setItem("greenloop-imei-auto-save", autoSaveToggle.checked ? "on" : "off");
    syncAutoSaveControl();
    if (autoSaveToggle.checked) scheduleAutoSave();
  });
  window.addEventListener("greenloop:device", (event) => {
    applyConnectedDevice(event.detail || {});
  });
  initialize().catch((error) => {
    batchSelect.disabled = false;
    if (batchSelect.options[0]?.textContent === "Loading stock batches...") {
      batchSelect.replaceChildren(new Option("Stock batches could not be loaded", ""));
    }
    permissionMessage.textContent = error.message || "IMEI Entry could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
