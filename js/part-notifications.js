(() => {
  "use strict";
  if (window.GREENLOOP_NOTIFICATIONS_STARTED) return;
  window.GREENLOOP_NOTIFICATIONS_STARTED = true;

  const config = window.GREENLOOP_CONFIG || {};
  const stages = [
    {file:'stock-entry.html',key:'stock_received',page:'stock_received',label:'Stock Received',unit:'phones received'},
    {file:'imei-entry.html',key:'imei_entry',page:'imei_entry',label:'IMEI Entry',unit:'phones awaiting IMEI entry'},
    {file:'initial-qc.html',key:'initial_qc',page:'initial_qc',label:'Initial QC',unit:'phones awaiting inspection'},
    {file:'qc-issuance.html',key:'qc_issuance',page:'initial_qc',label:'Lab & Glass Issuance',unit:'phones awaiting issuance'},
    {file:'stock-return.html',key:'supplier_returns',page:'supplier_returns',label:'Return/Replacement',unit:'phones awaiting supplier return'},
    {file:'laboratory.html',key:'lab_glass',page:'lab_glass',label:'Lab & Glass',unit:'pending phones'},
    {file:'parts.html',key:'parts',page:'parts',label:'Parts',unit:'phones awaiting parts issue or return review'},
    {file:'final-qc.html',key:'final_qc',page:'final_qc',label:'Final QC',unit:'phones awaiting Final QC'},
    {file:'laboratory.html#frame',key:'frame',page:'frame_department',label:'B-DEPT',unit:'pending phones'},
    {file:'ready-stock.html',key:'ready_stock',page:'ready_stock',label:'Ready Stock',unit:'available ready phones'},
    {file:'export-box.html',key:'box_entry',page:'export_boxes',label:'Box Entry',unit:'draft or recheck boxes'},
    {file:'accounts.html',key:'accounts',page:'accounts',label:'Accounts',unit:'boxes awaiting verification'},
    {file:'stock-exported.html',key:'stock_exported',page:'stock_exported',label:'Stock Exported',unit:'exported phones'},
    {file:'ready-stock-journey.html',key:'stock_journey',page:'ready_stock_journey',label:'Stock Journey',unit:'recorded phones'}
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
      lineHeight: "18px", textAlign: "center", flexShrink: "0", boxSizing: "border-box", whiteSpace: "nowrap"
    });
    link.appendChild(badge);
    return badge;
  }

  function hideAllBadges() {
    document.querySelectorAll('[data-workflow-badge],[data-accounts-pending-badge]').forEach(badge=>{badge.hidden=true;badge.textContent='';});
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
      await window.GREENLOOP_ACCESS_READY;
      const {data,error}=await withDeadline(client.rpc('get_sidebar_notification_counts_v1'));
      if(requestEpoch!==epoch||stopped||document.hidden)return;
      if(error)throw error;
      const updated=Array.isArray(data)?data[0]:data;
      if(!updated||typeof updated!=='object'||Array.isArray(updated)||Object.values(updated).some(n=>!Number.isSafeInteger(n)||n<0))throw new Error('Invalid sidebar counts');
      failures=0;
      if(requestEpoch!==epoch||stopped||document.hidden)return;
      renderCounts(updated);
      const countsKey=JSON.stringify(updated);if(countsKey!==lastCountsKey||notifyAfterRead){lastCountsKey=countsKey;document.dispatchEvent(new CustomEvent("greenloop:workflow-notifications-refreshed",{detail:{counts:{...updated}}}));}
    } catch (_) {
      // A temporary connection failure must not make pending work disappear.
      failures += 1;
    } finally {
      inFlight = false;
      pollLater();
      if (dirty) refreshWorkflowNotifications();
    }
  }

  function setBadge(badge,count,title){
    badge.textContent=String(count);badge.hidden=count===0;badge.title=`${count} ${title}`;badge.setAttribute('aria-label',badge.title);
  }
  function renderCounts(counts){
    for(const stage of stages){
      const badge=createBadge(stage);if(!badge)continue;
      if(window.GREENLOOP_CAN?.('view',stage.page)!==true||!Object.hasOwn(counts,stage.key)){badge.hidden=true;badge.textContent='';continue;}
      setBadge(badge,counts[stage.key],stage.unit);
    }
    const card=document.querySelector('[data-accounts-view="verify"]');
    if(card){
      let badge=card.querySelector('[data-accounts-pending-badge]');
      if(!badge){badge=document.createElement('span');badge.className='accounts-pending-badge';badge.dataset.accountsPendingBadge='';badge.hidden=true;card.appendChild(badge);}
      if(window.GREENLOOP_CAN?.('view','accounts')===true&&Object.hasOwn(counts,'accounts'))setBadge(badge,counts.accounts,'boxes awaiting verification');
      else{badge.hidden=true;badge.textContent='';}
    }
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
    window.addEventListener('greenloop:permissions-changed',()=>{epoch++;lastCountsKey='';hideAllBadges();refreshWorkflowNotifications();});
    window.addEventListener('greenloop:office-locked',()=>{stopped=true;epoch++;disconnect();hideAllBadges();window.clearTimeout(pollTimer);});
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
