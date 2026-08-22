window.GREENLOOP_CONFIG = Object.freeze({
  supabaseUrl: "https://prypklagfznpdlleldll.supabase.co",
  supabaseAnonKey: "sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt"
});

// Applied after every page stylesheet so no individual table can override the
// shared centred layout for its headings and cell values.
(() => {
  if (document.querySelector("#greenloop-table-centering")) return;
  const style = document.createElement("style");
  style.id = "greenloop-table-centering";
  style.textContent = `
    .app-page table th, .app-page table td { text-align: center !important; }
    .app-page table input:not([type="checkbox"]):not([type="radio"]),
    .app-page table select,
    .app-page table textarea { text-align: center !important; }
  `;
  document.head.append(style);
})();

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
    item("Lab Live Board", "lab-live-board.html", "▦", page === "lab-live-board.html"),
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
    lab_live_board: "lab-live-board.html",
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
    "lab-live-board.html": "lab_live_board",
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
      const descendants = root.querySelectorAll
        ? root.querySelectorAll("button, input[type='submit'], input[type='button']")
        : [];
      controls.push(...descendants);
      controls.forEach((control) => {
        if (isMutationControl(control)) {
          // Do not continuously change the native `disabled` property. Several
          // page modules update that property while loading; observing and
          // rewriting it caused a feedback loop that froze view-only accounts.
          control.setAttribute("aria-disabled", "true");
          control.title = "View-only access: entries and changes are disabled.";
          control.dataset.viewOnlyLocked = "true";
          control.style.opacity = "0.55";
          control.style.cursor = "not-allowed";
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
      change.addedNodes.forEach((node) => {
        if (node.nodeType === Node.ELEMENT_NODE) lockControls(node);
      });
    })).observe(document.body, { childList: true, subtree: true });

    document.addEventListener("click", (event) => {
      const control = event.target.closest?.("button, input[type='submit'], input[type='button']");
      if (!isMutationControl(control)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    }, true);

    document.addEventListener("submit", (event) => {
      const formControls = event.target.querySelectorAll
        ? [...event.target.querySelectorAll("button, input[type='submit'], input[type='button']")]
        : [];
      if (formControls.some(isMutationControl)) {
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
    const { data: partnerNameAccess, error: partnerNameError } = await client.rpc("get_my_partner_name_access");
    let partnerNameValue = partnerNameAccess;
    if (Array.isArray(partnerNameValue)) partnerNameValue = partnerNameValue[0];
    if (partnerNameValue && typeof partnerNameValue === "object") {
      partnerNameValue = partnerNameValue.can_view ?? partnerNameValue.allowed ?? Object.values(partnerNameValue)[0];
    }
    window.GREENLOOP_CAN_VIEW_PARTNER_NAMES = !partnerNameError
      && (partnerNameValue === true || String(partnerNameValue ?? "").trim().toLowerCase() === "true");
    window.GREENLOOP_PARTNER_LABEL = (code, name, fallback = "-") => {
      const safeCode = String(code || "").trim();
      const safeName = String(name || "").trim();
      if (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && safeName) return [safeCode, safeName].filter(Boolean).join(" - ");
      return safeCode || fallback;
    };
    window.GREENLOOP_SUPPLIER_RECEIPT_LABEL = (code, quantity, name, fallback = "-") => {
      const safeCode = String(code || "").trim();
      const safeName = String(name || "").trim();
      const parsedQuantity = Number.parseInt(quantity, 10);
      const receiptCode = safeCode && !/-\(\d+\)$/.test(safeCode) && Number.isInteger(parsedQuantity) && parsedQuantity > 0
        ? `${safeCode}-(${parsedQuantity})`
        : safeCode;
      return window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && safeName
        ? [receiptCode, safeName].filter(Boolean).join(" ")
        : (receiptCode || fallback);
    };
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

  function installQuickImeiScanner() {
    const file = (window.location.pathname.split("/").pop() || "").toLowerCase();
    const operationalPages = new Set([
      "stock-entry.html", "imei-entry.html", "initial-qc.html", "parts.html", "inventory.html",
      "laboratory.html", "final-qc.html", "ready-stock.html", "export-box.html", "stock-out.html"
    ]);
    if (!operationalPages.has(file) || document.querySelector("#greenloop-quick-imei-scanner")) return;
    const main = document.querySelector(".app-main");
    const anchor = main?.querySelector(".page-content");
    if (!main || !anchor) return;
    const style = document.createElement("style");
    style.textContent = ".greenloop-quick-scan{display:flex;align-items:center;gap:10px;margin:0 0 14px;border:1px solid #cfe4d6;border-radius:11px;padding:9px 13px;background:#f7fcf8}.greenloop-quick-scan strong{color:#176c4d;font-size:.76rem;white-space:nowrap}.greenloop-quick-scan input{width:min(340px,100%);min-height:35px;border:1px solid #bcd8c7;border-radius:7px;padding:0 10px;font:inherit;font-size:.78rem}.greenloop-quick-scan small{color:#718178;font-size:.68rem}.greenloop-quick-scan button{min-height:35px;border:1px solid #bcd8c7;border-radius:7px;padding:0 10px;background:#fff;color:#176c4d;font:700 .72rem/1 inherit}.greenloop-imei-match{outline:3px solid #1a8a60!important;outline-offset:-3px;background:#ecfaf1!important;transition:background .2s,outline .2s}@media(max-width:650px){.greenloop-quick-scan{align-items:stretch;flex-direction:column}.greenloop-quick-scan input{width:100%}}";
    document.head.append(style);
    const scanner = document.createElement("form");
    scanner.id = "greenloop-quick-imei-scanner";
    scanner.className = "greenloop-quick-scan";
    scanner.innerHTML = '<strong>⌁ Scan IMEI</strong><input inputmode="numeric" autocomplete="off" maxlength="15" placeholder="Scan phone barcode / IMEI"><button type="button" hidden>Show all lines</button><small>Scans the current phone without loading the full queue.</small>';
    anchor.prepend(scanner);
    const input = scanner.querySelector("input");
    const clearFilter = scanner.querySelector("button");
    const scannerStatus = scanner.querySelector("small");
    let filteredTable = null;
    const normalizeImei = (value) => String(value || "").replace(/\D/g, "").slice(0, 15);
    const findLoadedImeiRow = (imei) => [...document.querySelectorAll("tbody tr")].find((row) => {
      const inputMatch = [...row.querySelectorAll("input")].some((field) => normalizeImei(field.value) === imei);
      const textMatches = (row.textContent.match(/\d{15}/g) || []).some((value) => value === imei);
      return inputMatch || textMatches;
    });
    window.addEventListener("greenloop:imei-scan", (event) => {
      const imei = normalizeImei(event.detail?.imei);
      if (!/^\d{15}$/.test(imei)) return;
      const row = findLoadedImeiRow(imei);
      if (!row) return;
      event.preventDefault();
      const table = row.closest("table");
      table?.querySelectorAll("tbody tr").forEach((item) => { item.hidden = item !== row; });
      filteredTable = table;
      clearFilter.hidden = false;
      row.classList.remove("greenloop-imei-match");
      window.requestAnimationFrame(() => row.classList.add("greenloop-imei-match"));
      window.setTimeout(() => row.classList.remove("greenloop-imei-match"), 4500);
      row.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
      row.setAttribute("tabindex", "-1");
      row.focus({ preventScroll: true });
      scannerStatus.textContent = `Showing only IMEI ${imei} in this page.`;
    });
    clearFilter.addEventListener("click", () => {
      filteredTable?.querySelectorAll("tbody tr").forEach((row) => { row.hidden = false; });
      filteredTable = null;
      clearFilter.hidden = true;
      scannerStatus.textContent = "All current page lines are shown.";
    });
    input.addEventListener("input", () => {
      input.value = input.value.replace(/\D/g, "").slice(0, 15);
      if (input.value.length === 15) scanner.requestSubmit();
    });
    scanner.addEventListener("submit", (event) => {
      event.preventDefault();
      const imei = input.value.trim();
      if (!/^\d{15}$/.test(imei)) return;
      const notHandled = window.dispatchEvent(new CustomEvent("greenloop:imei-scan", { cancelable: true, detail: { imei } }));
      if (notHandled) scannerStatus.textContent = "This IMEI is not in the current page's loaded lines.";
      input.value = "";
    });
  }

  installQuickImeiScanner();

  window.GREENLOOP_CAN_VIEW_PARTNER_NAMES = false;
  window.GREENLOOP_PARTNER_LABEL = (code, name, fallback = "-") => {
    const safeCode = String(code || "").trim();
    const safeName = String(name || "").trim();
    if (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && safeName) return [safeCode, safeName].filter(Boolean).join(" - ");
    return safeCode || fallback;
  };
  window.GREENLOOP_SUPPLIER_RECEIPT_LABEL = (code, quantity, name, fallback = "-") => {
    const safeCode = String(code || "").trim();
    const safeName = String(name || "").trim();
    const parsedQuantity = Number.parseInt(quantity, 10);
    const receiptCode = safeCode && !/-\(\d+\)$/.test(safeCode) && Number.isInteger(parsedQuantity) && parsedQuantity > 0
      ? `${safeCode}-(${parsedQuantity})`
      : safeCode;
    return window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && safeName
      ? [receiptCode, safeName].filter(Boolean).join(" ")
      : (receiptCode || fallback);
  };

  window.GREENLOOP_ACCESS_READY = applyPageAccess()
    .then(() => {
      window.dispatchEvent(new CustomEvent("greenloop:access-ready", {
        detail: {
          pageAccess: window.GREENLOOP_PAGE_ACCESS || null,
          canViewPartnerNames: Boolean(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES)
        }
      }));
      return window.GREENLOOP_PAGE_ACCESS || null;
    })
    .catch((error) => {
      console.error("Page access error:", error);
      return null;
    });
})();
