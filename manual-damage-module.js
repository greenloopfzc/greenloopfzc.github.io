(() => {
  "use strict";

  const sidebar = document.getElementById("sidebar");
  const backdrop = document.getElementById("menu-backdrop");
  const openButton = document.getElementById("open-menu");
  const closeButton = document.getElementById("close-menu");
  if (!sidebar || !backdrop || !openButton || !closeButton) return;

  function setMenu(open) {
    sidebar.classList.toggle("is-open", open);
    backdrop.hidden = !open;
    document.body.classList.toggle("menu-open", open);
    openButton.setAttribute("aria-expanded", String(open));
    (open ? closeButton : openButton).focus();
  }

  openButton.addEventListener("click", () => setMenu(true));
  closeButton.addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && sidebar.classList.contains("is-open")) setMenu(false);
  });
})();

// PDF reading requires Damage Report access, independently of entry access.
(async () => {
  await window.GREENLOOP_ACCESS_READY;
  const toggle = document.getElementById("damage-pdf-toggle");
  if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "manual_damage_report" || !toggle || toggle.hidden) return;
  const client = window.GREENLOOP_GET_CLIENT();
  const message = document.getElementById("damage-pdf-access-message");
  let controller;
  function deny(error) {
    controller?.setActive(false);
    toggle.hidden = true;
    message.hidden = false;
    message.textContent = error?.message || "Damage Report access is unavailable. Ask your administrator to check your access.";
  }
  const api = { loadDamageExport(from, to, callback) {
    client.rpc("get_manual_damage_export_v2", { p_date_from: from, p_date_to: to }).then(({data, error}) => {
      if (error) {
        const denied = [error.code, error.status, error.statusCode].some(value => /^(42501|PGRST301|PGRST302|401|403)$/.test(String(value || ""))) || /permission|session|jwt|not authenticated|access denied/i.test(error.message || "");
        callback(denied ? {...error, code:"PERMISSION_DENIED"} : error);
      } else callback(null, Array.isArray(data) ? data[0] : data);
    }).catch(error => callback(error));
  }};
  controller = window.GREENLOOP_DAMAGE_EXPORT(api, deny, () => {});
  controller.setActive(true);
  let accountId = null;
  client.auth.onAuthStateChange?.((event, session) => {
    const nextId = session?.user?.id;
    if (event === "SIGNED_OUT" || (accountId && nextId !== accountId)) deny({message:"Your session changed. Sign in again to view the report."});
    if (nextId) accountId = nextId;
  });
})().catch(() => {
  const message = document.getElementById("damage-pdf-access-message");
  if (message) { message.hidden = false; message.textContent = "PDF tools could not load. Refresh the page and try again."; }
});
