(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  let supabaseClient;
  let refreshTimer;

  function getClient() {
    if (!supabaseClient && window.supabase) {
      supabaseClient = window.supabase.createClient(
        config.supabaseUrl,
        config.supabaseAnonKey
      );
    }

    return supabaseClient;
  }

  function findSidebarLink(fileName) {
    return [...document.querySelectorAll(".sidebar-nav a")].find((link) => {
      const url = new URL(link.href, window.location.href);
      return url.pathname.endsWith(`/${fileName}`);
    });
  }

  function reorderSidebar() {
    const initialQcLink = findSidebarLink("initial-qc.html");
    const laboratoryLink = findSidebarLink("laboratory.html");
    const partsLink = findSidebarLink("parts.html");

    if (!initialQcLink || !laboratoryLink || !partsLink) return;

    const parent = initialQcLink.parentElement;

    if (
      laboratoryLink.parentElement !== parent ||
      partsLink.parentElement !== parent
    ) {
      return;
    }

    initialQcLink.after(laboratoryLink);
    laboratoryLink.after(partsLink);
  }

  function updateDashboardGreeting() {
    const greetingHeading = [...document.querySelectorAll("h1")].find(
      (heading) =>
        /good\s+(morning|afternoon|evening|night)/i.test(
          heading.textContent
        )
    );

    if (!greetingHeading) return;

    const hour = new Date().getHours();

    let greeting = "Good night";

    if (hour >= 5 && hour < 12) {
      greeting = "Good morning";
    } else if (hour >= 12 && hour < 17) {
      greeting = "Good afternoon";
    } else if (hour >= 17 && hour < 22) {
      greeting = "Good evening";
    }

    const currentText = greetingHeading.textContent.trim();

    const userName =
      currentText
        .replace(
          /good\s+(morning|afternoon|evening|night)\s*,?\s*/i,
          ""
        )
        .replace(/\.$/, "")
        .trim() || "Admin";

    greetingHeading.textContent = `${greeting}, ${userName}.`;
  }

  function createPartsBadge() {
    const partsLink = findSidebarLink("parts.html");

    if (!partsLink) return null;

    let badge = partsLink.querySelector(
      "[data-parts-notification-badge]"
    );

    if (!badge) {
      badge = document.createElement("span");
      badge.dataset.partsNotificationBadge = "true";
      badge.hidden = true;

      Object.assign(badge.style, {
        minWidth: "22px",
        height: "22px",
        marginLeft: "auto",
        border: "2px solid white",
        borderRadius: "999px",
        padding: "0 6px",
        color: "white",
        background: "#dc2f25",
        boxShadow: "0 2px 7px rgba(160, 25, 18, 0.35)",
        fontSize: "11px",
        fontWeight: "800",
        lineHeight: "18px",
        textAlign: "center"
      });

      partsLink.appendChild(badge);
    }

    return badge;
  }

  function readCount(data) {
    if (Array.isArray(data)) {
      const firstItem = data[0];

      if (typeof firstItem === "object" && firstItem !== null) {
        return Number(
          firstItem.get_pending_part_request_count ??
          firstItem.pending_count ??
          0
        );
      }

      return Number(firstItem || 0);
    }

    if (typeof data === "object" && data !== null) {
      return Number(
        data.get_pending_part_request_count ??
        data.pending_count ??
        0
      );
    }

    return Number(data || 0);
  }

  async function refreshPartsNotification() {
    const badge = createPartsBadge();
    const client = getClient();

    if (!badge || !client) return;

    const { data: sessionData } = await client.auth.getSession();

    if (!sessionData?.session) {
      badge.hidden = true;
      return;
    }

    const { data, error } = await client.rpc(
      "get_pending_part_request_count"
    );

    if (error) {
      badge.hidden = true;
      return;
    }

    const pendingCount = Math.max(0, readCount(data));

    badge.textContent =
      pendingCount > 99 ? "99+" : String(pendingCount);

    badge.hidden = pendingCount === 0;
    badge.title = `${pendingCount} part request(s) waiting`;
  }

  function markManualImeiAction(event) {
    if (!event.isTrusted) return;

    const target = event.target;

    if (
      target.matches("input[id*='imei'], input[placeholder*='IMEI']") ||
      target.matches(
        "#pending-imei-select, #lab-step-select, #final-qc-step-select, #glass-step-select, #frame-step-select"
      )
    ) {
      manualImeiAction = true;
    }
  }

  function clearAutomaticImeiSelection() {
    if (manualImeiAction) return;

    const automaticDropdowns = document.querySelectorAll(
      "#pending-imei-select, #lab-step-select, #final-qc-step-select, #glass-step-select, #frame-step-select"
    );

    automaticDropdowns.forEach((dropdown) => {
      if (dropdown.options.length > 0) {
        dropdown.selectedIndex = 0;
      }
    });

    const automaticImeiInputs = document.querySelectorAll(
      "input[id*='imei'][data-auto-picked='true']"
    );

    automaticImeiInputs.forEach((input) => {
      input.value = "";
      input.removeAttribute("data-auto-picked");
    });

    const workspaces = document.querySelectorAll(
      "#qc-workspace, #lab-workspace, #final-qc-workspace, #glass-workspace, #frame-workspace"
    );

    workspaces.forEach((workspace) => {
      workspace.hidden = true;
    });
  }

  function startManualImeiOnlyMode() {
    document.addEventListener("keydown", markManualImeiAction, true);
    document.addEventListener("input", markManualImeiAction, true);
    document.addEventListener("change", markManualImeiAction, true);
    document.addEventListener("paste", markManualImeiAction, true);

    let checksRemaining = 40;

    window.clearInterval(autoPickTimer);

    autoPickTimer = window.setInterval(() => {
      clearAutomaticImeiSelection();

      checksRemaining -= 1;

      if (checksRemaining <= 0 || manualImeiAction) {
        window.clearInterval(autoPickTimer);
      }
    }, 250);
  }

  function initialize() {
    reorderSidebar();
    updateDashboardGreeting();
    refreshPartsNotification();

    window.clearInterval(refreshTimer);

    refreshTimer = window.setInterval(() => {
      updateDashboardGreeting();
      refreshPartsNotification();
    }, 30000);

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) {
        updateDashboardGreeting();
        refreshPartsNotification();
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initialize);
  } else {
    initialize();
  }
})();
