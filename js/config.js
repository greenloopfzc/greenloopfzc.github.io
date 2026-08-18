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
    "Lab & Glass": "laboratory.html",
    "Lab, Glass & Frame": "laboratory.html",
    "Glass": "laboratory.html",
    "Frame": "laboratory.html#frame",
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
    // Permanent production workflow order:
    // Initial QC -> Lab & Glass -> Final QC -> optional Frame -> Final QC -> Ready Stock.
    // Parts and Inventory support the repair workflow and stay beside Lab & Glass.
    item("Initial QC", "initial-qc.html", "✓", page === "initial-qc.html"),
    item("Lab & Glass", "laboratory.html", "⌁", (page === "laboratory.html" || page === "glass.html") && window.location.hash !== "#frame"),
    item("Parts", "parts.html", "▦", page === "parts.html"),
    item("Inventory", "inventory.html", "▧", page === "inventory.html"),
    item("Final QC", "final-qc.html", "◉", page === "final-qc.html"),
    item("Frame Department", "laboratory.html#frame", "□", page === "laboratory.html" && window.location.hash === "#frame"),
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

// Page-level access is shared by every Greenloop screen. The database returns
// the exact pages selected in User Access; unselected links are removed and a
// direct URL is redirected to the first permitted page.
(() => {
  const pageRoutes = Object.freeze({
    overview: "dashboard.html",
    stock_received: "stock-entry.html",
    imei_entry: "imei-entry.html",
    initial_qc: "initial-qc.html",
    lab_glass: "laboratory.html",
    parts: "parts.html",
    inventory: "inventory.html",
    final_qc: "final-qc.html",
    ready_stock: "ready-stock.html",
    export_boxes: "export-box.html",
    ready_stock_journey: "ready-stock-journey.html",
    reports: "reports.html",
    user_access: "user-access.html"
  });

  const filePageKeys = Object.freeze({
    "dashboard.html": "overview",
    "stock-entry.html": "stock_received",
    "receiving.html": "stock_received",
    "imei-entry.html": "imei_entry",
    "initial-qc.html": "initial_qc",
    "laboratory.html": "lab_glass",
    "glass.html": "lab_glass",
    "parts.html": "parts",
    "inventory.html": "inventory",
    "final-qc.html": "final_qc",
    "ready-stock.html": "ready_stock",
    "export-box.html": "export_boxes",
    "ready-stock-journey.html": "ready_stock_journey",
    "reports.html": "reports",
    "user-access.html": "user_access"
  });

  function pageKeyForLink(link) {
    const fileName = new URL(link.href, window.location.href).pathname.split("/").pop().toLowerCase();
    return filePageKeys[fileName] || "";
  }

  function cleanNavigationLabels(navigation) {
    const children = [...navigation.children];
    children.forEach((child, index) => {
      if (!child.classList.contains("nav-label")) return;
      let hasVisibleLink = false;
      for (let next = index + 1; next < children.length; next += 1) {
        if (children[next].classList.contains("nav-label")) break;
        if (children[next].matches("a.nav-item") && !children[next].hidden) {
          hasVisibleLink = true;
          break;
        }
      }
      child.hidden = !hasVisibleLink;
    });
  }

  function lockApplication(navigation, main) {
    if (navigation) {
      navigation.querySelectorAll("a.nav-item").forEach((link) => {
        if (pageKeyForLink(link)) link.hidden = true;
      });
      cleanNavigationLabels(navigation);
    }
    if (main) {
      main.style.visibility = "hidden";
      main.setAttribute("aria-busy", "true");
    }
  }

  function unlockApplication(main) {
    if (!main) return;
    main.style.visibility = "";
    main.removeAttribute("aria-busy");
  }

  function showAccessError(navigation, main) {
    if (navigation) {
      navigation.innerHTML = '<p class="nav-label">Access unavailable</p>';
    }
    if (!main) return;
    main.style.visibility = "";
    main.removeAttribute("aria-busy");
    main.innerHTML = '<div class="page-content"><section class="panel"><p class="form-message error-message">Your page permissions could not be loaded. Please logout, sign in again, and refresh the page.</p></section></div>';
  }

  function makePageViewOnly(main, pageKey) {
    window.GREENLOOP_PAGE_ACCESS = { pageKey, accessLevel: "view", canEdit: false };
    document.documentElement.dataset.pageAccess = "view";
    const mutationWords = /\b(save|create|add|remove|delete|receive|issue|install|return|approve|reject|order|complete|route|pass|fail|cancel|submit|update|edit)\b/i;
    const mutationSelector = [
      "[data-save-row]", "[data-order-parts]", "[data-complete-lab]", "[data-complete-frame]",
      "[data-add-choice]", "[data-remove-choice]", "[data-review-return]", "[data-delete]",
      ".master-add", ".master-remove", ".danger-button"
    ].join(",");

    function isMutationControl(control) {
      if (!control) return false;
      const text = `${control.textContent || ""} ${control.value || ""} ${control.id || ""}`;
      return control.matches(mutationSelector) || mutationWords.test(text);
    }

    function lockControls(root = document) {
      const controls = [];
      if (root.matches?.("button, input[type='submit'], input[type='button']")) controls.push(root);
      controls.push(...root.querySelectorAll?.("button, input[type='submit'], input[type='button']") || []);
      controls.forEach((control) => {
        if (isMutationControl(control)) {
          control.disabled = true;
          control.title = "View-only access: entries and changes are disabled.";
          control.dataset.viewOnlyLocked = "true";
        }
      });
    }

    if (main && !main.querySelector(".view-only-access-banner")) {
      const banner = document.createElement("div");
      banner.className = "view-only-access-banner";
      banner.textContent = "View-only access — you can see this page, but entries and changes are disabled.";
      const content = main.querySelector(".page-content");
      (content || main).prepend(banner);
    }
    lockControls();
    new MutationObserver((changes) => changes.forEach((change) => {
      if (change.type === "attributes") {
        lockControls(change.target);
        return;
      }
      change.addedNodes.forEach((node) => {
        if (node.nodeType === Node.ELEMENT_NODE) lockControls(node);
      });
    })).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["disabled"] });

    document.addEventListener("click", (event) => {
      const control = event.target.closest?.("button, input[type='submit'], input[type='button']");
      if (!isMutationControl(control)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    }, true);

    document.addEventListener("submit", (event) => {
      if ([...event.target.querySelectorAll?.("button, input[type='submit'], input[type='button']") || []].some(isMutationControl)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
  }

  async function applyPageAccess() {
    const currentFile = (window.location.pathname.split("/").pop() || "dashboard.html").toLowerCase();
    const currentPageKey = filePageKeys[currentFile];
    if (!currentPageKey) return;

    const navigation = document.querySelector(".sidebar-nav");
    const main = document.querySelector(".app-main");
    lockApplication(navigation, main);

    if (!window.supabase || !window.GREENLOOP_CONFIG?.supabaseUrl || !window.GREENLOOP_CONFIG?.supabaseAnonKey) {
      showAccessError(navigation, main);
      return;
    }

    const client = window.supabase.createClient(
      window.GREENLOOP_CONFIG.supabaseUrl,
      window.GREENLOOP_CONFIG.supabaseAnonKey
    );
    const { data: sessionData } = await client.auth.getSession();
    if (!sessionData?.session) {
      window.location.replace("index.html");
      return;
    }

    let { data, error } = await client.rpc("get_my_page_access_v2");
    let accessRows;
    if (error && (error.code === "PGRST202" || String(error.message || "").includes("get_my_page_access_v2"))) {
      ({ data, error } = await client.rpc("get_my_page_access"));
      accessRows = (Array.isArray(data) ? data : []).map((pageKey) => ({ page_key: pageKey, access_level: "edit" }));
    } else {
      accessRows = Array.isArray(data) ? data : [];
    }
    if (error) {
      console.error("Page permissions could not be loaded:", error.message);
      showAccessError(navigation, main);
      return;
    }

    const accessByPage = new Map(accessRows.map((row) => [row.page_key, row.access_level || "view"]));
    const allowedPages = new Set(accessByPage.keys());
    if (navigation) {
      navigation.querySelectorAll("a.nav-item").forEach((link) => {
        const pageKey = pageKeyForLink(link);
        if (pageKey) link.hidden = !allowedPages.has(pageKey);
      });
      cleanNavigationLabels(navigation);
    }

    if (allowedPages.has(currentPageKey)) {
      const accessLevel = accessByPage.get(currentPageKey) || "view";
      window.GREENLOOP_PAGE_ACCESS = { pageKey: currentPageKey, accessLevel, canEdit: accessLevel === "edit" };
      document.documentElement.dataset.pageAccess = accessLevel;
      if (accessLevel !== "edit") makePageViewOnly(main, currentPageKey);
      unlockApplication(main);
      return;
    }

    const firstAllowedPage = Object.keys(pageRoutes).find((pageKey) => allowedPages.has(pageKey));
    if (firstAllowedPage) {
      window.location.replace(pageRoutes[firstAllowedPage]);
      return;
    }

    if (main) main.style.display = "none";
    if (navigation) navigation.innerHTML = '<p class="nav-label">No pages assigned</p>';
  }

  applyPageAccess().catch((error) => console.error("Page access error:", error));
})();
