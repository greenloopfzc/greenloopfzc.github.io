(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#history-app");
  const permissionMessage = document.querySelector("#permission-message");
  const form = document.querySelector("#imei-search-form");
  const query = document.querySelector("#imei-query");
  const searchButton = document.querySelector("#search-button");
  const message = document.querySelector("#search-message");
  const result = document.querySelector("#history-result");
  const deviceSummary = document.querySelector("#device-summary");
  const totalCost = document.querySelector("#total-cost");
  const currentStatus = document.querySelector("#current-status");
  const currentLocation = document.querySelector("#current-location");
  const jobHistory = document.querySelector("#job-history");
  const eventHistory = document.querySelector("#event-history");
  const movementHistory = document.querySelector("#movement-history");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedQuery = new URLSearchParams(window.location.search).get("q") || "";
  let client;
  let toastTimer;
  let autoSearchTimer;

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
  }

  function label(value) {
    return String(value || "—").replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase());
  }

  function money(value) {
    return `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }

  function supplierLabel(code, name) {
    return String(code || "").trim() || String(name || "").trim() || "Not recorded";
  }

  function dateTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString();
  }

  function setMessage(text = "") {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
  }

  function setSubmitting(isSubmitting) {
    searchButton.disabled = isSubmitting;
    if (isSubmitting) searchButton.dataset.label = searchButton.textContent.trim();
    searchButton.textContent = isSubmitting ? "Searching..." : searchButton.dataset.label || "Search IMEI";
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function showToast(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3400);
  }

  function renderJobs(jobs) {
    if (!jobs.length) {
      jobHistory.innerHTML = '<p class="history-empty">No jobs found for this device.</p>';
      return;
    }
    jobHistory.innerHTML = jobs.map((job) => `
      <article class="job-row">
        <div class="job-topline"><span>${escapeHtml(job.job_number)}</span><span class="job-cost">${money(job.total_cost)}</span></div>
        <div class="job-meta">${escapeHtml(job.job_type)} · ${escapeHtml(job.status)} · Received ${escapeHtml(dateTime(job.received_at))}</div>
        <div class="job-meta">Purchase: ${money(job.purchase_cost)} · Parts installed: ${money(job.parts_cost)} · Laboratory materials: ${money(job.laboratory_material_cost)} · Glass materials: ${money(job.glass_material_cost)}</div>
        <div class="job-meta">${escapeHtml(job.customer ? `Customer: ${job.customer}` : `Supplier: ${supplierLabel(job.supplier_code, job.supplier)}`)}</div>
      </article>`).join("");
  }

  function renderEvents(events) {
    if (!events.length) {
      eventHistory.innerHTML = '<li class="history-empty">No system events found.</li>';
      return;
    }
    eventHistory.innerHTML = events.map((event) => `
      <li><strong>${escapeHtml(event.title)}</strong><span>${escapeHtml(dateTime(event.occurred_at))}${event.job_number ? ` · ${escapeHtml(event.job_number)}` : ""}${event.supplier_code ? ` · ${escapeHtml(event.supplier_code)}` : ""}${event.actor ? ` · ${escapeHtml(event.actor)}` : ""}</span></li>`).join("");
  }

  function renderMovements(movements) {
    if (!movements.length) {
      movementHistory.innerHTML = '<p class="history-empty">No location movements found.</p>';
      return;
    }
    movementHistory.innerHTML = movements.map((movement) => `
      <article class="movement-row">
        <div class="movement-topline"><span>${escapeHtml(movement.from_location || "New intake")} → ${escapeHtml(movement.to_location)}</span><span>${escapeHtml(dateTime(movement.moved_at))}</span></div>
        <div class="movement-meta">${escapeHtml(movement.reason)}${movement.job_number ? ` · ${escapeHtml(movement.job_number)}` : ""}${movement.supplier_code ? ` · ${escapeHtml(movement.supplier_code)}` : ""}${movement.notes ? ` · ${escapeHtml(movement.notes)}` : ""}</div>
      </article>`).join("");
  }

  function renderHistory(data) {
    const device = data.device || {};
    const exportBox = data.export_box || null;
    const exportBoxLabel = exportBox
      ? `${exportBox.box_number}${exportBox.serial_no ? ` · S.No ${exportBox.serial_no}` : ""}`
      : data.export_box_lookup_ready === false ? "Box lookup unavailable" : "Not exported";
    const details = [device.brand, device.model, device.storage_gb ? `${device.storage_gb} GB` : "", device.color, device.grade ? `Grade ${device.grade}` : ""].filter(Boolean).join(" · ");
    deviceSummary.innerHTML = `
      <div><p class="panel-kicker">Device</p><h2>${escapeHtml(device.device_number)}</h2><p>${escapeHtml(details || "No model details recorded")}</p></div>
      <dl class="device-details">
        <div><dt>IMEI 1</dt><dd>${escapeHtml(device.imei_1)}</dd></div>
        <div><dt>IMEI 2</dt><dd>${escapeHtml(device.imei_2 || "—")}</dd></div>
        <div><dt>Supplier code</dt><dd>${escapeHtml(supplierLabel(device.supplier_code))}</dd></div>
        <div><dt>Export box</dt><dd>${escapeHtml(exportBoxLabel)}</dd></div>
        <div><dt>Battery health</dt><dd>${device.battery_health ? `${escapeHtml(device.battery_health)}%` : "—"}</dd></div>
      </dl>`;
    totalCost.textContent = money(data.total_cost);
    currentStatus.textContent = label(device.current_status);
    currentLocation.textContent = device.current_location || "No active location";
    renderJobs(data.jobs || []);
    renderEvents(data.events || []);
    renderMovements(data.movements || []);
    result.hidden = false;
  }

  async function search(event) {
    event?.preventDefault();
    setMessage();
    result.hidden = true;
    const imei = query.value.trim();
    if (!imei) {
      setMessage("Enter an IMEI number first.");
      return;
    }
    setSubmitting(true);
    const { data: identifierRows, error: identifierError } = await getClient().rpc("resolve_device_identifier", { p_identifier: imei });
    if (identifierError) {
      setSubmitting(false);
      setMessage(identifierError.message || "Device search could not be completed.");
      return;
    }
    let identifier = Array.isArray(identifierRows) ? identifierRows[0]?.imei_1 : identifierRows?.imei_1;
    if (!identifier) {
      const { data: directMatches, error: directError } = await getClient()
        .from("devices")
        .select("imei_1")
        .is("deleted_at", null)
        .or(`imei_1.eq.${imei},imei_2.eq.${imei},device_number.eq.${imei},serial_number.eq.${imei}`)
        .limit(1);
      if (directError) {
        setSubmitting(false);
        setMessage(directError.message || "Device search could not be completed.");
        return;
      }
      identifier = directMatches?.[0]?.imei_1;
    }
    if (!identifier) {
      setSubmitting(false);
      setMessage("No active device was found for this IMEI, device number, or serial number.");
      return;
    }
    const [historyResult, exportBoxResult] = await Promise.all([
      getClient().rpc("search_imei_history", { p_imei: identifier }),
      getClient().rpc("get_export_box_by_imei", { p_imei: identifier })
    ]);
    setSubmitting(false);
    if (historyResult.error) {
      setMessage(historyResult.error.message || "IMEI history could not be loaded.");
      return;
    }
    const history = Array.isArray(historyResult.data) ? historyResult.data[0]?.search_imei_history || historyResult.data[0] : historyResult.data;
    if (!history?.found) {
      setMessage("No active device was found for this IMEI.");
      return;
    }
    history.export_box_lookup_ready = !exportBoxResult.error;
    if (!exportBoxResult.error) {
      history.export_box = Array.isArray(exportBoxResult.data) ? exportBoxResult.data[0] : exportBoxResult.data;
    }
    renderHistory(history);
    showToast("IMEI history loaded.");
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }
    const { data: canSearch, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "receiving", "initial_qc", "parts", "technician", "glass", "frame", "final_qc", "production", "packing", "shipping", "rma", "shop_staff"] });
    if (error) throw error;
    if (!canSearch) {
      permissionMessage.textContent = "Your account does not have IMEI Search permission.";
      permissionMessage.hidden = false;
      return;
    }
    app.hidden = false;
    if (requestedQuery.trim()) {
      query.value = requestedQuery.trim();
      await search();
    }
  }

  query.addEventListener("input", () => {
    window.clearTimeout(autoSearchTimer);
    const value = query.value.trim();
    if (/^\d{15}$/.test(value) || /^DEV-\d+$/i.test(value)) {
      autoSearchTimer = window.setTimeout(() => search(), 300);
    }
  });
  form.addEventListener("submit", search);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "IMEI Search could not be loaded."; permissionMessage.hidden = false; });
})();
