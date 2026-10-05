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
