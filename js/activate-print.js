(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const batchSelect = document.querySelector("#activate-batch");
  const batchSummary = document.querySelector("#activate-batch-summary");
  const readerStatus = document.querySelector("#reader-status");
  const homeScreenConfirm = document.querySelector("#home-screen-confirm");
  const homeScreenStatus = document.querySelector("#home-screen-status");
  const homeScreenCard = document.querySelector(".home-screen-confirm");
  const printButton = document.querySelector("#print-phone-label");
  const nextButton = document.querySelector("#next-activate-phone");
  const continueLinks = [document.querySelector("#continue-imei"), document.querySelector("#continue-imei-top")].filter(Boolean);
  const message = document.querySelector("#activate-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedBatchId = new URLSearchParams(window.location.search).get("batch");
  const fields = {
    imei: document.querySelector("#device-imei"), model: document.querySelector("#device-model"),
    storage: document.querySelector("#device-storage"), color: document.querySelector("#device-color"),
    battery: document.querySelector("#device-bh"), activation: document.querySelector("#device-activation")
  };
  const label = {
    barcode: document.querySelector("#imei-barcode"), model: document.querySelector("#label-model"),
    storage: document.querySelector("#label-storage"), color: document.querySelector("#label-color"),
    battery: document.querySelector("#label-bh")
  };

  let client;
  let batches = [];
  let currentDevice = null;
  let readerBusy = false;
  let autoReadTimer;
  let connectedDeviceKey = "";
  let activationInProgress = false;
  let activationCompletedDeviceKey = "";
  let activationBlockedDeviceKey = "";
  let nextActivationAttemptAt = 0;
  let toastTimer;

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function supplierLabel(batch) { return String(batch?.supplier_code || batch?.supplier_name || "").trim() || "No supplier"; }
  function setMessage(value = "", type = "error") {
    message.textContent = value;
    message.classList.toggle("is-visible", Boolean(value));
    message.classList.toggle("is-success", type === "success");
  }
  function setReaderStatus(value, state = "") {
    readerStatus.textContent = value;
    readerStatus.classList.toggle("is-ready", state === "ready");
    readerStatus.classList.toggle("is-warning", state === "warning");
  }
  function showToast(value) {
    window.clearTimeout(toastTimer);
    toast.textContent = value;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200);
  }
  function showActivationPopup({ title, popupMessage, type = "warning" }) {
    const popup = document.querySelector("#activation-popup");
    const popupTitle = document.querySelector("#activation-popup-title");
    const popupText = document.querySelector("#activation-popup-message");
    if (!popup || !popupTitle || !popupText) return;
    popup.className = `activation-popup is-${type}`;
    popupTitle.textContent = title;
    popupText.textContent = popupMessage;
    popup.hidden = false;
  }
  function closeActivationPopup() { document.querySelector("#activation-popup").hidden = true; }

  function updateContinueLinks() {
    const query = batchSelect.value ? `?batch=${encodeURIComponent(batchSelect.value)}` : "";
    continueLinks.forEach((link) => { link.href = `imei-entry.html${query}`; });
  }
  async function loadBatches() {
    const { data, error } = await api().rpc("get_open_stock_entry_batches_with_lines");
    if (error) throw error;
    batches = data || [];
    batchSelect.replaceChildren(new Option(batches.length ? "Select supplier code / batch" : "No incomplete stock batches", ""));
    batches.forEach((batch) => batchSelect.add(new Option(`${supplierLabel(batch)} · ${batch.planned_label} · ${batch.remaining_quantity} remaining`, batch.batch_id)));
    if (batches.some((batch) => batch.batch_id === requestedBatchId)) batchSelect.value = requestedBatchId;
    else if (batches.length === 1) batchSelect.value = batches[0].batch_id;
    updateBatchView();
  }
  function updateBatchView() {
    const batch = batches.find((item) => item.batch_id === batchSelect.value);
    batchSummary.hidden = !batch;
    if (batch) {
      batchSummary.innerHTML = [["Supplier", supplierLabel(batch)], ["Stock channel", batch.stock_channel], ["Stock plan", batch.planned_label], ["Remaining", `${batch.remaining_quantity} phones`]]
        .map(([name, value]) => `<div><span>${escapeHtml(name)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
    }
    updateContinueLinks();
    updatePrintReady();
  }

  function cleanColor(value) {
    const raw = String(value || "").trim();
    if (!raw || raw.startsWith("#") || /^\d+$/.test(raw)) return "";
    return raw.replace(/[-_]/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  }
  function normaliseDevice(raw = {}) {
    const imei = String(raw.imei || "").replace(/\D/g, "");
    const storage = Number.parseInt(String(raw.storageGb || "").replace(/\D/g, ""), 10);
    const battery = Number.parseInt(String(raw.batteryHealth || "").replace(/\D/g, ""), 10);
    return {
      imei: /^\d{15}$/.test(imei) ? imei : "", model: String(raw.model || "").trim(),
      storageGb: Number.isInteger(storage) && storage > 0 ? storage : null,
      color: cleanColor(raw.color), batteryHealth: Number.isInteger(battery) && battery >= 1 && battery <= 100 ? battery : null,
      activationState: String(raw.activationState || "").trim()
    };
  }
  function renderEmptyBarcode() {
    label.barcode.replaceChildren();
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    text.setAttribute("x", "50%"); text.setAttribute("y", "55%"); text.setAttribute("text-anchor", "middle");
    text.setAttribute("font-size", "10"); text.setAttribute("fill", "#87958c"); text.textContent = "CONNECT PHONE TO CREATE BARCODE";
    label.barcode.append(text);
  }
  function renderDevice(device) {
    currentDevice = device;
    fields.imei.textContent = device.imei || "—";
    fields.model.textContent = device.model || "—";
    fields.storage.textContent = device.storageGb ? `${device.storageGb} GB` : "—";
    fields.color.textContent = device.color || "—";
    fields.battery.textContent = device.batteryHealth ? `${device.batteryHealth}%` : "—";
    if (activationCompletedDeviceKey !== connectedDeviceKey) {
      fields.activation.textContent = device.activationState ? `${device.activationState} · Setup pending` : "Setup pending";
      fields.activation.classList.remove("is-activated");
      fields.activation.classList.add("is-pending");
    }
    label.model.textContent = device.model || "Model —";
    label.storage.textContent = device.storageGb ? `${device.storageGb} GB` : "GB —";
    label.color.textContent = device.color || "Color —";
    label.battery.textContent = device.batteryHealth ? `BH ${device.batteryHealth}%` : "BH —";
    if (device.imei && window.JsBarcode) {
      window.JsBarcode(label.barcode, device.imei, { format: "CODE128", displayValue: true, width: 1.35, height: 38, margin: 0, font: "Arial", fontSize: 10, textMargin: 1, lineColor: "#071d13" });
    } else renderEmptyBarcode();
    updatePrintReady();
  }
  function deviceComplete() { return Boolean(currentDevice?.imei && currentDevice?.model && currentDevice?.storageGb && currentDevice?.color && currentDevice?.batteryHealth); }
  function updatePrintReady() { printButton.disabled = !(batchSelect.value && deviceComplete() && homeScreenConfirm.checked); }
  function markSetupWaiting() {
    homeScreenConfirm.checked = false;
    homeScreenStatus.textContent = "Waiting for automatic Home Screen setup";
    homeScreenCard.classList.remove("is-complete");
    updatePrintReady();
  }
  function markSetupComplete(deviceKey) {
    activationCompletedDeviceKey = deviceKey;
    homeScreenConfirm.checked = true;
    homeScreenStatus.textContent = "Activation Successful — Home Screen ready";
    homeScreenCard.classList.add("is-complete");
    fields.activation.textContent = "Activation Successful";
    fields.activation.classList.remove("is-pending");
    fields.activation.classList.add("is-activated");
    updatePrintReady();
  }

  async function fetchLocal(path, timeoutMs = 12000) {
    const abort = new AbortController();
    const timeout = window.setTimeout(() => abort.abort(), timeoutMs);
    try {
      const response = await fetch(`http://127.0.0.1:51892${path}${path.includes("?") ? "&" : "?"}t=${Date.now()}`, { cache: "no-store", signal: abort.signal });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) { const error = new Error(result.message || "The local Cable Reader could not complete this action."); error.details = result; throw error; }
      return result;
    } finally { window.clearTimeout(timeout); }
  }
  async function checkReader() {
    try { await fetchLocal("/health", 3500); setReaderStatus("Cable Reader ready · waiting for iPhone", "ready"); return true; }
    catch { setReaderStatus("Cable Reader offline", "warning"); return false; }
  }

  async function readActivatedDevice() {
    let lastError;
    for (let attempt = 0; attempt < 12; attempt += 1) {
      try {
        const result = await fetchLocal("/v1/device", 6000);
        const device = normaliseDevice(result.device || {});
        if (device.imei) { renderDevice(device); return device; }
      } catch (error) { lastError = error; }
      await new Promise((resolve) => window.setTimeout(resolve, 1000));
    }
    throw lastError || new Error("The phone is activated, but its label data is not ready yet.");
  }

  async function completeSetupAutomatically(probe) {
    const deviceKey = String(probe?.deviceKey || "");
    if (!deviceKey || activationInProgress || activationCompletedDeviceKey === deviceKey || activationBlockedDeviceKey === deviceKey || Date.now() < nextActivationAttemptAt) return;
    activationInProgress = true;
    setMessage("iPhone detected. Greenloop is completing Apple activation and Setup Assistant automatically…", "success");
    setReaderStatus("Automatic Home Screen setup in progress");
    try {
      const result = await fetchLocal("/v1/activate", 150000);
      if (!result.setupAssistantCompleted && !result.homeScreenReady) throw new Error("Setup Assistant completion was not confirmed.");
      markSetupComplete(deviceKey);
      setReaderStatus("Activation Successful", "ready");
      try {
        await readActivatedDevice();
        markSetupComplete(deviceKey);
        setMessage("Activation Successful. The Home Screen is ready and Print label is available.", "success");
      } catch {
        setMessage("Activation Successful. The Home Screen is ready; Greenloop is still reading label data.", "success");
      }
      showActivationPopup({ title: "Activation Successful", popupMessage: "Greenloop completed Setup Assistant. The phone is ready on the Home Screen and its label can now be printed.", type: "success" });
    } catch (error) {
      const details = error?.details || {};
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      const text = offline ? "Greenloop Cable Reader is offline. Restart the installed Cable Reader and reconnect the iPhone." : (error.message || "Automatic activation could not be completed.");
      if (details.securityBlocked) activationBlockedDeviceKey = deviceKey;
      else nextActivationAttemptAt = Date.now() + 8000;
      setMessage(text);
      setReaderStatus(details.securityBlocked ? "Apple security block" : "Automatic setup needs attention", "warning");
      if (details.title || details.securityBlocked || details.blockCode) showActivationPopup({ title: details.title || "Activation Needs Attention", popupMessage: details.message || text, type: details.securityBlocked ? "blocked" : "warning" });
    } finally { activationInProgress = false; }
  }

  async function pollConnectedPhone() {
    if (readerBusy || activationInProgress) return;
    readerBusy = true;
    try {
      const probe = await fetchLocal("/v1/probe", 5000);
      if (!probe.connected || !probe.deviceKey) {
        if (connectedDeviceKey) resetPhoneState();
        setReaderStatus("Waiting for iPhone");
        return;
      }
      if (probe.deviceKey !== connectedDeviceKey) {
        connectedDeviceKey = probe.deviceKey;
        activationCompletedDeviceKey = "";
        activationBlockedDeviceKey = "";
        nextActivationAttemptAt = 0;
        markSetupWaiting();
        currentDevice = null;
      }
      setReaderStatus(activationCompletedDeviceKey === probe.deviceKey ? "Activation Successful" : "iPhone detected", "ready");
      if (activationCompletedDeviceKey === probe.deviceKey) {
        if (!currentDevice?.imei) {
          try { await readActivatedDevice(); markSetupComplete(probe.deviceKey); } catch {}
        }
      } else {
        await completeSetupAutomatically(probe);
      }
    } catch (error) {
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      setReaderStatus(offline ? "Cable Reader offline" : "Waiting for iPhone", offline ? "warning" : "");
    } finally { readerBusy = false; }
  }

  function resetPhoneState() {
    currentDevice = null; connectedDeviceKey = ""; activationCompletedDeviceKey = ""; activationBlockedDeviceKey = ""; nextActivationAttemptAt = 0;
    markSetupWaiting();
    Object.values(fields).forEach((field) => { field.textContent = field === fields.activation ? "Waiting" : "—"; });
    fields.activation.classList.remove("is-activated", "is-pending");
    label.model.textContent = "Model —"; label.storage.textContent = "GB —"; label.color.textContent = "Color —"; label.battery.textContent = "BH —";
    renderEmptyBarcode();
  }
  function clearPhone() {
    resetPhoneState();
    setMessage("Ready for the next phone. Disconnect the current iPhone, then connect the next one.", "success");
    setReaderStatus("Waiting for next iPhone", "ready");
  }
  function printLabel() {
    if (!batchSelect.value) { setMessage("Select the supplier batch before printing."); return; }
    if (!deviceComplete()) { setMessage("Complete phone data is required before printing its label."); return; }
    if (!homeScreenConfirm.checked) { setMessage("Wait for the automatic Activation Successful confirmation."); return; }
    window.print(); showToast("Label sent to the print dialog.");
  }
  function startAutomaticReader() {
    window.clearInterval(autoReadTimer);
    autoReadTimer = window.setInterval(() => { if (!document.hidden) pollConnectedPhone(); }, 1400);
    pollConnectedPhone();
  }
  async function initialize() {
    if (!window.supabase || !config.supabaseUrl || !config.supabaseAnonKey) throw new Error("Supabase is not configured.");
    const { data } = await api().auth.getSession();
    if (!data.session) { window.location.replace("index.html"); return; }
    await loadBatches();
    renderEmptyBarcode();
    await checkReader();
    startAutomaticReader();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  batchSelect.addEventListener("change", updateBatchView);
  printButton.addEventListener("click", printLabel);
  nextButton.addEventListener("click", clearPhone);
  document.querySelector("#close-activation-popup")?.addEventListener("click", closeActivationPopup);
  document.querySelector("#activation-popup")?.addEventListener("click", (event) => { if (event.target?.id === "activation-popup") closeActivationPopup(); });
  window.addEventListener("keydown", (event) => { if (event.key === "Escape") closeActivationPopup(); });
  window.addEventListener("beforeunload", () => window.clearInterval(autoReadTimer));
  initialize().catch((error) => setMessage(error.message || "Activate & Print Label could not start."));
})();
