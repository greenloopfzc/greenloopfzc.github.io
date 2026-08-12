(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const notificationTargets = [
    { key: "initial_qc", selector: '[data-module="Initial QC"], a[href="initial-qc.html"]', label: "Initial QC jobs waiting" },
    { key: "parts", selector: '[data-module="Parts"], a[href="parts.html"]', label: "Parts requests waiting" },
    { key: "laboratory", selector: '[data-module="Laboratory"], a[href="laboratory.html"]', label: "Laboratory jobs waiting" },
    { key: "glass", selector: '[data-module="Glass"], a[href="glass.html"]', label: "Glass jobs waiting" },
    { key: "final_qc", selector: '[data-module="Final QC"], a[href="final-qc.html"]', label: "Final QC jobs waiting" },
    { key: "production", selector: '[data-module="Production"], a[href="production.html"]', label: "Production jobs waiting" }
  ];
  let client;

  function getClient() {
    return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
  }

  function renderBadge(target, count) {
    document.querySelectorAll(target.selector).forEach((item) => {
      let badge = item.querySelector(".workflow-notification-badge");
      if (count > 0) {
        if (!badge) {
          badge = document.createElement("span");
          badge.className = "workflow-notification-badge";
          badge.setAttribute("aria-label", target.label);
          item.append(badge);
        }
        badge.textContent = count > 99 ? "99+" : String(count);
        badge.hidden = false;
      } else if (badge) {
        badge.hidden = true;
      }
    });
  }

  async function refreshPartsNotification() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) return;
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) return;
    const { data, error } = await getClient().rpc("get_workflow_notification_counts");
    if (!error) {
      notificationTargets.forEach((target) => renderBadge(target, Number(data?.[target.key]) || 0));
      return;
    }

    const fallback = await getClient().rpc("get_pending_part_request_count");
    if (!fallback.error) {
      const partsTarget = notificationTargets.find((target) => target.key === "parts");
      renderBadge(partsTarget, Number(fallback.data) || 0);
    }
  }

  refreshPartsNotification().catch(() => {});
  window.setInterval(() => refreshPartsNotification().catch(() => {}), 20000);
})();
