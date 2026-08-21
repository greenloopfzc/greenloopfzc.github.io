(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const stages = [
    { file: "initial-qc.html", key: "initial_qc", label: "Initial QC" },
    { file: "laboratory.html", key: ["laboratory", "glass"], badgeKey: "lab_glass", label: "Lab & Glass" },
    { file: "parts.html", key: "parts", label: "Parts" },
    { file: "final-qc.html", key: "final_qc", label: "Final QC" },
    { file: "laboratory.html#frame", key: "frame", badgeKey: "frame", label: "Frame Department" }
  ];
  let supabaseClient;
  let refreshTimer;
  let autoPickTimer;
  let manualImeiAction = false;

  function getClient() {
    if (!supabaseClient && window.supabase && config.supabaseUrl && config.supabaseAnonKey) {
      supabaseClient = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    }
    return supabaseClient;
  }

  function findSidebarLink(fileName) {
    const wanted = new URL(fileName, window.location.href);
    return [...document.querySelectorAll(".sidebar-nav a")].find((link) => {
      const url = new URL(link.href, window.location.href);
      return url.pathname === wanted.pathname && url.hash === wanted.hash;
    });
  }

  function reorderSidebar() {
    // config.js owns the permanent production workflow order.
  }

  function updateDashboardGreeting() {
    const heading = [...document.querySelectorAll("h1")].find((item) => /good\s+(morning|afternoon|evening|night)/i.test(item.textContent));
    if (!heading) return;
    const hourPart = new Intl.DateTimeFormat("en-US", {
      hour: "2-digit",
      hourCycle: "h23",
      timeZone: "Asia/Dubai"
    }).formatToParts(new Date()).find((part) => part.type === "hour");
    const hour = Number(hourPart?.value || 0);
    const greeting = hour >= 5 && hour < 12 ? "Good morning" : hour < 17 && hour >= 12 ? "Good afternoon" : hour < 22 && hour >= 17 ? "Good evening" : "Good night";
    const name = heading.textContent.replace(/good\s+(morning|afternoon|evening|night)\s*,?\s*/i, "").replace(/\.$/, "").trim() || "Admin";
    heading.textContent = `${greeting}, ${name}.`;
  }

  function createBadge(stage) {
    const link = findSidebarLink(stage.file);
    if (!link) return null;
    const badgeKey = stage.badgeKey || stage.key;
    let badge = link.querySelector(`[data-workflow-badge="${badgeKey}"]`);
    if (badge) return badge;
    badge = document.createElement("span");
    badge.dataset.workflowBadge = badgeKey;
    badge.hidden = true;
    Object.assign(badge.style, {
      minWidth: "22px", height: "22px", marginLeft: "auto", border: "2px solid white",
      borderRadius: "999px", padding: "0 6px", color: "white", background: "#dc2f25",
      boxShadow: "0 2px 7px rgba(160,25,18,.35)", fontSize: "11px", fontWeight: "800",
      lineHeight: "18px", textAlign: "center"
    });
    link.appendChild(badge);
    return badge;
  }

  function hideAllBadges() {
    stages.forEach((stage) => {
      const badge = createBadge(stage);
      if (badge) badge.hidden = true;
    });
  }

  async function refreshWorkflowNotifications() {
    const client = getClient();
    if (!client) return;
    const { data: sessionData } = await client.auth.getSession();
    if (!sessionData?.session) { hideAllBadges(); return; }
    const { data, error } = await client.rpc("get_workflow_notification_counts");
    if (error) { hideAllBadges(); return; }
    const counts = Array.isArray(data) ? (data[0] || {}) : (data || {});
    stages.forEach((stage) => {
      const badge = createBadge(stage);
      if (!badge) return;
      const count = Math.max(0, Array.isArray(stage.key)
        ? stage.key.reduce((total, key) => total + Number(counts[key] || 0), 0)
        : Number(counts[stage.key] || 0));
      badge.textContent = count > 99 ? "99+" : String(count);
      badge.hidden = count === 0;
      badge.title = `${count} ${stage.label} item(s) pending`;
    });
  }

  function markManualImeiAction(event) {
    if (!event.isTrusted) return;
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (target.matches("input[id*='imei'], input[placeholder*='IMEI'], #pending-imei-select, #lab-step-select, #final-qc-step-select, #glass-step-select, #frame-step-select")) manualImeiAction = true;
  }

  function clearAutomaticImeiSelection() {
    if (manualImeiAction) return;
    document.querySelectorAll("#pending-imei-select, #lab-step-select, #final-qc-step-select, #glass-step-select, #frame-step-select").forEach((dropdown) => {
      if (dropdown.options.length > 0 && dropdown.dataset.userSelected !== "true") dropdown.selectedIndex = 0;
    });
    document.querySelectorAll("input[id*='imei'][data-auto-picked='true']").forEach((input) => {
      input.value = "";
      input.removeAttribute("data-auto-picked");
    });
  }

  function startManualImeiOnlyMode() {
    ["keydown", "input", "change", "paste"].forEach((name) => document.addEventListener(name, markManualImeiAction, true));
    let checksRemaining = 40;
    window.clearInterval(autoPickTimer);
    autoPickTimer = window.setInterval(() => {
      clearAutomaticImeiSelection();
      checksRemaining -= 1;
      if (checksRemaining <= 0 || manualImeiAction) window.clearInterval(autoPickTimer);
    }, 250);
  }

  function initialize() {
    reorderSidebar();
    updateDashboardGreeting();
    startManualImeiOnlyMode();
    refreshWorkflowNotifications();
    window.GREENLOOP_REFRESH_NOTIFICATIONS = refreshWorkflowNotifications;
    document.addEventListener("greenloop:notifications-changed", refreshWorkflowNotifications);
    window.clearInterval(refreshTimer);
    refreshTimer = window.setInterval(refreshWorkflowNotifications, 20000);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) { updateDashboardGreeting(); refreshWorkflowNotifications(); }
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize);
  else initialize();
})();
