(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const CABLE_READER = "http://127.0.0.1:51892";
  const THREE_U_BRIDGE = "http://127.0.0.1:51894";
  const batchSelect = document.querySelector("#activate-batch");
  const batchSummary = document.querySelector("#activate-batch-summary");
  const readerStatus = document.querySelector("#reader-status");
  const homeScreenConfirm = document.querySelector("#home-screen-confirm");
  const homeScreenStatus = document.querySelector("#home-screen-status");
  const homeScreenCard = document.querySelector(".home-screen-confirm");
  const printButton = document.querySelector("#print-phone-label");
  const nextButton = document.querySelector("#next-activate-phone");
  const openThreeUButton = document.querySelector("#open-3utools");
  const refreshThreeUButton = document.querySelector("#refresh-3utools");
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
  let connectedDeviceKey = "";
  let homeScreenReady = false;
  let pollBusy = false;
  let threeUToolsOpenedForKey = "";
  let pollTimer;
  let toastTimer;

  function api() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
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
  function showPopup(title, popupMessage, type = "warning") {
    const popup = document.querySelector("#activation-popup");
    popup.className = `activation-popup is-${type}`;
    document.querySelector("#activation-popup-title").textContent = title;
    document.querySelector("#activation-popup-message").textContent = popupMessage;
    popup.hidden = false;
  }
  function closePopup() { document.querySelector("#activation-popup").hidden = true; }

  async function fetchLocal(base, path, timeoutMs = 7000) {
    const abort = new AbortController();
    const timeout = window.setTimeout(() => abort.abort(), timeoutMs);
    try {
      const response = await fetch(`${base}${path}${path.includes("?") ? "&" : "?"}t=${Date.now()}`, { cache: "no-store", signal: abort.signal });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) {
        const error = new Error(result.message || "The local Greenloop helper could not complete this action.");
        error.details = result;
        throw error;
      }
      return result;
    } finally { window.clearTimeout(timeout); }
  }

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
    const storage = Number.parseInt(String(raw.storageGb || raw.storage || "").replace(/\D/g, ""), 10);
    const battery = Number.parseInt(String(raw.batteryHealth || raw.battery || "").replace(/\D/g, ""), 10);
    return {
      imei: /^\d{15}$/.test(imei) ? imei : "", model: String(raw.model || "").trim(),
      storageGb: Number.isInteger(storage) && storage > 0 ? storage : null,
      color: cleanColor(raw.color),
      batteryHealth: Number.isInteger(battery) && battery >= 1 && battery <= 100 ? battery : null,
      activationState: String(raw.activationState || "").trim()
    };
  }
  function mergeDevices(...devices) {
    const result = { imei: "", model: "", storageGb: null, color: "", batteryHealth: null, activationState: "" };
    devices.filter(Boolean).forEach((device) => Object.keys(result).forEach((key) => {
      if (device[key] !== "" && device[key] !== null && device[key] !== undefined) result[key] = device[key];
    }));
    return result;
  }
  function renderEmptyBarcode() {
    label.barcode.replaceChildren();
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    text.setAttribute("x", "50%"); text.setAttribute("y", "55%"); text.setAttribute("text-anchor", "middle");
    text.setAttribute("font-size", "10"); text.setAttribute("fill", "#87958c"); text.textContent = "OPEN 3UTOOLS TO CREATE BARCODE";
    label.barcode.append(text);
  }
  function renderDevice(device) {
    currentDevice = mergeDevices(currentDevice, device);
    fields.imei.textContent = currentDevice.imei || "—";
    fields.model.textContent = currentDevice.model || "—";
    fields.storage.textContent = currentDevice.storageGb ? `${currentDevice.storageGb} GB` : "—";
    fields.color.textContent = currentDevice.color || "—";
    fields.battery.textContent = currentDevice.batteryHealth ? `${currentDevice.batteryHealth}%` : "—";
    fields.activation.textContent = homeScreenReady ? "Home Screen ready" : (currentDevice.activationState ? `${currentDevice.activationState} · Home Screen pending` : "Home Screen pending");
    fields.activation.classList.toggle("is-activated", homeScreenReady);
    fields.activation.classList.toggle("is-pending", !homeScreenReady);
    label.model.textContent = currentDevice.model || "Model —";
    label.storage.textContent = currentDevice.storageGb ? `${currentDevice.storageGb} GB` : "GB —";
    label.color.textContent = currentDevice.color || "Color —";
    label.battery.textContent = currentDevice.batteryHealth ? `BH ${currentDevice.batteryHealth}%` : "BH —";
    if (currentDevice.imei && window.JsBarcode) {
      window.JsBarcode(label.barcode, currentDevice.imei, { format: "CODE128", displayValue: true, width: 1.35, height: 38, margin: 0, font: "Arial", fontSize: 10, textMargin: 1, lineColor: "#071d13" });
    } else renderEmptyBarcode();
    updatePrintReady();
  }
  function deviceComplete() { return Boolean(currentDevice?.imei && currentDevice?.model && currentDevice?.storageGb && currentDevice?.color && currentDevice?.batteryHealth); }
  function updatePrintReady() { printButton.disabled = !(batchSelect.value && homeScreenReady && deviceComplete()); }
  function markHomeScreen(ready) {
    homeScreenReady = Boolean(ready);
    homeScreenConfirm.checked = homeScreenReady;
    homeScreenStatus.textContent = homeScreenReady ? "Home Screen confirmed — label ready" : "Waiting for 3uTools to finish setup";
    homeScreenCard.classList.toggle("is-complete", homeScreenReady);
    if (currentDevice) renderDevice({});
    updatePrintReady();
  }

  async function checkHelpers() {
    let cableReady = false;
    let bridgeReady = false;
    try { cableReady = Boolean((await fetchLocal(CABLE_READER, "/health", 3500)).ok); } catch {}
    try { bridgeReady = Boolean((await fetchLocal(THREE_U_BRIDGE, "/health", 3500)).ok); } catch {}
    if (cableReady && bridgeReady) { setReaderStatus("Greenloop + 3uTools ready", "ready"); return true; }
    setReaderStatus(!bridgeReady ? "3uTools integration offline" : "Cable Reader offline", "warning");
    setMessage("Run the Greenloop Cable Reader installer once on this Windows PC, then refresh this page.");
    return false;
  }
  async function openThreeUTools(showMessage = true) {
    try {
      const result = await fetchLocal(THREE_U_BRIDGE, "/v1/open", 12000);
      if (showMessage) setMessage("3uTools is open. Complete its normal activation / Skip Setup action; Greenloop will read the result automatically.", "success");
      setReaderStatus(result.windowShown ? "3uTools open · monitoring phone" : "3uTools running · open its iDevice page", result.windowShown ? "ready" : "warning");
      return true;
    } catch (error) {
      setReaderStatus("3uTools could not open", "warning");
      setMessage(error.message || "3uTools could not be opened.");
      if (showMessage) showPopup("3uTools Needs Attention", error.message || "Open 3uTools manually and keep its iDevice page visible.");
      return false;
    }
  }
  async function readThreeUTools(showErrors = false) {
    try {
      const result = await fetchLocal(THREE_U_BRIDGE, "/v1/device", 20000);
      const device = normaliseDevice(result.device || {});
      if (!device.imei) throw new Error("3uTools has not exposed the connected phone IMEI yet.");
      renderDevice(device);
      setReaderStatus(homeScreenReady ? "Home Screen ready · label data loaded" : "Phone data loaded · finish setup in 3uTools", homeScreenReady ? "ready" : "warning");
      if (showErrors) setMessage("Phone data refreshed from 3uTools.", "success");
      return device;
    } catch (error) {
      if (showErrors) {
        setMessage(error.message || "Phone data could not be read from 3uTools.");
        showPopup("3uTools Needs Attention", error.message || "Keep 3uTools open on its iDevice page and press Refresh once.");
      }
      return null;
    }
  }
  async function readCableDevice() {
    try {
      const device = normaliseDevice((await fetchLocal(CABLE_READER, "/v1/device", 6500)).device || {});
      if (device.imei) renderDevice(device);
      return device;
    } catch { return null; }
  }
  async function readHomeScreenStatus() {
    try {
      const result = await fetchLocal(CABLE_READER, "/v1/setup-status", 6000);
      markHomeScreen(Boolean(result.homeScreenReady));
      return Boolean(result.homeScreenReady);
    } catch { markHomeScreen(false); return false; }
  }

  async function pollConnectedPhone() {
    if (pollBusy || document.hidden || !batchSelect.value) return;
    pollBusy = true;
    try {
      const probe = await fetchLocal(CABLE_READER, "/v1/probe", 5000);
      if (!probe.connected || !probe.deviceKey) {
        if (connectedDeviceKey) resetPhoneState();
        setReaderStatus("Waiting for iPhone");
        return;
      }
      if (probe.deviceKey !== connectedDeviceKey) {
        resetPhoneState();
        connectedDeviceKey = String(probe.deviceKey);
        setReaderStatus("iPhone detected · opening 3uTools", "ready");
      }
      if (threeUToolsOpenedForKey !== connectedDeviceKey) {
        if (await openThreeUTools(false)) threeUToolsOpenedForKey = connectedDeviceKey;
      }
      const [threeUDevice] = await Promise.all([readThreeUTools(false), readCableDevice(), readHomeScreenStatus()]);
      if (threeUDevice?.imei && homeScreenReady) {
        setMessage("3uTools setup is complete. Phone data and Print label are ready.", "success");
        setReaderStatus("Home Screen ready · label ready", "ready");
      } else if (threeUDevice?.imei) {
        setMessage("Phone data loaded. Finish activation / Skip Setup in 3uTools; Greenloop is monitoring automatically.", "success");
      }
    } catch (error) {
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      setReaderStatus(offline ? "Cable Reader offline" : "Waiting for iPhone", offline ? "warning" : "");
    } finally { pollBusy = false; }
  }

  function resetPhoneState() {
    currentDevice = null; connectedDeviceKey = ""; threeUToolsOpenedForKey = "";
    markHomeScreen(false);
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
    if (!homeScreenReady) { setMessage("Finish the phone setup in 3uTools before printing."); return; }
    if (!deviceComplete()) { setMessage("IMEI, model, GB, color and Battery Health are required before printing."); return; }
    window.print(); showToast("Label sent to the print dialog.");
  }
  function startMonitoring() {
    window.clearInterval(pollTimer);
    pollTimer = window.setInterval(pollConnectedPhone, 1800);
    pollConnectedPhone();
  }
  async function initialize() {
    if (!window.supabase || !config.supabaseUrl || !config.supabaseAnonKey) throw new Error("Supabase is not configured.");
    const { data } = await api().auth.getSession();
    if (!data.session) { window.location.replace("index.html"); return; }
    await loadBatches();
    resetPhoneState();
    await checkHelpers();
    startMonitoring();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  batchSelect.addEventListener("change", updateBatchView);
  openThreeUButton.addEventListener("click", () => openThreeUTools(true));
  refreshThreeUButton.addEventListener("click", async () => { await readThreeUTools(true); await readCableDevice(); await readHomeScreenStatus(); });
  printButton.addEventListener("click", printLabel);
  nextButton.addEventListener("click", clearPhone);
  document.querySelector("#close-activation-popup")?.addEventListener("click", closePopup);
  document.querySelector("#activation-popup")?.addEventListener("click", (event) => { if (event.target?.id === "activation-popup") closePopup(); });
  window.addEventListener("keydown", (event) => { if (event.key === "Escape") closePopup(); });
  window.addEventListener("beforeunload", () => window.clearInterval(pollTimer));
  initialize().catch((error) => setMessage(error.message || "3uTools Setup & Print Label could not start."));
})();
