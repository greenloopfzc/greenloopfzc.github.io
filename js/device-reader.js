(() => {
  "use strict";

  const endpoint = "http://127.0.0.1:51892/v1/device";
  const threeUToolsEndpoint = "http://127.0.0.1:51894/v1/device";
  let lastFingerprint = "";
  const nextThreeUToolsAttemptAt = new Map();
  let polling = false;
  let failedReads = 0;
  let readerState = "";
  window.GREENLOOP_GET_CONNECTED_DEVICE = () =>
    Date.now() - (window.GREENLOOP_LAST_DEVICE_AT || 0) < 30000 ? window.GREENLOOP_LAST_DEVICE : null;
  const appleSalesRegions = new Map([
    ["VC/A", "Canada"], ["C/A", "Canada"], ["CL/A", "Canada"],
    ["LL/A", "United States"], ["CH/A", "Mainland China"], ["ZP/A", "Hong Kong / Macau"],
    ["J/A", "Japan"], ["KH/A", "South Korea"], ["VN/A", "Vietnam"], ["TA/A", "Taiwan"],
    ["ZA/A", "Singapore / Malaysia"], ["AB/A", "United Arab Emirates"], ["X/A", "Australia / New Zealand"],
    ["B/A", "United Kingdom / Ireland"], ["ZD/A", "Central Europe"]
  ]);

  function formatPhoneRegion(value) {
    const source = String(value || "").trim();
    if (!source) return "";
    const match = source.toUpperCase().match(/\b([A-Z]{1,3}\/A)\b/);
    const code = match?.[1] || "";
    const country = appleSalesRegions.get(code);
    if (!country) return source;
    return source.toLocaleLowerCase().includes(country.toLocaleLowerCase()) ? source : `${code} — ${country}`;
  }
  let stopped = false;

  function normalise(payload) {
    const source = payload?.device || payload || {};
    const batteryRaw = source.batteryHealth ?? source.battery_health;
    return {
      imei: String(source.imei || source.imei1 || "").replace(/\D/g, "").slice(0, 15),
      model: String(source.model || source.productName || "").trim(),
      storageGb: Number(source.storageGb || source.storage_gb || source.capacity || 0) || "",
      color: String(source.color || source.deviceColor || "").trim(),
      batteryHealth: batteryRaw === "" || batteryRaw === null || batteryRaw === undefined
        ? ""
        : (Number(batteryRaw) || ""),
      batteryHealthSource: String(source.batteryHealthSource || "device"),
      serialNumber: String(source.serialNumber || source.serial_number || "").trim(),
      phoneRegion: formatPhoneRegion(source.phoneRegion || source.phone_region || source.specificationRegion || source.specification_region || source.region)
    };
  }

  async function readThreeUToolsDevice() {
    const response = await fetch(threeUToolsEndpoint, { cache: "no-store", signal: AbortSignal.timeout(2500) });
    if (!response.ok) return null;
    const payload = await response.json();
    if (payload?.ok === false) return null;
    const device = normalise(payload);
    return /^\d{15}$/.test(device.imei) ? device : null;
  }

  async function fillMissingColorFrom3uTools(device) {
    if (device.color || !device.imei) return device;
    const now = Date.now();
    if (now < (nextThreeUToolsAttemptAt.get(device.imei) || 0)) return device;
    // 3uTools can finish reading a newly connected iPhone a moment after its IMEI.
    // Retry automatically instead of requiring a cable reconnect.
    nextThreeUToolsAttemptAt.set(device.imei, now + 1500);
    try {
      const fallback = await readThreeUToolsDevice();
      if (!fallback) return device;
      if (fallback.imei !== device.imei) return device;
      return {
        ...device,
        color: fallback.color || device.color,
        serialNumber: device.serialNumber || fallback.serialNumber,
        phoneRegion: device.phoneRegion || fallback.phoneRegion
      };
    } catch (_) {
      return device;
    }
  }

  function publishDevice(device) {
    const previous = window.GREENLOOP_LAST_DEVICE;
    if (previous?.imei !== device.imei) window.GREENLOOP_CABLE_CONNECTION_ID = (window.GREENLOOP_CABLE_CONNECTION_ID || 0) + 1;
    if (previous?.imei === device.imei) {
      // Late/partial USB responses enrich the same phone, never erase good data.
      device = { ...device };
      for (const key of ["model", "storageGb", "color", "batteryHealth", "serialNumber", "phoneRegion"]) {
        if (device[key] === "" || device[key] == null) device[key] = previous[key];
      }
      if (!device.batteryHealth || device.batteryHealth === previous.batteryHealth) device.batteryHealthSource = previous.batteryHealthSource;
    }
    const fingerprint = JSON.stringify(device);
    window.GREENLOOP_LAST_DEVICE_AT = Date.now();
    if (fingerprint === lastFingerprint) return false;
    lastFingerprint = fingerprint;
    window.GREENLOOP_LAST_DEVICE = device;
    window.dispatchEvent(new CustomEvent("greenloop:device", { detail: device }));
    return true;
  }
  function publishReaderState(state, message = "") {
    const key = `${state}:${message}`;
    if (key === readerState) return;
    readerState = key;
    window.GREENLOOP_READER_STATUS = { state, message };
    window.dispatchEvent(new CustomEvent("greenloop:device-reader-status", { detail: { state, message } }));
  }
  function forgetConnection() {
    lastFingerprint = "";
    window.GREENLOOP_LAST_DEVICE = null;
    window.GREENLOOP_LAST_DEVICE_AT = 0;
  }

  async function poll() {
    if (stopped || document.hidden || polling) return;
    polling = true;
    try {
      let device = null;
      let readerResponded = false;
      let readerMessage = "";
      if (!window.GREENLOOP_LAST_DEVICE) publishReaderState("reading", "Reading connected phone...");
      try {
        // USB startup + optional diagnostics are bounded by the helper. Do not
        // abort a healthy first read after only 2.5 seconds.
        const response = await fetch(endpoint, { cache: "no-store", signal: AbortSignal.timeout(20000) });
        const payload = await response.json();
        readerResponded = true;
        readerMessage = payload?.message || "Connect one unlocked phone and accept Trust if asked.";
        if (response.ok) {
          if (payload?.ok !== false) device = normalise(payload);
        }
      } catch (_) {
        // A 3uTools-only receiving PC does not run the Apple driver reader.
      }
      // A known disconnected/locked phone must not be replaced with stale OCR.
      if (!readerResponded && (!device || !/^\d{15}$/.test(device.imei))) {
        try { device = await readThreeUToolsDevice(); } catch (_) { device = null; }
      }
      if (!device || !/^\d{15}$/.test(device.imei)) {
        failedReads += 1;
        forgetConnection();
        publishReaderState(readerResponded ? "waiting" : "offline", readerResponded ? readerMessage : "Cable reader unavailable. Start Greenloop Cable Reader; allow local-network access if your browser asks.");
        return;
      }
      failedReads = 0;
      publishReaderState("ready");
      publishDevice(device);
      if (!device.color) {
        const enriched = await fillMissingColorFrom3uTools(device);
        publishDevice(enriched);
      }
    } catch (_) {
      failedReads += 1;
      forgetConnection();
      publishReaderState("offline", "Cable reader could not respond. Start Greenloop Cable Reader, then retry.");
    } finally {
      polling = false;
    }
  }

  window.addEventListener("beforeunload", () => { stopped = true; });
  window.addEventListener("focus", poll);
  window.addEventListener("greenloop:retry-device", () => { lastFingerprint = ""; window.GREENLOOP_CABLE_CONNECTION_ID = (window.GREENLOOP_CABLE_CONNECTION_ID || 0) + 1; poll(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
  window.setInterval(poll, 900);
  window.setTimeout(poll, 100);
})();
