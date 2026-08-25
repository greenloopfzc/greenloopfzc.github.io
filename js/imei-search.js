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
  const journeyDetails = document.querySelector("#journey-details");
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

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function label(value) { return String(value || "-").replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase()); }
  function money(value) { return `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`; }
  function dateTime(value) {
    if (!value) return "-";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString("en-GB", {
      timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "numeric", minute: "2-digit", hour12: true
    });
  }
  function supplierLabel(code, name) {
    if (typeof window.GREENLOOP_PARTNER_LABEL === "function") return window.GREENLOOP_PARTNER_LABEL(code, name, "Not recorded");
    return String(code || "").trim() || "Not recorded";
  }
  function supplierReceiptLabel(code, quantity, name) {
    if (typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function") return window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(code, quantity, name, "Not recorded");
    const safeCode = String(code || "").trim();
    return safeCode && Number(quantity) > 0 ? `${safeCode}-(${quantity})` : (safeCode || "Not recorded");
  }
  function customerLabel(code, name) {
    const safeCode = String(code || "").trim();
    const safeName = String(name || "").trim();
    return window.GREENLOOP_CAN_VIEW_PARTNER_NAMES && safeName ? [safeCode, safeName].filter(Boolean).join(" - ") : (safeCode || "Confidential customer");
  }
  function setMessage(text = "") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); }
  function setSubmitting(isSubmitting) { searchButton.disabled = isSubmitting; if (isSubmitting) searchButton.dataset.label = searchButton.textContent.trim(); searchButton.textContent = isSubmitting ? "Searching..." : searchButton.dataset.label || "Search device"; }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function detailCard(title, value) { return `<div class="journey-detail"><dt>${escapeHtml(title)}</dt><dd>${escapeHtml(value || "-")}</dd></div>`; }

  function renderJobs(jobs) {
    jobHistory.innerHTML = jobs.length ? jobs.map((job) => `
      <article class="job-row">
        <div class="job-topline"><span>${escapeHtml(job.job_number)}</span><span class="job-cost">${money(job.total_cost)}</span></div>
        <div class="job-meta">${escapeHtml(job.job_type)} - ${escapeHtml(job.status)} - Received ${escapeHtml(dateTime(job.received_at))}</div>
        <div class="job-meta">Purchase: ${money(job.purchase_cost)} - Parts: ${money(job.parts_cost)} - Lab: ${money(job.laboratory_material_cost)} - Glass: ${money(job.glass_material_cost)}</div>
        <div class="job-meta">${escapeHtml(job.customer_code || job.customer ? `Customer: ${customerLabel(job.customer_code, job.customer)}` : `Supplier: ${supplierLabel(job.supplier_code, job.supplier)}`)}</div>
      </article>`).join("") : '<p class="history-empty">No jobs found for this device.</p>';
  }

  function readableEventDetails(value) {
    if (!value || typeof value !== "object") return "";
    return ["department", "result", "final_grade", "final_battery_health", "box_number", "reason", "notes"]
      .map((key) => value[key] ? `${label(key)}: ${value[key]}` : "").filter(Boolean).join(" - ");
  }

  function renderEvents(events) {
    eventHistory.innerHTML = events.length ? events.map((event) => {
      const meta = [dateTime(event.occurred_at), event.job_number, event.supplier_code, event.actor, readableEventDetails(event.details)].filter(Boolean).join(" - ");
      return `<li><strong>${escapeHtml(event.title)}</strong><span>${escapeHtml(meta)}</span></li>`;
    }).join("") : '<li class="history-empty">No system events found.</li>';
  }

  function renderMovements(movements) {
    movementHistory.innerHTML = movements.length ? movements.map((movement) => `
      <article class="movement-row">
        <div class="movement-topline"><span>${escapeHtml(movement.from_location || "New intake")} → ${escapeHtml(movement.to_location || "-")}</span><span>${escapeHtml(dateTime(movement.moved_at))}</span></div>
        <div class="movement-meta">${escapeHtml([movement.reason, movement.job_number, movement.supplier_code, movement.notes].filter(Boolean).join(" - "))}</div>
      </article>`).join("") : '<p class="history-empty">No location movements found.</p>';
  }

  function renderHistory(data) {
    const device = data.device || {};
    const journey = data.journey || {};
    const details = [device.brand, device.model, device.storage_gb ? `${device.storage_gb} GB` : "", device.color, device.region].filter(Boolean).join(" - ");
    deviceSummary.innerHTML = `
      <div><p class="panel-kicker">Device</p><h2>${escapeHtml(device.device_number)}</h2><p>${escapeHtml(details || "No model details recorded")}</p></div>
      <dl class="device-details">
        <div><dt>IMEI 1</dt><dd>${escapeHtml(device.imei_1)}</dd></div><div><dt>IMEI 2</dt><dd>${escapeHtml(device.imei_2 || "-")}</dd></div>
        <div><dt>Serial number</dt><dd>${escapeHtml(device.serial_number || "-")}</dd></div><div><dt>Region</dt><dd>${escapeHtml(device.region || "-")}</dd></div>
        <div><dt>Supplier code</dt><dd>${escapeHtml(supplierLabel(device.supplier_code, device.supplier_name))}</dd></div><div><dt>Customer</dt><dd>${escapeHtml(customerLabel(device.customer_code, device.customer_name))}</dd></div>
      </dl>`;
    journeyDetails.innerHTML = [
      ["Date received", dateTime(journey.date_received)], ["Date completed", dateTime(journey.date_completed)], ["Stock channel", journey.stock_channel], ["Invoice number", journey.invoice_number],
      ["Supplier company", window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? journey.supplier_company : "Confidential"], ["Quantity received", journey.quantity_received ? `${journey.quantity_received} devices` : "-"],
      ["Supplier code", supplierReceiptLabel(journey.supplier_code, journey.quantity_received, journey.supplier_company)], ["Initial BH / Final BH", journey.battery_health], ["Supplier grade", journey.supplier_grade], ["Company initial grade", journey.company_initial_grade],
      ["Company final grade", journey.company_final_grade], ["Parts issued", journey.parts_issued], ["Parts cost", money(journey.parts_cost)], ["Service done", journey.service_done],
      ["Technician name", journey.technician_name], ["Box number", journey.box_number], ["Export date", dateTime(journey.export_date)], ["Customer", customerLabel(journey.customer_code, journey.customer_name)]
    ].map(([title, value]) => detailCard(title, value)).join("");
    totalCost.textContent = money(data.total_cost); currentStatus.textContent = label(device.current_status); currentLocation.textContent = device.current_location || "No active location";
    renderJobs(data.jobs || []); renderEvents(data.events || []); renderMovements(data.movements || []); result.hidden = false;
  }

  async function search(event) {
    event?.preventDefault(); setMessage(); result.hidden = true;
    const imei = query.value.trim();
    if (!imei) { setMessage("Enter an IMEI number first."); return; }
    setSubmitting(true);
    const { data: identifierRows, error: identifierError } = await getClient().rpc("resolve_device_identifier", { p_identifier: imei });
    if (identifierError) { setSubmitting(false); setMessage(identifierError.message || "Device search could not be completed."); return; }
    let identifier = Array.isArray(identifierRows) ? identifierRows[0]?.imei_1 : identifierRows?.imei_1;
    if (!identifier) {
      const { data: directMatches, error: directError } = await getClient().from("devices").select("imei_1").is("deleted_at", null).or(`imei_1.eq.${imei},imei_2.eq.${imei},device_number.eq.${imei},serial_number.eq.${imei}`).limit(1);
      if (directError) { setSubmitting(false); setMessage(directError.message || "Device search could not be completed."); return; }
      identifier = directMatches?.[0]?.imei_1;
    }
    if (!identifier) { setSubmitting(false); setMessage("No active device was found for this IMEI, device number, or serial number."); return; }
    const { data, error } = await getClient().rpc("search_imei_history", { p_imei: identifier });
    setSubmitting(false);
    if (error) { setMessage(error.message || "IMEI history could not be loaded."); return; }
    const history = Array.isArray(data) ? data[0]?.search_imei_history || data[0] : data;
    if (!history?.found) { setMessage("No active device was found for this IMEI."); return; }
    renderHistory(history); showToast("Complete IMEI history loaded.");
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;
    if (!window.GREENLOOP_PAGE_ACCESS) { permissionMessage.textContent = "Your account does not have IMEI Search permission."; permissionMessage.hidden = false; return; }
    app.hidden = false;
    if (requestedQuery.trim()) { query.value = requestedQuery.trim(); await search(); }
  }

  query.addEventListener("input", () => { window.clearTimeout(autoSearchTimer); const value = query.value.trim(); if (/^\d{15}$/.test(value) || /^DEV-\d+$/i.test(value)) autoSearchTimer = window.setTimeout(() => search(), 300); });
  form.addEventListener("submit", search);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true)); document.querySelector("#close-menu").addEventListener("click", () => setMenu(false)); backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "IMEI Search could not be loaded."; permissionMessage.hidden = false; });
})();
