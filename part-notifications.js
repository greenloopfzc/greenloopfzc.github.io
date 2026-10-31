(() => {
  "use strict";
  if (window.GREENLOOP_NOTIFICATIONS_STARTED) return;
  window.GREENLOOP_NOTIFICATIONS_STARTED = true;

  const config = window.GREENLOOP_CONFIG || {};
  const stages = [
    { file: "initial-qc.html", key: "initial_qc", label: "Initial QC" },
    { file: "laboratory.html", key: ["laboratory", "glass"], badgeKey: "lab_glass", label: "Lab & Glass" },
    { file: "parts.html", key: "parts", label: "Parts" },
    { file: "final-qc.html", key: "final_qc", label: "Final QC" },
    { file: "laboratory.html#frame", key: "frame", badgeKey: "frame", label: "B-DEPT" }
  ];
  let supabaseClient;
  let refreshTimer, pollTimer, channel, authSubscription;
  let inFlight = false, dirty = false, connected = false, stopped = false;
  let lastStarted = -Infinity, failures = 0, epoch = 0, userId = null;
  const minimumGap = 200; // Leading refresh, with a bounded trailing refresh for bulk writes.
  let autoPickTimer;
  let manualImeiAction = false;
  let lastCountsKey="",forceDispatch=false;

  function getClient() {
    if (!supabaseClient && window.supabase && config.supabaseUrl && config.supabaseAnonKey) {
      supabaseClient = window.GREENLOOP_GET_CLIENT();
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

  function disconnect() {
    connected = false;
    const oldChannel = channel;
    channel = null;
    if (oldChannel) Promise.resolve(getClient()?.removeChannel(oldChannel)).catch(() => {});
  }

  function pollLater() {
    window.clearTimeout(pollTimer);
    if (stopped || document.hidden) return;
    const officeOnly = window.GREENLOOP_OFFICE?.state?.mode === 'office';
    const delay = failures ? Math.min(30000, 5000 * 2 ** Math.min(failures - 1, 3)) : officeOnly ? 2000 : connected ? 30000 : 5000;
    pollTimer = window.setTimeout(refreshWorkflowNotifications, delay);
  }

  function connect(client) {
    if (window.GREENLOOP_OFFICE?.state?.mode === 'office') { disconnect(); return; }
    if (channel || !userId || document.hidden || stopped || typeof client.channel !== 'function') return;
    try {
      const next = client.channel('greenloop-workflow-notifications-v1');
      channel = next;
      next.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'workflow_notification_signal' }, () => {
        if (channel === next) {forceDispatch=true;refreshWorkflowNotifications();}
      }).subscribe((status) => {
        if (channel !== next) return;
        connected = status === 'SUBSCRIBED';
        if (connected) refreshWorkflowNotifications(); // Catch changes during connection/reconnection.
        pollLater();
      });
    } catch (_) { disconnect(); }
  }

  function refreshWorkflowNotifications(event) {
    if(event?.type)forceDispatch=true;
    dirty = true;
    if (stopped || document.hidden || inFlight || refreshTimer) return;
    refreshTimer = window.setTimeout(runRefresh, Math.max(0, minimumGap - (performance.now() - lastStarted)));
  }

  async function withDeadline(promise) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = window.setTimeout(() => reject(new Error('Notification request timed out')), 10000);
      })]);
    } finally { window.clearTimeout(timer); }
  }

  async function runRefresh() {
    refreshTimer = null;
    if (stopped || document.hidden || inFlight) return;
    const client = getClient();
    if (!client) { pollLater(); return; }
    inFlight = true; dirty = false; lastStarted = performance.now();
    const requestEpoch = epoch,notifyAfterRead=forceDispatch;forceDispatch=false;
    try {
      const { data: sessionData } = await withDeadline(client.auth.getSession());
      if (requestEpoch !== epoch || stopped || document.hidden) return;
      const nextUser = sessionData?.session?.user?.id || null;
      if (nextUser !== userId) { disconnect(); hideAllBadges(); userId = nextUser; }
      if (!userId) { hideAllBadges(); return; }
      connect(client);
      const [{data,error},partsResult]=await Promise.all([withDeadline(client.rpc('get_workflow_notification_counts')),withDeadline(client.rpc('get_parts_flow_counts_v1')).catch(()=>null)]);
      if (requestEpoch !== epoch || stopped || document.hidden) return;
      if (error) throw error;
      failures = 0;
      const updated=partsResult&&!partsResult.error?{...(Array.isArray(data)?data[0]:data),parts:partsResult.data}:data;
      if(requestEpoch!==epoch||stopped||document.hidden)return;
      renderCounts(updated);
      const countsKey=JSON.stringify(updated);if(countsKey!==lastCountsKey||notifyAfterRead){lastCountsKey=countsKey;document.dispatchEvent(new Event("greenloop:workflow-notifications-refreshed"));}
    } catch (_) {
      // A temporary connection failure must not make pending work disappear.
      failures += 1;
    } finally {
      inFlight = false;
      pollLater();
      if (dirty) refreshWorkflowNotifications();
    }
  }

  function renderCounts(data) {
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
    document.addEventListener('greenloop:workflow-committed', refreshWorkflowNotifications);
    window.addEventListener('storage', (event) => {
      if (event.key === 'greenloop-workflow-commit-v1') {forceDispatch=true;refreshWorkflowNotifications();}
    });
    window.addEventListener('online', refreshWorkflowNotifications);
    window.addEventListener('focus', refreshWorkflowNotifications);
    const auth = getClient()?.auth;
    authSubscription = auth?.onAuthStateChange?.((event, session) => {
      // Never call Supabase from inside its auth lock.
      if ((session?.user?.id || null) !== userId || event === 'SIGNED_OUT') {
        epoch += 1; userId = session?.user?.id || null;lastCountsKey="";
        disconnect(); hideAllBadges();
      }
      refreshWorkflowNotifications();
    })?.data?.subscription;
    document.addEventListener("visibilitychange", () => {
      epoch += 1;
      if (document.hidden) {
        window.clearTimeout(refreshTimer); refreshTimer = null;
        window.clearTimeout(pollTimer); disconnect();
      } else { updateDashboardGreeting(); refreshWorkflowNotifications(); }
    });
    window.addEventListener('pagehide', () => {
      stopped = true; epoch += 1;
      window.clearTimeout(refreshTimer); refreshTimer = null;
      window.clearTimeout(pollTimer); window.clearInterval(autoPickTimer);
      disconnect();
    });
    window.addEventListener('pageshow', () => { stopped = false; refreshWorkflowNotifications(); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize);
  else initialize();
})();
