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
  const readConnectedIphone = document.querySelector("#read-connected-iphone");
  const autoReadIphone = document.querySelector("#auto-read-iphone");
  const autoReadStatus = document.querySelector("#iphone-auto-status");
  const permissionMessage = document.querySelector("#permission-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedBatchId = new URLSearchParams(window.location.search).get("batch");
  let client;
  let toastTimer;
  let batches = [];
  let autoSaveTimer;
  let saving = false;
  let autoReadTimer;
  let readerRequestBusy = false;
  const autoReadSessionImeis = new Set();
  const autoReadStorageKey = "greenloop-auto-read-iphone";

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(value) { window.clearTimeout(toastTimer); toast.textContent = value; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function setMessage(value = "", type = "error") { message.textContent = value; message.classList.toggle("is-visible", Boolean(value)); message.classList.toggle("is-success", type === "success"); }
  function setBusy(button, busy, label) { if (busy) button.dataset.label = button.textContent; button.disabled = busy; button.textContent = busy ? label : (button.dataset.label || button.textContent); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function supplierLabel(batch) { return String(batch?.supplier_code || batch?.supplier_name || "").trim() || "No supplier"; }

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
    const { data, error } = await api().rpc("get_open_stock_entry_batches_with_lines");
    if (error) throw error;
    batches = data || [];
    batchSelect.replaceChildren(new Option(batches.length ? "Select supplier code / batch" : "No incomplete stock batches", ""));
    batches.forEach((batch) => batchSelect.add(new Option(`${supplierLabel(batch)} - ${batch.planned_label} - ${batch.remaining_quantity} remaining`, batch.batch_id)));
    if (batches.some((batch) => batch.batch_id === selected)) batchSelect.value = selected;
    else batchSelect.value = "";
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
  }

  function canAutoSave() {
    return Boolean(
      batches.some((item) => item.batch_id === batchSelect.value) &&
      /^\d{15}$/.test(imei.value.trim()) &&
      model.value && storage.value && color.value &&
      battery.value !== "" && Number(battery.value) >= 0 && Number(battery.value) <= 100
    );
  }

  function normaliseValue(value) {
    return String(value || "").trim().replace(/\s+/g, " ").toLocaleLowerCase();
  }

  function setScannerSelectValue(select, value) {
    const cleaned = String(value || "").trim();
    if (!cleaned) return false;
    const matchingOption = [...select.options].find((option) => normaliseValue(option.value) === normaliseValue(cleaned));
    if (matchingOption) {
      select.value = matchingOption.value;
      return true;
    }
    select.add(new Option(cleaned, cleaned));
    select.value = cleaned;
    return true;
  }

  function recognisedColor(value) {
    const raw = String(value || "").trim();
    if (!raw || raw.startsWith("#") || /^\d+$/.test(raw)) return "";
    return raw.replace(/[-_]/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  }

  function setAutoReadStatus(value, state = "") {
    if (!autoReadStatus) return;
    autoReadStatus.textContent = value;
    autoReadStatus.classList.toggle("is-active", state === "active");
    autoReadStatus.classList.toggle("is-warning", state === "warning");
  }

  function updateAutoReadAppearance() {
    autoReadIphone.closest(".iphone-auto-read")?.classList.toggle("is-active", autoReadIphone.checked);
    if (!autoReadIphone.checked) setAutoReadStatus("Auto read off");
  }

  async function requestCableDevice(timeoutMs = 15000) {
    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), timeoutMs);
    try {
      const response = await fetch(`http://127.0.0.1:51892/v1/device?t=${Date.now()}`, { cache: "no-store", signal: abort.signal });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) throw new Error(result.message || "The connected iPhone could not be read.");
      return result.device || {};
    } finally {
      window.clearTimeout(timer);
    }
  }

  function applyCableDevice(device, automatic = false) {
    const scannedImei = String(device.imei || "").replace(/\D/g, "");
    const bulkPanel = document.querySelector("#batch-entry-panel:not([hidden])");
    if (bulkPanel) {
      window.dispatchEvent(new CustomEvent("greenloop:cable-device", { detail: device }));
      setMessage(`${automatic ? "Auto Read" : "Connected iPhone"} data loaded into the active batch line.`, "success");
      return scannedImei;
    }
    const loaded = [];
    if (/^\d{15}$/.test(scannedImei)) { imei.value = scannedImei; loaded.push("IMEI"); }
    if (setScannerSelectValue(model, device.model)) loaded.push("model");
    if (device.storageGb && Number(device.storageGb) > 0) { setScannerSelectValue(storage, String(Number(device.storageGb))); loaded.push("GB"); }
    if (setScannerSelectValue(color, recognisedColor(device.color))) loaded.push("color");
    const batteryHealth = Number.parseInt(String(device.batteryHealth || "").replace(/\D/g, ""), 10);
    if (Number.isInteger(batteryHealth) && batteryHealth >= 1 && batteryHealth <= 100) {
      battery.value = String(batteryHealth);
      loaded.push("Battery Health");
    }
    if (!loaded.length) throw new Error("The iPhone was connected, but it did not provide usable device details. Unlock it, tap Trust, then try again.");
    const stillNeeded = [
      device.storageGb ? "" : "GB",
      recognisedColor(device.color) ? "" : "Color",
      (Number.isInteger(batteryHealth) && batteryHealth >= 1 && batteryHealth <= 100) ? "" : "Battery Health"
    ].filter(Boolean);
    const followUp = stillNeeded.length ? ` The iPhone did not expose ${stillNeeded.join(", ")} to Apple Mobile Device Support.` : " The IMEI will save automatically.";
    setMessage(`${loaded.join(", ")} loaded from the connected iPhone.${followUp}`, "success");
    if (stillNeeded.length) battery.focus();
    else scheduleAutoSave();
    return scannedImei;
  }

  async function readFrom3uTools() {
    setMessage();
    setBusy(readConnectedIphone, true, "Reading 3uTools...");
    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), 12000);
    try {
      const response = await fetch(`http://127.0.0.1:51894/v1/device?t=${Date.now()}`, { cache: "no-store", signal: abort.signal });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) throw new Error(result.message || "3uTools could not be read.");
      const device = result.device || {};
      const scannedImei = String(device.imei || "").replace(/\D/g, "");
      const loaded = [];
      if (/^\d{15}$/.test(scannedImei)) { imei.value = scannedImei; loaded.push("IMEI"); }
      if (setScannerSelectValue(model, device.model)) loaded.push("model");
      if (device.storageGb && Number(device.storageGb) > 0) { setScannerSelectValue(storage, String(Number(device.storageGb))); loaded.push("GB"); }
      if (setScannerSelectValue(color, recognisedColor(device.color))) loaded.push("color");
      const batteryHealth = Number.parseInt(String(device.batteryHealth || "").replace(/\D/g, ""), 10);
      if (Number.isInteger(batteryHealth) && batteryHealth >= 1 && batteryHealth <= 100) { battery.value = String(batteryHealth); loaded.push("Battery Health"); }
      if (!loaded.length) throw new Error("3uTools was read, but no usable device details were found. Keep its iDevice page visible and press Refresh in 3uTools.");
      const missing = [!device.storageGb && "GB", !recognisedColor(device.color) && "Color", !(Number.isInteger(batteryHealth) && batteryHealth >= 1 && batteryHealth <= 100) && "Battery Health"].filter(Boolean);
      setMessage(`${loaded.join(", ")} loaded from 3uTools.${missing.length ? ` 3uTools could not read ${missing.join(", ")} from the visible screen.` : " The IMEI will save automatically."}`, missing.length ? "error" : "success");
      if (missing.length) battery.focus(); else scheduleAutoSave();
    } catch (error) {
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      setMessage(offline
        ? "Start the Greenloop 3uTools Bridge first. Keep 3uTools open, maximized, and on the iDevice screen."
        : (error.message || "3uTools could not be read."));
    } finally {
      window.clearTimeout(timer);
      setBusy(readConnectedIphone, false, "Reading 3uTools...");
    }
  }

  async function readIphoneFromCable(automatic = false) {
    if (readerRequestBusy) return;
    readerRequestBusy = true;
    if (!automatic) setMessage();
    if (!automatic) setBusy(readConnectedIphone, true, "Reading iPhone...");
    try {
      const device = await requestCableDevice(automatic ? 5500 : 15000);
      const scannedImei = String(device.imei || "").replace(/\D/g, "");
      if (automatic && !/^\d{15}$/.test(scannedImei)) {
        setAutoReadStatus("Connected phone has no readable IMEI", "warning");
        return;
      }
      if (automatic && autoReadSessionImeis.has(scannedImei)) {
        setAutoReadStatus("Phone already loaded - connect the next iPhone", "active");
        return;
      }
      const appliedImei = applyCableDevice(device, automatic);
      if (/^\d{15}$/.test(appliedImei)) autoReadSessionImeis.add(appliedImei);
      setAutoReadStatus(automatic ? "iPhone loaded - connect the next iPhone" : "iPhone loaded", "active");
    } catch (error) {
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      if (automatic) {
        const noPhone = /no iphone detected|not trusted|unlock|connect/i.test(String(error?.message || ""));
        setAutoReadStatus(offline ? "Cable Reader is offline" : (noPhone ? "Waiting for iPhone" : "Reader waiting"), offline ? "warning" : "");
      } else {
        setMessage(offline
          ? "Start Greenloop iPhone Scanner first, then connect and trust the unlocked iPhone."
          : (error.message || "The connected iPhone could not be read."));
      }
    } finally {
      readerRequestBusy = false;
      if (!automatic) setBusy(readConnectedIphone, false, "Reading iPhone...");
    }
  }

  async function autoReadTick() {
    if (!autoReadIphone.checked || document.hidden || readerRequestBusy) return;
    if (!batchSelect.value) { setAutoReadStatus("Select supplier batch first", "warning"); return; }
    const activeBatchPanel = document.querySelector("#batch-entry-panel:not([hidden])");
    if (!activeBatchPanel) { setAutoReadStatus("Preparing batch lines"); return; }
    if (!activeBatchPanel.querySelector("tbody tr:not(.batch-saved-row)")) { setAutoReadStatus("No empty batch line", "warning"); return; }
    await readIphoneFromCable(true);
  }

  function startAutoRead() {
    window.clearInterval(autoReadTimer);
    updateAutoReadAppearance();
    if (!autoReadIphone.checked) return;
    setAutoReadStatus(batchSelect.value ? "Waiting for iPhone" : "Select supplier batch first", batchSelect.value ? "" : "warning");
    autoReadTimer = window.setInterval(autoReadTick, 1200);
    autoReadTick();
  }

  function configureAutoRead() {
    autoReadIphone.checked = window.localStorage.getItem(autoReadStorageKey) === "on";
    startAutoRead();
  }

  function scheduleAutoSave() {
    window.clearTimeout(autoSaveTimer);
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
    const { data: session } = await api().auth.getSession();
    if (!session.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await api().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "rma"] });
    if (error) throw error;
    if (!allowed) throw new Error("Your account does not have IMEI Entry permission.");
    await loadAllMaster();
    await loadBatches(requestedBatchId);
    configureAutoRead();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  batchSelect.addEventListener("change", () => { updateBatchView(); if (autoReadIphone.checked) window.setTimeout(autoReadTick, 150); });
  readConnectedIphone.addEventListener("click", () => readIphoneFromCable(false));
  autoReadIphone.addEventListener("change", () => {
    window.localStorage.setItem(autoReadStorageKey, autoReadIphone.checked ? "on" : "off");
    startAutoRead();
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && autoReadIphone.checked) autoReadTick(); });
  window.addEventListener("beforeunload", () => window.clearInterval(autoReadTimer));
  imei.addEventListener("input", () => { imei.value = imei.value.replace(/\D/g, ""); });
  battery.addEventListener("input", scheduleAutoSave);
  battery.addEventListener("change", () => saveImei(null, true));
  battery.addEventListener("blur", () => saveImei(null, true));
  battery.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      saveImei(null, true);
    }
  });
  document.querySelectorAll(".master-add").forEach((button) => button.addEventListener("click", () => addOption(button)));
  document.querySelectorAll(".master-remove").forEach((button) => button.addEventListener("click", () => removeOption(button)));
  form.addEventListener("submit", saveImei);
  initialize().catch((error) => { permissionMessage.textContent = error.message || "IMEI Entry could not be loaded."; permissionMessage.hidden = false; form.hidden = true; });
})();
