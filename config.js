// GreenLoop audit release: 20260918-audit-2
window.GREENLOOP_CONFIG = Object.freeze({
  supabaseUrl: "https://prypklagfznpdlleldll.supabase.co",
  supabaseAnonKey: "sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt"
});

// Every page uses the same client and storage choice. Session-only sign-in must
// survive page navigation without leaving the token in persistent storage.
(() => {
  let sharedClient;
  // Publish only a token after a confirmed write. Every tab reads its own
  // authorized counts; no IMEI, payload or credentials go into this signal.
  const announceWorkflowCommit = () => {
    try { document.dispatchEvent(new Event('greenloop:workflow-committed')); } catch (_) {}
    try { window.localStorage.setItem('greenloop-workflow-commit-v1', `${Date.now()}-${Math.random()}`); } catch (_) {}
  };
  const modeKey = "greenloop-session-mode";
  const authKey = `sb-${new URL(window.GREENLOOP_CONFIG.supabaseUrl).hostname.split(".")[0]}-auth-token`;
  const authKeys = [authKey, `${authKey}-code-verifier`, `${authKey}-user`];
  const tvKey = "greenloop-tv-session-v1";
  const changeKey = "greenloop-app-session-change-v1";
  const epochKey = "greenloop-app-session-epoch-v1";
  const currentEpoch = () => { try { return window.localStorage.getItem(changeKey); } catch (_) { return null; } };
  let clientEpoch = currentEpoch();
  // A token-free signal also reaches TV tabs using sessionStorage. Credentials
  // remain solely in the storage chosen for the application session.
  const clearTvSession = () => {
    [window.localStorage, window.sessionStorage].forEach((store) => {
      try { store.removeItem(tvKey); store.removeItem(`${tvKey}-refresh`); } catch (_) {}
    });
    try { window.localStorage.setItem(changeKey, `${Date.now()}-${Math.random()}`); } catch (_) {}
    clientEpoch = currentEpoch();
    try {
      if (clientEpoch === null) window.sessionStorage.removeItem(epochKey);
      else window.sessionStorage.setItem(epochKey, clientEpoch);
    } catch (_) {}
  };
  const sessionUser = (value) => {
    try { return JSON.parse(value)?.user?.id || null; } catch (_) { return null; }
  };
  const storage = () => {
    if (window.sessionStorage.getItem(modeKey) !== "session") return window.localStorage;
    // sessionStorage is cloned when a tab is opened. A shared logout/account
    // change must also expire that copied session when the old tab reloads.
    if (window.sessionStorage.getItem(epochKey) !== currentEpoch()) {
      authKeys.forEach((key) => window.sessionStorage.removeItem(key));
      window.sessionStorage.removeItem(tvKey);
    }
    return window.sessionStorage;
  };
  window.GREENLOOP_SET_REMEMBER_SESSION = (remember) => {
    clearTvSession();
    window.sessionStorage.setItem(modeKey, remember ? "local" : "session");
    const otherStorage = remember ? window.sessionStorage : window.localStorage;
    authKeys.forEach((key) => otherStorage.removeItem(key));
  };
  window.GREENLOOP_CLEAR_SESSION = () => {
    clearTvSession();
    authKeys.forEach((key) => {
      window.localStorage.removeItem(key);
      window.sessionStorage.removeItem(key);
    });
  };
  window.GREENLOOP_GET_CLIENT = () => {
    if (!sharedClient) {
      sharedClient = window.supabase.createClient(window.GREENLOOP_CONFIG.supabaseUrl, window.GREENLOOP_CONFIG.supabaseAnonKey, {
        global: { fetch: window.GREENLOOP_OFFICE && window.GREENLOOP_OFFICE.fetch },
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage: {
          getItem: (key) => authKeys.includes(key) && clientEpoch !== currentEpoch() ? null : storage().getItem(key),
          setItem: (key, value) => {
            // A refresh already running in an externally signed-out app tab
            // cannot repopulate shared credentials when its response arrives.
            if (authKeys.includes(key) && clientEpoch !== currentEpoch()) return;
            if (key === authKey && sessionUser(storage().getItem(key)) !== sessionUser(value)) clearTvSession();
            storage().setItem(key, value);
          },
          removeItem: (key) => {
            if (authKeys.includes(key) && clientEpoch !== currentEpoch()) return;
            if (key === authKey) clearTvSession();
            window.localStorage.removeItem(key); window.sessionStorage.removeItem(key);
          }
        } }
      });
      sharedClient.auth.onAuthStateChange((event, session) => {
        setTimeout(() => { if (event === 'SIGNED_OUT') window.GREENLOOP_OFFICE?.reset(); else if (session?.access_token) window.GREENLOOP_OFFICE?.check(session.access_token, () => {}); }, 0);
      });
      // Direct table mutations receive the same page guard as RPC writes.
      // Defer the query until permissions resolve, while retaining Supabase's
      // fluent .select().eq().single() API and ordinary read-only queries.
      if (typeof sharedClient.from === 'function') {
        const from=sharedClient.from.bind(sharedClient);
        sharedClient.from=(...fromArgs)=>{
          const builder=from(...fromArgs);
          return new Proxy(builder,{get(target,property){
            if(!['insert','update','upsert','delete'].includes(property)) {
              const member=target[property];return typeof member==='function'?member.bind(target):member;
            }
            return (...writeArgs)=>{
              const calls=[];let result;
              const execute=()=>result ||= (async()=>{
                await window.GREENLOOP_ACCESS_READY;
                if(!window.GREENLOOP_TABLE_WRITE_ALLOWED?.(String(fromArgs[0]),property))return {data:null,error:{code:'42501',message:'This action is not allowed for your account.'}};
                let query=target[property](...writeArgs);
                for(const [method,args] of calls)query=query[method](...args);
                const response = await query;
                if (response && !response.error) announceWorkflowCommit();
                return response;
              })();
              const guarded=new Proxy({}, {get(_target,method){
                if(['then','catch','finally'].includes(method))return (...args)=>execute()[method](...args);
                if(typeof method==='symbol')return undefined;
                return (...args)=>{calls.push([method,args]);return guarded;};
              }});
              return guarded;
            };
          }});
        };
      }
      // The deployed user-creation service also checks the caller's page
      // permission. Keep the page-level guard here for synthetic UI callbacks.
      if (typeof sharedClient.functions?.invoke === 'function') {
        const invoke = sharedClient.functions.invoke.bind(sharedClient.functions);
        sharedClient.functions.invoke = async (...args) => {
          await window.GREENLOOP_ACCESS_READY;
          if (!window.GREENLOOP_CAN?.('create_users','user_access')) return {data:null,error:{code:'42501',message:'Add Greenloop User permission is required.'}};
          return invoke(...args);
        };
      }
      const rpc = sharedClient.rpc.bind(sharedClient);
      sharedClient.rpc = async (name, ...args) => {
        // Versioned RPC requirements distinguish independent page actions.
        // The bootstrap readers must finish before accessReady can resolve.
        const bootstrap = new Set(['get_my_page_access_v2','get_my_page_access','get_my_page_capabilities_v1','get_my_damage_tv_settings_v1','get_my_partner_name_access','has_role']);
        if (!bootstrap.has(name)) {
          const requirement = window.GREENLOOP_RPC_CAPABILITY?.(name,args[0] || {});
          if (requirement) {
            await window.GREENLOOP_ACCESS_READY;
            if (!window.GREENLOOP_RPC_ALLOWED?.(name,args[0] || {})) return {data:null,error:{code:'42501',message:'This action is not allowed for your account.'}};
          }
        }
        const response = await rpc(name, ...args);
        if (response?.error?.code === '23505') {
          let detail;try { detail=JSON.parse(response.error.details || '{}'); } catch (_) {}
          if(detail?.reason === 'secondary_imei' && /^\d{15}$/.test(detail.primary_imei || '')) {
            const scanned=args[0]?.p_imei || args[0]?.p_imei_1 || args[0]?.p_identifier || '';
            void window.GREENLOOP_IMEI_STAGE_NOTICE?.show({imei:scanned,knownRecord:{found:true,matched_type:'secondary',primary_imei:detail.primary_imei,current_stage:null}});
          }
        }
        const rule = window.GREENLOOP_RPC_CAPABILITIES?.[name];
        if (response && !response.error && rule && !rule.read) announceWorkflowCommit();
        return response;
      };
    }
    return sharedClient;
  };
})();

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
    "Parts Inventory": "inventory.html",
    "Laboratory": "laboratory.html",
    "Lab & Glass": "laboratory.html",
    "Lab, Glass & Frame": "laboratory.html",
    "Glass": "laboratory.html",
    "Frame": "laboratory.html#frame",
    "Final QC": "final-qc.html",
    "Ready Stock": "ready-stock.html",
    "Export Boxes": "export-box.html",
    "Box Entry": "export-box.html",
    "Accounts": "accounts.html",
    "Stock Exported": "stock-exported.html",
    "Ready Stock Journey": "ready-stock-journey.html",
    "Stock Journey": "ready-stock-journey.html",
    "Reports": "reports.html",
    "User Access": "user-access.html",
    "Suspicious Activity": "suspicious-activity.html"
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
    item("IMEI Search", "imei-search.html", "⌕", page === "imei-search.html"),
    item("Dashboard", "dashboard.html", "⌘", page === "dashboard.html"),
    item("Lab Live Board", "lab-live-board.html", "▦", page === "lab-live-board.html"),
    item("Live Damage Report", "manual-damage-report.html", "▤", page === "manual-damage-report.html" || page === "damage-entry.html"),
    item("Daily Production Report", "daily-production.html", "▥", page === "daily-production.html"),
    '<p class="nav-label">Operations</p>',
    item("Stock Received", "stock-entry.html", "+", page === "stock-entry.html" || page === "receiving.html"),
    item("IMEI Entry", "imei-entry.html", "⌕", page === "imei-entry.html"),
    item("Initial QC", "initial-qc.html", "✓", page === "initial-qc.html"),
    item("Stock Return", "stock-return.html", "↩", page === "stock-return.html"),
    item("Lab & Glass", "laboratory.html", "⌁", (page === "laboratory.html" || page === "glass.html") && window.location.hash !== "#frame"),
    item("Parts", "parts.html", "▦", page === "parts.html"),
    item("Final QC", "final-qc.html", "◉", page === "final-qc.html"),
    item("Frame Department", "laboratory.html#frame", "□", page === "laboratory.html" && window.location.hash === "#frame"),
    item("Ready Stock", "ready-stock.html", "▤", page === "ready-stock.html"),
    item("Stock Journey", "ready-stock-journey.html", "≡", page === "ready-stock-journey.html"),
    '<p class="nav-label">Control</p>',
    item("Reports", "reports.html", "▤", page === "reports.html"),
    item("Suspicious Activity", "suspicious-activity.html", "◇", page === "suspicious-activity.html"),
    item("User Access", "user-access.html", "☷", page === "user-access.html")
  ].join("");

  const readyStock = navigation.querySelector('a[href="ready-stock.html"]');
  if (readyStock) {
    readyStock.insertAdjacentHTML(
      "afterend",
      `<a class="nav-item${page === "export-box.html" ? " active" : ""}" href="export-box.html"><span class="nav-icon" aria-hidden="true">&#9635;</span>Box Entry</a>` +
      item("Accounts", "accounts.html", "▣", page === "accounts.html") +
      item("Stock Exported", "stock-exported.html", "↗", page === "stock-exported.html")
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
        const client = window.GREENLOOP_GET_CLIENT();
        await client.auth.signOut({ scope: "local" });
      }
    } finally {
      try { window.GREENLOOP_CLEAR_SESSION(); } finally { window.location.replace("index.html?greeting=bye"); }
    }
  });
})();

