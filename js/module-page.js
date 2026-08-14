(() => {
  "use strict";
  const allowed = new Set(["Parts", "Frame", "RMA", "Retail Shop", "Reports"]);
  const moduleName = new URLSearchParams(window.location.search).get("module") || "Module";
  const title = allowed.has(moduleName) ? moduleName : "Module";
  document.title = `${title} | Greenloop`;
  document.querySelector("#module-crumb").textContent = title;
  document.querySelector("#module-kicker").textContent = title;
  document.querySelector("#module-title").textContent = title;
  document.querySelector("#module-description").textContent = `${title} has its own workspace. Its database workflow will be added in the next Greenloop build step.`;
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  document.querySelector("#open-menu").addEventListener("click", () => { sidebar.classList.add("is-open"); backdrop.hidden = false; });
  document.querySelector("#close-menu").addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
  backdrop.addEventListener("click", () => { sidebar.classList.remove("is-open"); backdrop.hidden = true; });
})();
