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
    const links = document.querySelectorAll(".sidebar-nav a");

    return [...links].find((link) => {
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

    badge.textContent = pendingCount > 99
      ? "99+"
      : String(pendingCount);

    badge.hidden = pendingCount === 0;
    badge.title = `${pendingCount} part request(s) waiting`;
  }

  function initialize() {
    reorderSidebar();
    refreshPartsNotification();

    window.clearInterval(refreshTimer);

    refreshTimer = window.setInterval(
      refreshPartsNotification,
      30000
    );

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) {
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
