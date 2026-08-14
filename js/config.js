window.GREENLOOP_CONFIG = Object.freeze({
  supabaseUrl: "https://prypklagfznpdlleldll.supabase.co",
  supabaseAnonKey: "sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt"
});

document.addEventListener("click", (event) => {
  const button = event.target.closest(".module-link[data-module]");
  if (!button) return;

  const routes = {
    "Stock Received": "stock-entry.html",
    "IMEI Entry": "imei-entry.html",
    "IMEI Search": "imei-search.html",
    "Parts": "parts.html",
    "Inventory": "inventory.html",
    "Laboratory": "laboratory.html",
    "Glass": "laboratory.html",
    "Frame": "module.html?module=Frame",
    "Final QC": "final-qc.html",
    "Ready Stock": "ready-stock.html",
    "Export Boxes": "export-box.html",
    "Ready Stock Journey": "ready-stock-journey.html",
    "Production": "production.html",
    "RMA": "module.html?module=RMA",
    "Retail Shop": "module.html?module=Retail%20Shop",
    "Reports": "reports.html",
    "User Access": "user-access.html"
  };

  const route = routes[button.dataset.module];
  if (!route) return;
  event.preventDefault();
  event.stopPropagation();
  window.location.href = route;
}, true);

// One shared sidebar prevents different pages from showing different menus.
(() => {
  const navigation = document.querySelector(".sidebar-nav");
  if (!navigation) return;

  const page = (window.location.pathname.split("/").pop() || "dashboard.html").toLowerCase();
  const moduleName = new URLSearchParams(window.location.search).get("module") || "";
  const item = (label, href, icon, active = false) => `<a class="nav-item${active ? " active" : ""}" href="${href}"><span class="nav-icon" aria-hidden="true">${icon}</span>${label}</a>`;

  navigation.innerHTML = [
    '<p class="nav-label">Workspace</p>',
    item("Overview", "dashboard.html", "⌘", page === "dashboard.html"),
    item("Stock Received", "stock-entry.html", "+", page === "stock-entry.html" || page === "receiving.html"),
    item("IMEI Entry", "imei-entry.html", "⌕", page === "imei-entry.html"),
    '<p class="nav-label">Operations</p>',
    item("Initial QC", "initial-qc.html", "✓", page === "initial-qc.html"),
    item("Parts", "parts.html", "▦", page === "parts.html"),
    item("Inventory", "inventory.html", "▧", page === "inventory.html"),
    item("Laboratory &amp; Glass", "laboratory.html", "⌁", page === "laboratory.html" || page === "glass.html"),
    item("Final QC", "final-qc.html", "◉", page === "final-qc.html"),
    item("Ready Stock", "ready-stock.html", "▤", page === "ready-stock.html"),
    item("Ready Stock Journey", "ready-stock-journey.html", "≡", page === "ready-stock-journey.html"),
    '<p class="nav-label">Control</p>',
    item("Reports", "reports.html", "▤", page === "reports.html"),
    item("User Access", "user-access.html", "☷", page === "user-access.html")
  ].join("");

  const readyStock = navigation.querySelector('a[href="ready-stock.html"]');
  if (readyStock) {
    readyStock.insertAdjacentHTML(
      "afterend",
      `<a class="nav-item${page === "export-box.html" ? " active" : ""}" href="export-box.html"><span class="nav-icon" aria-hidden="true">&#9635;</span>Export Boxes</a>`
    );
  }
})();

// A single logout control is injected into every application page.
(() => {
  const actions = document.querySelector(".topbar-actions");
  if (!actions || actions.querySelector("#global-logout")) return;

  const logoutButton = document.createElement("button");
  logoutButton.id = "global-logout";
  logoutButton.className = "logout-button";
  logoutButton.type = "button";
  logoutButton.textContent = "Logout";
  logoutButton.setAttribute("aria-label", "Sign out from Greenloop");
  actions.append(logoutButton);

  logoutButton.addEventListener("click", async () => {
    logoutButton.disabled = true;
    logoutButton.textContent = "Logging out...";
    try {
      if (window.supabase && window.GREENLOOP_CONFIG?.supabaseUrl && window.GREENLOOP_CONFIG?.supabaseAnonKey) {
        const client = window.supabase.createClient(window.GREENLOOP_CONFIG.supabaseUrl, window.GREENLOOP_CONFIG.supabaseAnonKey);
        await client.auth.signOut();
      }
    } finally {
      window.location.replace("index.html");
    }
  });
})();

// One top-centre IMEI search is available on every application page.
(() => {
  const topbar = document.querySelector(".topbar");
  if (!topbar) return;

  let search = topbar.querySelector(".search-box");
  if (!search) {
    search = document.createElement("form");
    search.className = "search-box global-imei-search";
    search.innerHTML = '<label class="sr-only" for="global-imei-search">Search by IMEI or device number</label><span aria-hidden="true">⌕</span><input id="global-imei-search" type="search" autocomplete="off" placeholder="Search IMEI or device number"><kbd>Enter</kbd>';
    const actions = topbar.querySelector(".topbar-actions");
    topbar.insertBefore(search, actions || null);
  } else {
    search.classList.add("global-imei-search");
    const input = search.querySelector("input");
    if (input) input.placeholder = "Search IMEI or device number";
  }

  const input = search.querySelector("input");
  if (!input) return;
  const goToSearch = () => {
    const value = input.value.trim();
    if (!value) return;
    window.location.assign(`imei-search.html?q=${encodeURIComponent(value)}`);
  };

  let automaticSearchTimer;
  input.addEventListener("input", () => {
    window.clearTimeout(automaticSearchTimer);
    const value = input.value.trim();
    if (/^\d{15}$/.test(value) || /^DEV-\d+$/i.test(value)) {
      automaticSearchTimer = window.setTimeout(goToSearch, 260);
    }
  });

  if (search.tagName === "FORM") {
    search.addEventListener("submit", (event) => { event.preventDefault(); goToSearch(); });
  } else {
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); goToSearch(); }
    });
  }
})();

document.querySelectorAll('a[href="receiving.html"]').forEach((link) => {
  [...link.childNodes].forEach((node) => {
    if (node.nodeType === Node.TEXT_NODE) node.textContent = node.textContent.replace("Receiving", "Stock Received");
  });
  link.href = "stock-entry.html";
});
