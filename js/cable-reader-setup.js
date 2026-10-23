(() => {
  "use strict";
  const host = document.querySelector(".cable-reader-banner, .journey-cable-card");
  if (!host) return;
  const version = "20261023-cable-setup-1";
  const windows = /Windows NT/.test(navigator.userAgent);
  const toolbar = document.createElement("div");
  toolbar.className = "reader-setup-toolbar";
  toolbar.innerHTML = '<button type="button" class="secondary-button reader-setup-open">Setup Cable Reader</button>';
  host.append(toolbar);
  const dialog = document.createElement("dialog");
  dialog.className = "reader-setup-dialog";
  dialog.setAttribute("aria-labelledby", "reader-setup-title");
  dialog.innerHTML = `<header><div><p class="panel-kicker">iPhone + Android · Windows 10/11 x64</p><h2 id="reader-setup-title">Cable Reader setup</h2></div><button type="button" class="secondary-button reader-setup-close" aria-label="Close cable reader setup">Close</button></header>
    <p class="reader-setup-state" role="status" aria-live="polite">Checking this computer...</p>
    <ol><li><strong>Download and run setup</strong><span>Run the downloaded EXE on the computer where phones connect. Install once per Windows user.</span></li><li><strong>Finish the phone driver steps</strong><span>Setup includes iPhone reader tools and downloads official Android tools. Open Apple Devices if needed; Android USB drivers depend on the phone brand. Approve any Windows installation prompt yourself.</span></li><li><strong>Connect one unlocked phone</strong><span>iPhone: tap Trust. Android: enable USB debugging and tap Allow. Allow this website's local-network access if your browser asks. Then check again.</span></li></ol>
    <p class="reader-setup-note">Reader starts automatically at Windows sign-in. Only details supplied by the phone can be filled; review them before saving.</p>
    <div class="reader-setup-actions"><a class="primary-button reader-setup-download" href="downloads/Greenloop-Cable-Reader-Setup.exe?v=${version}" download="Greenloop-Cable-Reader-Setup.exe">Download Windows setup</a><button type="button" class="secondary-button reader-setup-check">Check again</button></div>
    <p class="reader-setup-platform" hidden>Download and run setup on a Windows 10/11 x64 computer. This installer does not run on this device.</p>
    <footer><a href="downloads/reader-sources.zip" download>Reader tool sources &amp; licenses</a></footer>`;
  document.body.append(dialog);
  const state = dialog.querySelector(".reader-setup-state");
  const open = toolbar.querySelector("button");
  const check = dialog.querySelector(".reader-setup-check");
  dialog.querySelector(".reader-setup-platform").hidden = windows;
  dialog.querySelector(".reader-setup-download").hidden = !windows;
  let pending = false;
  let sequence = 0;
  async function inspect() {
    if (pending) return;
    pending = true;
    const request = ++sequence;
    check.disabled = true;
    state.textContent = "Checking this computer...";
    try {
      const response = await fetch("http://127.0.0.1:51892/health", { cache: "no-store", signal: AbortSignal.timeout(3500) });
      const health = await response.json();
      if (!response.ok || health.ok !== true || health.service !== "Greenloop Read-Only Device Reader" || health.mode !== "read-only") throw new Error("unrecognized");
      if (request !== sequence) return;
      const current = health.dualImeiVersion === "20261023-dual-imei-1" && health.androidToolsReady === true;
      open.textContent = current ? "Cable Reader · Ready" : "Update Cable Reader";
      toolbar.dataset.state = current ? "ready" : "update";
      state.dataset.state = current ? "ready" : "update";
      state.textContent = current
        ? "Reader is running with iPhone + Android tools. Connect a phone to confirm its USB driver and Trust/Allow permission."
        : "Reader is running, but its identity support or Android tools need an update. Run setup to check the installed files.";
    } catch (_) {
      if (request !== sequence) return;
      open.textContent = "Setup Cable Reader";
      toolbar.dataset.state = "offline";
      state.dataset.state = "offline";
      state.textContent = windows
        ? "Reader cannot be reached. If already installed, open Greenloop – Auto Reader and allow local-network access, then check again. Otherwise download setup."
        : "Cable Reader setup needs a Windows 10/11 x64 computer. You can continue using manual entry on this device.";
    } finally { pending = false; check.disabled = false; }
  }
  open.addEventListener("click", () => { dialog.showModal(); inspect(); });
  dialog.querySelector(".reader-setup-close").addEventListener("click", () => dialog.close());
  check.addEventListener("click", async () => { await inspect(); window.dispatchEvent(new CustomEvent("greenloop:retry-device")); });
  window.addEventListener("focus", () => { if (!document.hidden) inspect(); });
  window.addEventListener("greenloop:device-reader-status", event => {
    if (event.detail?.state === "ready" && toolbar.dataset.state !== "ready") inspect();
  });
  inspect();
})();
