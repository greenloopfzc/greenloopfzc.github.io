(() => {
  "use strict";

  const pending = new Map();
  let revision = 0;
  let dialog;
  function currentDialog() {
    if (dialog) return dialog;
    dialog = document.querySelector("#duplicate-imei-dialog");
    if (!dialog) {
      dialog = document.createElement("dialog");
      dialog.id = "duplicate-imei-dialog";
      dialog.setAttribute("aria-labelledby", "duplicate-imei-title");
      dialog.innerHTML = '<div class="duplicate-imei-dialog-heading"><span aria-hidden="true">!</span><h2 id="duplicate-imei-title"></h2></div><p></p><div class="duplicate-imei-actions"><button id="duplicate-imei-close" class="primary-button" type="button">OK</button></div>';
      document.body.append(dialog);
    }
    dialog.classList.add("imei-duplicate-dialog", "gl-imei-stage-dialog");
    const details = document.createElement("div");
    details.className = "gl-imei-stage-details";
    details.setAttribute("role", "status");
    details.setAttribute("aria-live", "polite");
    details.innerHTML = '<span>IMEI</span><strong data-notice-imei></strong><span>Current stage</span><strong data-notice-stage></strong>';
    dialog.querySelector(".duplicate-imei-actions").before(details);
    dialog.querySelector("#duplicate-imei-close").addEventListener("click", () => { revision++; if (dialog.open) dialog.close(); });
    dialog.addEventListener("cancel", () => { revision++; });
    return dialog;
  }
  async function lookup(imei) {
    const value = String(imei || "").trim();
    if (!/^\d{15}$/.test(value)) return null;
    if (!pending.has(value)) {
      const request = (async () => {
        let timer;
        try {
          const response = await Promise.race([
            window.GREENLOOP_GET_CLIENT().rpc("get_imei_duplicate_stage_v1", { p_imei: value }),
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Stage check timed out")), 12000); })
          ]);
          if (response.error) throw response.error;
          const data = response.data;
          if (!data || Array.isArray(data) || typeof data.found !== "boolean" || data.current_stage !== null && typeof data.current_stage !== "string") throw new Error("Invalid stage response");
          return data;
        } finally { clearTimeout(timer); }
      })().catch(() => null).finally(() => pending.delete(value));
      pending.set(value, request);
    }
    return pending.get(value);
  }
  async function show({ imei, title = "Duplicate phone", message = "This phone already exists in the system.", isCurrent = () => true, onlyIfFound = false, knownRecord = null } = {}) {
    const ticket = ++revision;
    const valid = () => ticket === revision && isCurrent();
    // A newer scan owns the notice. Close an older one while the new lookup
    // is pending; a late native close event must not cancel the new lookup.
    if (dialog?.open) dialog.close();
    const result = knownRecord ? Promise.resolve(knownRecord) : lookup(imei);
    let record;
    if (onlyIfFound) {
      record = await result;
      if (!valid() || !record?.found) return false;
    }
    if (!valid()) return false;
    const modal = currentDialog();
    modal.querySelector("#duplicate-imei-title").textContent = title;
    modal.querySelector(":scope > p").textContent = message;
    modal.dataset.imei = String(imei || "");
    modal.querySelector(".gl-imei-stage-details").hidden = false;
    modal.querySelector("[data-notice-imei]").textContent = String(imei || "");
    modal.querySelector("[data-notice-stage]").textContent = "Checking current stage…";
    if (!modal.open) modal.showModal();
    record ||= await result;
    if (!valid() || !modal.open) {
      if (ticket === revision && modal.open) modal.close();
      return false;
    }
    if (record?.matched_type === "secondary" && /^\d{15}$/.test(record.primary_imei || "")) {
      modal.querySelector("#duplicate-imei-title").textContent = "Duplicate phone";
      modal.querySelector(":scope > p").textContent = `This is IMEI 2 of IMEI 1 ${record.primary_imei}. Both belong to the same phone. Use IMEI 1 to continue.`;
      modal.querySelector("[data-notice-imei]").textContent = record.primary_imei;
    }
    modal.querySelector("[data-notice-stage]").textContent = record?.found && record.current_stage
      ? record.current_stage : "Current stage could not be checked. Please try again.";
    return true;
  }
  function clear() {
    revision++;
    const details = document.querySelector(".gl-imei-stage-details");
    if (details) details.hidden = true;
  }
  async function checkPrimary(imei, {isCurrent = () => true} = {}) {
    const value=String(imei || "").trim();if(!/^\d{15}$/.test(value))return true;
    const r=await lookup(value);if(!isCurrent())return false;
    if(!r || r.found && !["primary","secondary"].includes(r.matched_type))throw new Error("Phone identity could not be verified. Refresh before continuing.");
    if(r.matched_type === "secondary"){await show({imei:value,isCurrent,knownRecord:r});return false;}
    return true;
  }
  window.GREENLOOP_IMEI_STAGE_NOTICE = { show, clear, checkPrimary };
})();
