(() => {
  "use strict";

  const endpoint = "http://127.0.0.1:51892/v1/device";
  const threeUToolsEndpoint = "http://127.0.0.1:51894/v1/device";
  let lastFingerprint = "";
  let polling = false;
  let forceReaderRead = false;
  let readerState = "";
  let legacyIdentityCheck = null;
  let usbKey = "";
  let revision = 0;
  let colorRequest = null;
  let nextColorAttempt = 0;
  const canRead = () => !stopped && ["view", "edit"].includes(window.GREENLOOP_PAGE_ACCESS?.accessLevel) &&
    (!window.GREENLOOP_CAN || window.GREENLOOP_CAN("view", window.GREENLOOP_PAGE_ACCESS?.pageKey) === true);
  const current = ticket => ticket === revision && canRead();
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
    const platform = source.platform === "android" ? "android" : "ios";
    const imei = String(source.imei || source.imei1 || "").replace(/[\s-]/g, "");
    const serialNumber = String(source.serialNumber || source.serial_number || "").trim();
    return {
      imei: /^\d{15}$/.test(imei) ? imei : "",
      imei2: /^\d{15}$/.test(String(source.imei2 || source.imei_2 || "").trim()) && String(source.imei2 || source.imei_2).trim() !== imei ? String(source.imei2 || source.imei_2).trim() : "",
      identitySchemaVersion: Number(source.identitySchemaVersion || 0),
      platform,
      brand: String(source.brand || (platform === "ios" ? "Apple" : "")).trim(),
      connectionId: String(source.connectionId || (source.udid ? `ios:${source.udid}` : platform === "ios" && /^\d{15}$/.test(imei) ? `ios:${imei}` : "")),
      model: String(source.model || source.productName || "").trim(),
      storageGb: Number(source.storageGb || source.storage_gb || source.capacity || 0) || "",
      color: String(source.color || source.deviceColor || "").trim(),
      batteryHealth: batteryRaw === "" || batteryRaw === null || batteryRaw === undefined
        ? ""
        : (Number.isInteger(Number(batteryRaw)) && Number(batteryRaw) >= 0 && Number.isFinite(Number(batteryRaw)) ? Math.min(100, Number(batteryRaw)) : ""),
      batteryHealthUnavailable: platform === "android" && source.batteryHealthUnavailable === true,
      batteryHealthSource: String(source.batteryHealthSource || "device"),
      serialNumber,
      phoneRegion: (platform === "ios" ? formatPhoneRegion : (value) => String(value || "").trim())(source.phoneRegion || source.phone_region || source.specificationRegion || source.specification_region || source.region)
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

  function fillMissingColorFrom3uTools(device, ticket) {
    const now = Date.now();
    if (device.platform === "android" || !device.imei || window.GREENLOOP_LAST_DEVICE?.color ||
        colorRequest || now < nextColorAttempt) return;
    nextColorAttempt = now + 1500;
    const request = readThreeUToolsDevice();
    colorRequest = request;
    void request.then(fallback => {
      if (!current(ticket) || colorRequest !== request || fallback?.imei !== device.imei) return;
      const active = window.GREENLOOP_LAST_DEVICE;
      if (!active || active.connectionId !== device.connectionId || active.imei !== device.imei ||
          Date.now() - window.GREENLOOP_LAST_DEVICE_AT >= 30000) return;
      publishDevice({
        ...active,
        color: active.color || fallback.color,
        imei2: active.imei2 || fallback.imei2,
        serialNumber: active.serialNumber || fallback.serialNumber,
        phoneRegion: active.phoneRegion || fallback.phoneRegion
      }, false);
    }).catch(() => {
      // Color can still be read in a later USB response or entered manually.
    }).finally(() => {
      if (colorRequest === request) colorRequest = null;
    });
  }

  function publishDevice(device, fresh = true) {
    const previous = window.GREENLOOP_LAST_DEVICE;
    const samePhone = previous?.connectionId && previous.connectionId === device.connectionId && (!previous.imei || !device.imei || previous.imei === device.imei);
    if (!samePhone) window.GREENLOOP_CABLE_CONNECTION_ID = (window.GREENLOOP_CABLE_CONNECTION_ID || 0) + 1;
    if (samePhone) {
      // Late/partial USB responses enrich the same phone, never erase good data.
      device = { ...device };
      const missingBattery = device.batteryHealth === "" || device.batteryHealth == null;
      for (const key of ["imei", "imei2", "brand", "model", "storageGb", "color", "batteryHealth", "serialNumber", "phoneRegion"]) {
        if (device[key] === "" || device[key] == null) device[key] = previous[key];
      }
      if (missingBattery) device.batteryHealthSource = previous.batteryHealthSource;
    }
    if (device.batteryHealth !== "" && device.batteryHealth != null) device.batteryHealthUnavailable = false;
    const fingerprint = JSON.stringify(device);
    if (fresh) window.GREENLOOP_LAST_DEVICE_AT = Date.now();
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

  function resetReader() {
    revision += 1;
    usbKey = "";
    legacyIdentityCheck = null;
    colorRequest = null;
    nextColorAttempt = 0;
    forgetConnection();
  }

  async function poll() {
    if (document.hidden || polling || !canRead()) return;
    polling = true;
    let ticket = revision;
    let verifyingIdentity = false;
    try {
      let device = null;
      let readerResponded = false;
      let readerMessage = "";
      if (!window.GREENLOOP_LAST_DEVICE) publishReaderState("reading", "Reading connected phone...");
      const readerPath = forceReaderRead ? "/v1/device?refresh=1" : "/v1/device";
      forceReaderRead = false;
      try {
        // USB startup and optional diagnostics are bounded by the local helper.
        const request = window.GREENLOOP_READER_CONNECTION?.fetch || ((path, options) => fetch(new URL(path, endpoint).href, options));
        const response = await request(readerPath, { cache: "no-store", signal: AbortSignal.timeout(20000) });
        const payload = await response.json();
        readerResponded = true;
        readerMessage = payload?.message || "Connect one unlocked phone and accept Trust if asked.";
        if (response.ok && payload?.ok !== false) device = normalise(payload);
      } catch (_) {
        // A 3uTools-only receiving PC may not run the local Greenloop helper.
      }
      if (!current(ticket)) return;
      // A known disconnected or locked phone must never be replaced with old OCR.
      if (!readerResponded && (!device || !/^\d{15}$/.test(device.imei))) {
        try { device = await readThreeUToolsDevice(); } catch (_) { device = null; }
      }
      if (!current(ticket)) return;
      if (!device || (!/^\d{15}$/.test(device.imei) && !(device.platform === "android" && device.connectionId))) {
        resetReader();
        publishReaderState(readerResponded ? "waiting" : "offline", readerResponded ? readerMessage : "Cable reader unavailable. Start Greenloop Cable Reader; allow local-network access if your browser asks.");
        return;
      }

      const physicalKey = JSON.stringify([device.platform, device.connectionId, device.imei]);
      if (usbKey !== physicalKey) {
        resetReader();
        usbKey = physicalKey;
        ticket = revision;
      }
      if (/^\d{15}$/.test(device.imei)) {
        verifyingIdentity = true;
        const scanned = device.imei;
        const isCurrent = () => current(ticket);
        if (window.GREENLOOP_IMEI_CANONICAL) {
          // This protected lookup already verifies the saved primary IMEI.
          const identities = await window.GREENLOOP_IMEI_CANONICAL.resolve([scanned], isCurrent);
          if (!isCurrent()) return;
          const identity = identities.get(scanned);
          if (!identity) throw new Error("Phone identity unavailable.");
          if (identity.imei !== scanned) device = { ...device, imei: identity.imei, imei2: scanned };
        } else if (window.GREENLOOP_IMEI_STAGE_NOTICE?.checkPrimary) {
          // Older pages may have only the stage lookup.
          if (legacyIdentityCheck?.imei !== scanned) {
            const allowed = await window.GREENLOOP_IMEI_STAGE_NOTICE.checkPrimary(scanned, { isCurrent });
            if (!isCurrent()) return;
            legacyIdentityCheck = { imei: scanned, allowed };
          }
          if (!legacyIdentityCheck.allowed) {
            forgetConnection();
            publishReaderState("waiting", "Duplicate phone - the cable IMEI belongs to this phone's main IMEI. Use IMEI 1.");
            return;
          }
        }
        verifyingIdentity = false;
      }
      if (!current(ticket)) return;
      publishReaderState("ready");
      publishDevice(device);
      fillMissingColorFrom3uTools(device, ticket);
    } catch (_) {
      if (!current(ticket)) return;
      resetReader();
      publishReaderState(verifyingIdentity ? "waiting" : "offline", verifyingIdentity
        ? "Phone read, but its IMEI could not be verified. Read again."
        : "Cable reader could not respond. Start Greenloop Cable Reader, then retry.");
    } finally {
      polling = false;
      if (forceReaderRead && canRead() && !document.hidden) queueMicrotask(poll);
    }
  }

  function stopReader() { stopped = true; resetReader(); }
  for (const name of ["pagehide", "beforeunload", "greenloop:office-locked", "greenloop:signed-out"]) {
    window.addEventListener(name, stopReader);
  }
  window.addEventListener("greenloop:permissions-changed", () => { resetReader(); void poll(); });
  document.addEventListener("greenloop:workflow-committed", () => { legacyIdentityCheck = null; });
  window.addEventListener("focus", poll);
  window.addEventListener("greenloop:retry-device", () => {
    forceReaderRead = true;
    resetReader();
    publishReaderState("reading", "Reading connected phone...");
    void poll();
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
  window.setInterval(poll, 900);
  window.setTimeout(poll, 100);
})();
