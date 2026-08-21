(() => {
  "use strict";

  const endpoint = "http://127.0.0.1:51892/v1/device";
  const threeUToolsEndpoint = "http://127.0.0.1:51894/v1/device";
  let lastFingerprint = "";
  let lastThreeUToolsAttemptImei = "";
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
      serialNumber: String(source.serialNumber || source.serial_number || "").trim(),
      phoneRegion: formatPhoneRegion(source.phoneRegion || source.phone_region || source.specificationRegion || source.specification_region || source.region)
    };
  }

  async function fillMissingColorFrom3uTools(device) {
    if (device.color || !device.imei || device.imei === lastThreeUToolsAttemptImei) return device;
    lastThreeUToolsAttemptImei = device.imei;
    try {
      const response = await fetch(threeUToolsEndpoint, { cache: "no-store", signal: AbortSignal.timeout(3500) });
      if (!response.ok) return device;
      const fallback = normalise(await response.json());
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

  async function poll() {
    if (stopped || document.hidden) return;
    try {
      const response = await fetch(endpoint, { cache: "no-store", signal: AbortSignal.timeout(2200) });
      if (!response.ok) return;
      const payload = await response.json();
      if (payload?.ok === false) return;
      let device = normalise(payload);
      if (!/^\d{15}$/.test(device.imei)) return;
      device = await fillMissingColorFrom3uTools(device);
      window.GREENLOOP_LAST_DEVICE = device;
      const fingerprint = JSON.stringify(device);
      if (fingerprint === lastFingerprint) return;
      lastFingerprint = fingerprint;
      window.dispatchEvent(new CustomEvent("greenloop:device", { detail: device }));
    } catch (_) {
      // The local reader is optional. Manual entry must keep working.
    }
  }

  window.addEventListener("beforeunload", () => { stopped = true; });
  window.addEventListener("focus", poll);
  window.setInterval(poll, 1800);
  window.setTimeout(poll, 350);
})();