// Cross-page lookup opens on demand; table search stays beside its table.
(() => {
  const topbar = document.querySelector(".topbar");
  if (!topbar) return;
  const operationalPages = new Set(["stock-entry.html", "imei-entry.html", "initial-qc.html", "parts.html", "inventory.html", "laboratory.html", "final-qc.html", "ready-stock.html", "export-box.html", "stock-out.html"]);
  const file = (location.pathname.split("/").pop() || "").toLowerCase();
  topbar.querySelectorAll(".search-box").forEach(search => {
    const dashboardInput = search.querySelector("#dashboard-search");
    if (dashboardInput) {
      const field = document.createElement("label"); field.className = "table-filter-field table-filter-search dashboard-local-search";
      const caption = document.createElement("span"); caption.textContent = "Search queue";
      dashboardInput.placeholder = "Search IMEI, job or model…"; field.append(caption, dashboardInput);
      document.querySelector(".priority-table-wrap")?.prepend(field);
    }
    search.remove();
  });
  window.GREENLOOP_MOUNT_HEADER_LOOKUP = (form, permissionPage) => {
    const host = document.createElement("div"); host.className = "gl-header-lookup"; host.hidden = true;
    const trigger = document.createElement("button"); trigger.type = "button"; trigger.className = "secondary-button gl-header-search-trigger";
    trigger.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="10" cy="10" r="6"/><path d="m15 15 6 6"/></svg><span>Find record</span>';
    trigger.setAttribute("aria-haspopup", "dialog"); trigger.setAttribute("aria-expanded", "false");
    const panel = document.createElement("div"); panel.className = "gl-header-search-panel"; panel.id = form.id + "-panel"; panel.hidden = true;
    panel.setAttribute("role", "dialog"); panel.setAttribute("aria-label", "Find a record"); trigger.setAttribute("aria-controls", panel.id);
    const close = document.createElement("button"); close.className = "gl-header-search-close"; close.type = "button"; close.textContent = "Close";
    panel.append(form, close); host.append(trigger, panel);
    topbar.insertBefore(host, topbar.querySelector(".topbar-actions"));
    function dismiss(restoreFocus = false) {
      if (panel.hidden) return;
      panel.hidden = true; trigger.setAttribute("aria-expanded", "false");
      form.dispatchEvent(new Event("greenloop:close-lookup"));
      if (restoreFocus) trigger.focus();
    }
    function allowedPage() { return window.GREENLOOP_PAGE_ACCESS ? permissionPage() : null; }
    function sync() {
      const page = allowedPage(); host.hidden = !page;
      for (const control of [form, trigger]) { control.dataset.capability = "search"; control.dataset.capabilityPage = page || window.GREENLOOP_PAGE_ACCESS?.pageKey || "imei_search"; }
      // The access resolver can switch from the cross-page finder to local
      // records. Reconcile only this finder's controls after that decision.
      if (page) for (const control of [trigger, ...form.querySelectorAll('input,button')]) {
        const required = window.GREENLOOP_CONTROL_CAPABILITY?.(control);
        if (control.dataset.viewOnlyLocked === 'true' && required && window.GREENLOOP_CAPABILITY_ALLOWED?.(required)) {
          control.disabled = false; control.removeAttribute('aria-disabled'); delete control.dataset.viewOnlyLocked;
          if (control.title === 'Access not granted') control.removeAttribute('title');
        }
      }
      if (!page) dismiss();
    }
    trigger.addEventListener("click", () => {
      if (!allowedPage()) return;
      if (!panel.hidden) { dismiss(); return; }
      panel.hidden = false; trigger.setAttribute("aria-expanded", "true"); form.querySelector("input")?.focus();
    });
    close.addEventListener("click", () => dismiss(true));
    window.addEventListener("keydown", event => { if (event.key === "Escape" && !panel.hidden && host.contains(event.target)) { event.preventDefault(); event.stopImmediatePropagation(); dismiss(true); } }, true);
    document.addEventListener("pointerdown", event => { if (!host.contains(event.target) && !event.target.closest?.(".gl-record-search-list")) dismiss(); });
    window.addEventListener("greenloop:access-ready", sync); queueMicrotask(sync);
    return host;
  };
  // Operational pages retain their in-page IMEI selection handler below.
  if (operationalPages.has(file) || file === "imei-search.html") return;
  const search = document.createElement("form"); search.id = "global-record-lookup"; search.className = "global-imei-search";
  search.innerHTML = '<label for="global-imei-search">Find a device or receipt</label><input id="global-imei-search" type="search" autocomplete="off" maxlength="120" placeholder="IMEI, invoice, device or model">';
  const host = window.GREENLOOP_MOUNT_HEADER_LOOKUP(search, () => window.GREENLOOP_CAN?.("search", "imei_search") ? "imei_search" : null);
  const connect = () => {
    const widget = window.GREENLOOP_RECORD_SEARCH.attach(search.querySelector("input"));
    search.addEventListener("greenloop:close-lookup", () => widget.close());
    search.addEventListener("submit", event => { event.preventDefault(); if (!host.hidden) widget.search({selectExact:true}); });
  };
  if (window.GREENLOOP_RECORD_SEARCH) connect();
  else window.addEventListener("greenloop:record-search-ready", connect, {once:true});
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
    imei_search: "imei-search.html",
    initial_qc: "initial-qc.html",
    supplier_returns: "stock-return.html",
    lab_glass: "laboratory.html",
    lab_live_board: "lab-live-board.html",
    manual_damage_report: "manual-damage-report.html",
    tv_manual_entry: "damage-entry.html",
    damage_report: "tv.html",
    daily_production: "daily-production.html",
    frame_department: "laboratory.html#frame",
    parts: "parts.html",
    inventory: "inventory.html",
    final_qc: "final-qc.html",
    ready_stock: "ready-stock.html",
    export_boxes: "export-box.html",
    accounts: "accounts.html",
    stock_exported: "stock-exported.html",
    ready_stock_journey: "ready-stock-journey.html",
    reports: "reports.html",
    user_access: "user-access.html",
    suspicious_activity: "suspicious-activity.html"
  });

  const filePageKeys = Object.freeze({
    "dashboard.html": "overview",
    "stock-entry.html": "stock_received",
    "receiving.html": "stock_received",
    "imei-entry.html": "imei_entry",
    "imei-search.html": "imei_search",
    "initial-qc.html": "initial_qc",
    "stock-return.html": "supplier_returns",
    "laboratory.html": "lab_glass",
    "lab-live-board.html": "lab_live_board",
    "manual-damage-report.html": "manual_damage_report",
    "damage-entry.html": "tv_manual_entry",
    "tv.html": "damage_report",
    "daily-production.html": "daily_production",
    "live-tv.html": "lab_live_board",
    "glass.html": "lab_glass",
    "parts.html": "parts",
    "inventory.html": "inventory",
    "final-qc.html": "final_qc",
    "ready-stock.html": "ready_stock",
    "export-box.html": "export_boxes",
    "accounts.html": "accounts",
    "stock-exported.html": "stock_exported",
    "packing.html": "export_boxes",
    "stock-out.html": "export_boxes",
    "ready-stock-journey.html": "ready_stock_journey",
    "reports.html": "reports",
    "user-access.html": "user_access",
    "suspicious-activity.html": "suspicious_activity"
  });

  function pageKeyForLink(link) {
    const target = new URL(link.href, window.location.href);
    const fileName = target.pathname.split("/").pop().toLowerCase();
    if (fileName === "laboratory.html" && target.hash.toLowerCase() === "#frame") return "frame_department";
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
    main.innerHTML = '<div class="page-content"><section class="panel"><p class="form-message error-message">Your page permissions could not be loaded. Refresh to retry, or return to sign-in.</p><a class="secondary-button" href="index.html">Return to sign-in</a><button type="button" id="retry-page-access" class="secondary-button">Retry</button></section></div>';
    main.querySelector("#retry-page-access").addEventListener("click", () => window.location.reload());
  }

  async function applyPageAccess() {
    const currentFile = (window.location.pathname.split("/").pop() || "dashboard.html").toLowerCase();
    const currentPageKey = currentFile === "laboratory.html" && window.location.hash.toLowerCase() === "#frame"
      ? "frame_department"
      : filePageKeys[currentFile];
    if (!currentPageKey) return;

    const navigation = document.querySelector(".sidebar-nav");
    const main = document.querySelector(".app-main");
    lockApplication(navigation, main);

    if (!window.supabase || !window.GREENLOOP_CONFIG?.supabaseUrl || !window.GREENLOOP_CONFIG?.supabaseAnonKey) {
      showAccessError(navigation, main);
      return;
    }

    const client = window.GREENLOOP_GET_CLIENT();
    const { data: sessionData } = await client.auth.getSession();
    if (!sessionData?.session) {
      window.location.replace("index.html");
      return;
    }

    if (!window.GREENLOOP_OFFICE || !(await window.GREENLOOP_OFFICE.check(sessionData.session.access_token))) return;

    let { data, error } = await client.rpc("get_my_page_access_v2");
    let accessRows;
    if (error && (error.code === "PGRST202" || String(error.message || "").includes("get_my_page_access_v2"))) {
      ({ data, error } = await client.rpc("get_my_page_access"));
      accessRows = (Array.isArray(data) ? data : []).map((pageKey) => ({ page_key: pageKey, access_level: "view" }));
    } else {
      accessRows = Array.isArray(data) ? data : [];
    }
    if (error) {
      console.error("Page permissions could not be loaded:", error.message);
      showAccessError(navigation, main);
      return;
    }

    const tvSettings=await client.rpc("get_my_damage_tv_settings_v1");
    if(tvSettings.error || !tvSettings.data || typeof tvSettings.data.tv_only!=="boolean"){showAccessError(navigation,main);return;}
    if(tvSettings.data.tv_only){window.location.replace("tv.html");return;}

    const capabilities = await client.rpc("get_my_page_capabilities_v1");
    if (capabilities.error || !capabilities.data || Array.isArray(capabilities.data)
      || typeof capabilities.data !== "object" || !window.GREENLOOP_CAN
      || Object.values(capabilities.data).some(value => !Array.isArray(value) || value.some(cap => typeof cap !== "string"))) {
      showAccessError(navigation,main); return;
    }
    window.GREENLOOP_CAPABILITIES = Object.freeze(Object.fromEntries(Object.entries(capabilities.data).map(([key,value]) => [key,Object.freeze([...value])])));
    const accessByPage = new Map(Object.entries(window.GREENLOOP_CAPABILITIES)
      .filter(([key,caps]) => !window.GREENLOOP_PERMISSION_CATALOG?.byPage[key]?.virtual && caps.includes("view"))
      .map(([key]) => [key,window.GREENLOOP_HAS_WRITE(key) ? "edit" : "view"]));
    // Request, approval and handover staff share one screen. Each action is
    // still authorized independently by the Supplier Returns database API.
    const stockReturnLevels = ["supplier_returns", "supplier_return_approval", "supplier_return_handover"]
      .map((key) => accessByPage.get(key));
    const stockReturnAccess = stockReturnLevels.includes("edit") ? "edit"
      : stockReturnLevels.includes("view") ? "view" : null;
    if (stockReturnAccess) accessByPage.set("supplier_returns", stockReturnAccess);
    window.GREENLOOP_CAN_VIEW_STOCK_RETURN = Boolean(stockReturnAccess);
    document.querySelectorAll("[data-stock-return-link]").forEach((link) => {
      link.hidden = !stockReturnAccess;
    });
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
    // This is a navigation hub, not another saved permission. Either manual
    // damage capability opens it; each destination still enforces its own key.
    if (["damage_report", "tv_manual_entry"].some((key) => accessByPage.has(key))) {
      accessByPage.set("manual_damage_report", ["damage_report","tv_manual_entry"].some(key=>accessByPage.get(key)==="edit") ? "edit" : "view");
    }
    const allowedPages = new Set(accessByPage.keys());
    document.querySelectorAll("a[data-page-access]").forEach((link) => {
      link.hidden = !allowedPages.has(link.dataset.pageAccess);
    });
    window.GREENLOOP_CAN_SEARCH = allowedPages.has("imei_search");
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
      window.GREENLOOP_ENFORCE_CAPABILITIES?.(main);
      unlockApplication(main);
      return;
    }

    const firstAllowedPage = Object.keys(pageRoutes).find((pageKey) => allowedPages.has(pageKey));
    if (firstAllowedPage) {
      window.location.replace(pageRoutes[firstAllowedPage]);
      return;
    }

    if (main) {
      unlockApplication(main);
      const content = main.querySelector(".page-content");
      if (content) content.innerHTML = '<section class="panel"><h1>No pages assigned</h1><p>Please contact your administrator to enable your pages. You can use Logout above to switch accounts.</p></section>';
    }
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
    scanner.innerHTML = '<strong>⌕ Find record</strong><input type="search" autocomplete="off" maxlength="120" aria-label="Search IMEI, invoice, device number or phone details" placeholder="IMEI, invoice, device number or details"><button type="button" data-search-read-only hidden>Show all lines</button><small>Type any part of a number or name, then choose a matching record.</small>';
    window.GREENLOOP_MOUNT_HEADER_LOOKUP?.(scanner, () => window.GREENLOOP_CAN?.("search", "imei_search") ? "imei_search" : window.GREENLOOP_CAN?.("search") ? window.GREENLOOP_PAGE_ACCESS.pageKey : null);
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
    const showLoadedRow = (row, label) => {
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
      scannerStatus.textContent = `Showing ${label} in this page.`;
    };
    window.addEventListener("greenloop:imei-scan", (event) => {
      const imei = normalizeImei(event.detail?.imei);
      if (!/^\d{15}$/.test(imei)) return;
      const row = findLoadedImeiRow(imei);
      if (!row) return;
      event.preventDefault();
      showLoadedRow(row, `IMEI ${imei}`);
    });
    clearFilter.addEventListener("click", () => {
      filteredTable?.querySelectorAll("tbody tr").forEach((row) => { row.hidden = false; });
      filteredTable = null;
      clearFilter.hidden = true;
      scannerStatus.textContent = "All current page lines are shown.";
    });
    let searchWidget;
    scanner.addEventListener("greenloop:close-lookup", () => searchWidget?.close());
    const connectSearch = () => {
      const search = window.GREENLOOP_RECORD_SEARCH;
      if (!search || searchWidget) return;
      searchWidget = search.attach(input, {
        lookup: async (term, offset = 0) => {
          await window.GREENLOOP_ACCESS_READY;
          if (window.GREENLOOP_CAN?.("search", "imei_search")) return search.lookup(term, offset);
          // A page-only user can search only records already visible to that
          // page. Never call the cross-page lookup without its permission.
          const records = [...anchor.querySelectorAll("tbody tr")].map((row, index) => {
            const fields = [...row.querySelectorAll("input, select")].map(field => field.value.trim()).filter(Boolean);
            const text = [...row.cells].map(cell => cell.textContent.trim()).join(" ").replace(/\s+/g, " ").trim();
            const imei = fields.find(value => /^\d{15}$/.test(value)) || (text.match(/(?:^|\D)(\d{15})(?!\d)/) || [])[1] || "";
            const device = (text.match(/\bDEV-[A-Z0-9-]+\b/i) || [])[0] || "";
            const invoice = (text.match(/\bINV-[A-Z0-9-]+\b/i) || [])[0] || "";
            return { kind: "device", id: `loaded-row-${index}`, identifier: imei || device || invoice,
              imei_1: imei, device_number: device, invoice_number: invoice,
              title: imei || device || invoice || text.slice(0, 100), search_values: [text, ...fields], _loadedRow: row };
          }).filter(record => record.identifier);
          return search.localLookup(records, term);
        },
        onSelect: (record) => {
          input.value = record.identifier || record.imei_1 || "";
          if (record._loadedRow?.isConnected) {
            showLoadedRow(record._loadedRow, input.value);
            return;
          }
          const imei = String(record.imei_1 || "");
          if (record.kind === "device" && /^\d{15}$/.test(imei)) {
            const notHandled = window.dispatchEvent(new CustomEvent("greenloop:imei-scan", { cancelable: true, detail: { imei } }));
            if (!notHandled) return;
          }
          search.openRecord(record);
        }
      });
    };
    if (window.GREENLOOP_RECORD_SEARCH) connectSearch();
    else window.addEventListener("greenloop:record-search-ready", connectSearch, { once: true });
    scanner.addEventListener("submit", (event) => {
      event.preventDefault();
      searchWidget?.search({ selectExact: true });
    });
  }

  installQuickImeiScanner();

  window.GREENLOOP_CAN_VIEW_PARTNER_NAMES = false;
  window.GREENLOOP_CAN_VIEW_STOCK_RETURN = false;
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
      showAccessError(document.querySelector(".sidebar-nav"), document.querySelector(".app-main"));
      return null;
    });
})();
