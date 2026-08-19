(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const batchSelect = document.querySelector("#activate-batch");
  const batchSummary = document.querySelector("#activate-batch-summary");
  const open3uToolsButton = document.querySelector("#open-3utools");
  const readButton = document.querySelector("#read-activate-phone");
  const autoRead = document.querySelector("#activate-auto-read");
  const readerStatus = document.querySelector("#reader-status");
  const homeScreenConfirm = document.querySelector("#home-screen-confirm");
  const printButton = document.querySelector("#print-phone-label");
  const nextButton = document.querySelector("#next-activate-phone");
  const continueLinks = [document.querySelector("#continue-imei"), document.querySelector("#continue-imei-top")].filter(Boolean);
  const message = document.querySelector("#activate-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedBatchId = new URLSearchParams(window.location.search).get("batch");
  const autoReadStorageKey = "greenloop-activate-label-auto-read";
  const fields = {
    imei: document.querySelector("#device-imei"),
    model: document.querySelector("#device-model"),
    storage: document.querySelector("#device-storage"),
    color: document.querySelector("#device-color"),
    battery: document.querySelector("#device-bh"),
    activation: document.querySelector("#device-activation")
  };
  const label = {
    barcode: document.querySelector("#imei-barcode"),
    model: document.querySelector("#label-model"),
    storage: document.querySelector("#label-storage"),
    color: document.querySelector("#label-color"),
    battery: document.querySelector("#label-bh")
  };

  let client;
  let batches = [];
  let currentDevice = null;
  let readerBusy = false;
  let autoReadTimer;
  let connectedImei = "";
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
  function showToast(value) {
    window.clearTimeout(toastTimer);
    toast.textContent = value;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3200);
  }
  function setBusy(button, busy, busyLabel) {
    if (busy) button.dataset.originalLabel = button.textContent;
    button.disabled = busy;
    button.textContent = busy ? busyLabel : (button.dataset.originalLabel || button.textContent);
  }
  function setReaderStatus(value, state = "") {
    readerStatus.textContent = value;
    readerStatus.classList.toggle("is-ready", state === "ready");
    readerStatus.classList.toggle("is-warning", state === "warning");
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
    batches.forEach((batch) => batchSelect.add(new Option(
      `${supplierLabel(batch)} · ${batch.planned_label} · ${batch.remaining_quantity} remaining`,
      batch.batch_id
    )));
    if (batches.some((batch) => batch.batch_id === requestedBatchId)) batchSelect.value = requestedBatchId;
    updateBatchView();
  }

  function updateBatchView() {
    const batch = batches.find((item) => item.batch_id === batchSelect.value);
    batchSummary.hidden = !batch;
    if (batch) {
      batchSummary.innerHTML = [
        ["Supplier", supplierLabel(batch)],
        ["Stock channel", batch.stock_channel],
        ["Stock plan", batch.planned_label],
        ["Remaining", `${batch.remaining_quantity} phones`]
      ].map(([name, value]) => `<div><span>${escapeHtml(name)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
    }
    updateContinueLinks();
    updatePrintReady();
  }

  function cleanColor(value) {
    const raw = String(value || "").trim();
    if (!raw || raw.startsWith("#") || /^\d+$/.test(raw)) return "";
    return raw.replace(/[-_]/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  }

  function activationIsComplete(value) {
    const state = String(value || "").trim().toLowerCase().replace(/[\s_-]+/g, "");
    return ["activated", "factoryactivated", "true", "yes", "1"].includes(state);
  }

  function normaliseDevice(raw = {}) {
    const imei = String(raw.imei || "").replace(/\D/g, "");
    const storage = Number.parseInt(String(raw.storageGb || "").replace(/\D/g, ""), 10);
    const battery = Number.parseInt(String(raw.batteryHealth || "").replace(/\D/g, ""), 10);
    return {
      imei: /^\d{15}$/.test(imei) ? imei : "",
      model: String(raw.model || "").trim(),
      storageGb: Number.isInteger(storage) && storage > 0 ? storage : null,
      color: cleanColor(raw.color),
      batteryHealth: Number.isInteger(battery) && battery >= 1 && battery <= 100 ? battery : null,
      activationState: String(raw.activationState || "").trim()
    };
  }

  function renderEmptyBarcode() {
    label.barcode.replaceChildren();
    const namespace = "http://www.w3.org/2000/svg";
    const text = document.createElementNS(namespace, "text");
    text.setAttribute("x", "50%");
    text.setAttribute("y", "55%");
    text.setAttribute("text-anchor", "middle");
    text.setAttribute("font-size", "10");
    text.setAttribute("fill", "#87958c");
    text.textContent = "READ PHONE TO CREATE BARCODE";
    label.barcode.append(text);
  }

  function renderDevice(device) {
    currentDevice = device;
    fields.imei.textContent = device.imei || "—";
    fields.model.textContent = device.model || "—";
    fields.storage.textContent = device.storageGb ? `${device.storageGb} GB` : "—";
    fields.color.textContent = device.color || "—";
    fields.battery.textContent = device.batteryHealth ? `${device.batteryHealth}%` : "—";
    const activated = activationIsComplete(device.activationState);
    fields.activation.textContent = activated ? "Activated" : (device.activationState || "Confirm manually");
    fields.activation.classList.toggle("is-activated", activated);
    fields.activation.classList.toggle("is-pending", !activated);
    if (activated) homeScreenConfirm.checked = true;

    label.model.textContent = device.model || "Model —";
    label.storage.textContent = device.storageGb ? `${device.storageGb} GB` : "GB —";
    label.color.textContent = device.color || "Color —";
    label.battery.textContent = device.batteryHealth ? `BH ${device.batteryHealth}%` : "BH —";
    if (device.imei && window.JsBarcode) {
      window.JsBarcode(label.barcode, device.imei, {
        format: "CODE128",
        displayValue: true,
        width: 1.35,
        height: 38,
        margin: 0,
        font: "Arial",
        fontSize: 10,
        textMargin: 1,
        lineColor: "#071d13"
      });
    } else {
      renderEmptyBarcode();
    }
    updatePrintReady();
  }

  function deviceComplete() {
    return Boolean(
      currentDevice?.imei && currentDevice?.model && currentDevice?.storageGb &&
      currentDevice?.color && currentDevice?.batteryHealth
    );
  }

  function updatePrintReady() {
    printButton.disabled = !(batchSelect.value && deviceComplete() && homeScreenConfirm.checked);
  }

  async function fetchLocal(path, timeoutMs = 12000) {
    const abort = new AbortController();
    const timeout = window.setTimeout(() => abort.abort(), timeoutMs);
    try {
      const response = await fetch(`http://127.0.0.1:51892${path}${path.includes("?") ? "&" : "?"}t=${Date.now()}`, {
        cache: "no-store",
        signal: abort.signal
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) throw new Error(result.message || "The local Cable Reader could not complete this action.");
      return result;
    } finally {
      window.clearTimeout(timeout);
    }
  }

  async function checkReader() {
    try {
      await fetchLocal("/health", 3500);
      setReaderStatus("Cable Reader ready", "ready");
      return true;
    } catch {
      setReaderStatus("Cable Reader offline", "warning");
      return false;
    }
  }

  async function open3uTools() {
    setMessage();
    setBusy(open3uToolsButton, true, "Opening...");
    try {
      await fetchLocal("/v1/open-3utools", 6000);
      setMessage("3uTools opened. Activate the connected iPhone and wait for its Home Screen.", "success");
    } catch (error) {
      setMessage(error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""))
        ? "Greenloop Cable Reader is offline. Run its installer once, then try again."
        : (error.message || "3uTools could not be opened."));
    } finally {
      setBusy(open3uToolsButton, false, "Opening...");
    }
  }

  async function readPhone(automatic = false) {
    if (readerBusy) return;
    if (!batchSelect.value) {
      if (!automatic) setMessage("Select the supplier batch before reading a phone.");
      else setReaderStatus("Select supplier batch first", "warning");
      return;
    }
    readerBusy = true;
    if (!automatic) {
      setMessage();
      setBusy(readButton, true, "Reading phone...");
    }
    try {
      const result = await fetchLocal("/v1/device", automatic ? 5000 : 15000);
      const device = normaliseDevice(result.device || {});
      if (!device.imei) throw new Error("The connected phone did not provide a valid 15-digit IMEI.");
      if (automatic && device.imei === connectedImei) {
        setReaderStatus("Phone already loaded", "ready");
        return;
      }
      connectedImei = device.imei;
      renderDevice(device);
      const missing = [!device.model && "Model", !device.storageGb && "GB", !device.color && "Color", !device.batteryHealth && "Battery Health"].filter(Boolean);
      if (missing.length) {
        setMessage(`Phone read, but ${missing.join(", ")} could not be detected. Refresh 3uTools and read again.`);
      } else {
        setMessage(`IMEI ${device.imei} loaded. Confirm the Home Screen, then print its label.`, "success");
      }
      setReaderStatus("Phone loaded", "ready");
    } catch (error) {
      const offline = error?.name === "AbortError" || /failed to fetch|networkerror/i.test(String(error?.message || ""));
      const waiting = /no iphone detected|not trusted|unlock|connect/i.test(String(error?.message || ""));
      if (automatic) {
        if (waiting) connectedImei = "";
        setReaderStatus(offline ? "Cable Reader offline" : (waiting ? "Waiting for iPhone" : "Reader waiting"), offline ? "warning" : "");
      } else {
        setMessage(offline
          ? "Greenloop Cable Reader is offline. Install or restart it, then connect the iPhone again."
          : (error.message || "The connected phone could not be read."));
      }
    } finally {
      readerBusy = false;
      if (!automatic) setBusy(readButton, false, "Reading phone...");
    }
  }

  function clearPhone() {
    currentDevice = null;
    homeScreenConfirm.checked = false;
    Object.values(fields).forEach((field) => { field.textContent = field === fields.activation ? "Waiting" : "—"; });
    fields.activation.classList.remove("is-activated", "is-pending");
    label.model.textContent = "Model —";
    label.storage.textContent = "GB —";
    label.color.textContent = "Color —";
    label.battery.textContent = "BH —";
    renderEmptyBarcode();
    updatePrintReady();
    setMessage("Ready for the next phone. Disconnect the current iPhone, then connect the next one.", "success");
    setReaderStatus(autoRead.checked ? "Waiting for next iPhone" : "Ready", "ready");
  }

  function printLabel() {
    if (!batchSelect.value) { setMessage("Select the supplier batch first."); return; }
    if (!deviceComplete()) { setMessage("Read the complete phone data before printing its label."); return; }
    if (!homeScreenConfirm.checked) { setMessage("Confirm that the activated phone has reached the Home Screen."); return; }
    window.print();
    showToast("Label sent to the print dialog.");
  }

  function startAutoRead() {
    window.clearInterval(autoReadTimer);
    autoRead.closest(".auto-read-control")?.classList.toggle("is-active", autoRead.checked);
    window.localStorage.setItem(autoReadStorageKey, autoRead.checked ? "on" : "off");
    if (!autoRead.checked) {
      setReaderStatus("Auto Read off");
      return;
    }
    setReaderStatus(batchSelect.value ? "Waiting for iPhone" : "Select supplier batch first", batchSelect.value ? "" : "warning");
    autoReadTimer = window.setInterval(() => {
      if (!document.hidden && autoRead.checked) readPhone(true);
    }, 1400);
    readPhone(true);
  }

  async function initialize() {
    if (!window.supabase || !config.supabaseUrl || !config.supabaseAnonKey) throw new Error("Supabase is not configured.");
    const { data } = await api().auth.getSession();
    if (!data.session) { window.location.replace("index.html"); return; }
    await loadBatches();
    renderEmptyBarcode();
    autoRead.checked = window.localStorage.getItem(autoReadStorageKey) === "on";
    await checkReader();
    startAutoRead();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  batchSelect.addEventListener("change", updateBatchView);
  open3uToolsButton.addEventListener("click", open3uTools);
  readButton.addEventListener("click", () => readPhone(false));
  autoRead.addEventListener("change", startAutoRead);
  homeScreenConfirm.addEventListener("change", updatePrintReady);
  printButton.addEventListener("click", printLabel);
  nextButton.addEventListener("click", clearPhone);
  window.addEventListener("beforeunload", () => window.clearInterval(autoReadTimer));

  initialize().catch((error) => setMessage(error.message || "Activate & Print Label could not start."));
})();
