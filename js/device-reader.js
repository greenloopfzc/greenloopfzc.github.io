(() => {
  "use strict";

  const endpoint = "http://127.0.0.1:51892/v1/device";
  let lastFingerprint = "";
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
        : (Number(batteryRaw) || "")
    };
  }

  async function poll() {
    if (stopped || document.hidden) return;
    try {
      const response = await fetch(endpoint, { cache: "no-store", signal: AbortSignal.timeout(2200) });
      if (!response.ok) return;
      const payload = await response.json();
      if (payload?.ok === false) return;
      const device = normalise(payload);
      if (!/^\d{15}$/.test(device.imei)) return;
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
