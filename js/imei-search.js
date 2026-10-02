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
  const header = document.querySelector("#history-device");
  const body = document.querySelector("#history-rows");
  const summary = document.querySelector("#history-summary");
  const count = document.querySelector("#history-record-count");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedQuery = new URLSearchParams(window.location.search).get("q") || "";
  const missing = "Not recorded";
  const stages = {
    stock_received: "Stock Received", receiving: "Stock Received", receipt: "Stock Received",
    imei_entry: "IMEI Entry", intake: "IMEI Entry", job_created: "Job opened",
    initial_qc: "Initial QC", parts: "Parts", part_request: "Parts", part_issue: "Parts",
    part_installation: "Parts", manual_part: "Parts", part_return: "Parts return",
    laboratory: "Laboratory", laboratory_work: "Laboratory", lab_glass: "Lab & Glass", glass: "Glass",
    frame: "Frame Department", frame_department: "Frame Department", final_qc: "Final QC",
    ready_stock: "Ready Stock", rework: "Rework", export: "Export Boxes", export_box: "Export Boxes",
    stock_return: "Stock Return", supplier_return: "Stock Return", movement: "Location change",
    correction: "Data correction", job: "Job history", event: "Recorded activity",
    assignment: "Technician assignment", technician: "Technician time", workflow: "Process update"
  };
  let client;
  let allowed = false;
  let toastTimer;
  let autoSearchTimer;
  let searchVersion = 0;

  function getClient() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
  function scalar(value) { return ["string", "number", "boolean"].includes(typeof value) ? String(value).trim() : ""; }
  function escapeHtml(value) { return scalar(value).replace(/[&<>'"]/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function label(value) {
    return scalar(value).replaceAll("_", " ").replace(/\b\w/g, character => character.toUpperCase()).replace(/\bQc\b/g, "QC").replace(/\bImei\b/g, "IMEI") || missing;
  }
  function number(value) {
    if (value === null || value === undefined || typeof value === "boolean" || String(value).trim() === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  function money(value) {
    const amount = number(value);
    return amount === null ? missing : `AED ${amount.toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }
  function timestamp(value) {
    if (!scalar(value)) return null;
    const parsed = new Date(value).getTime();
    return Number.isFinite(parsed) ? parsed : null;
  }
  function date(value, time = false) {
    const stamp = timestamp(value);
    if (stamp === null) return missing;
    return new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", ...(time ? { hour: "numeric", minute: "2-digit", hour12: true } : { day: "2-digit", month: "short", year: "numeric" }) }).format(new Date(stamp));
  }
  function duration(value) {
    const seconds = number(value);
    if (seconds === null || seconds < 0) return missing;
    if (seconds < 60) return "Less than 1 min";
    const minutes = Math.floor(seconds / 60);
    const days = Math.floor(minutes / 1440);
    const hours = Math.floor(minutes % 1440 / 60);
    const rest = minutes % 60;
    return [days ? `${days} ${days === 1 ? "day" : "days"}` : "", hours ? `${hours} hr` : "", rest ? `${rest} min` : ""].filter(Boolean).join(" ");
  }
  function tone(value, stage = "") {
    const state = scalar(value).toLowerCase().replace(/[ -]/g, "_");
    if (/^(?:fail|failed|damaged|faulty|scrapped|rejected)$/.test(state)) return "danger";
    if (/^(?:pass|passed|qc_passed|completed|ready|ready_stock|shipped|closed)$/.test(state)) return "success";
    if (/pending|waiting|returned_to_supplier|return_requested|rework|hold|paused/.test(state)) return "warning";
    if (/in_progress|working|issued|assigned/.test(state)) return "info";
    if (/laboratory|lab_glass|glass|frame/.test(stage)) return "repair";
    if (/parts|part_|export/.test(stage)) return "info";
    if (/stock_return|supplier_return|rework/.test(stage)) return "warning";
    return "neutral";
  }
  function absent() { return `<span class="journey-missing">${missing}</span>`; }
  function badge(value) { return scalar(value) ? `<span class="journey-badge" data-tone="${tone(value)}">${escapeHtml(label(value))}</span>` : ""; }
  function detailList(details) {
    if (!Array.isArray(details)) return "";
    // The read-only report returns approved display fields, never raw records.
    // Keep the partner-name flag as a second display check as well.
    const visible = details.filter(item => item && scalar(item.label) && (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES || !/^(?:supplier|customer)(?: company)? name$/i.test(scalar(item.label))));
    return visible.length ? `<dl class="journey-detail-list">${visible.map(item => `<div><dt>${escapeHtml(item.label)}</dt><dd>${escapeHtml(scalar(item.value) || missing)}</dd></div>`).join("")}</dl>` : "";
  }
  function costCell(row) {
    const parts = Array.isArray(row.parts) ? row.parts.filter(part => part && typeof part === "object") : [];
    if (parts.length) return `<ul class="journey-part-list">${parts.map(part => {
      const quantity = number(part.quantity);
      const unit = number(part.unit_cost);
      const total = number(part.total_cost);
      return `<li><strong>${escapeHtml(scalar(part.name) || "Part name not recorded")}</strong><span>${quantity === null ? "Quantity not recorded" : `Qty ${escapeHtml(quantity)}`} · ${unit === null ? "Price not recorded" : `${escapeHtml(money(unit))} each`}</span>${total === null ? '<span>Total price: Not recorded</span>' : `<b>${escapeHtml(money(total))}</b>`}</li>`;
    }).join("")}</ul>`;
    return number(row.cost) === null ? absent() : `<span class="journey-cost-label">${escapeHtml(row.cost_label || "Recorded cost")}</span><strong class="journey-cost">${escapeHtml(money(row.cost))}</strong>`;
  }
  function renderRow(row, index) {
    const stage = scalar(row.stage);
    const stamp = timestamp(row.occurred_at);
    return `<tr data-history-id="${escapeHtml(row.id)}">
      <td data-label="When">${stamp === null ? absent() : `<time datetime="${escapeHtml(new Date(stamp).toISOString())}"><span class="journey-date">${escapeHtml(date(row.occurred_at))}</span><span class="journey-clock">${escapeHtml(date(row.occurred_at, true))}</span></time>`}</td>
      <td data-label="Step"><div class="journey-step" data-tone="${tone(row.status, stage)}"><span class="journey-step-number" aria-hidden="true">${String(index + 1).padStart(2, "0")}</span><div><span class="journey-step-name">${escapeHtml(stages[stage] || label(stage))}</span>${scalar(row.job_number) ? `<span class="journey-job">${escapeHtml(row.job_number)}</span>` : ""}</div></div></td>
      <td data-label="What happened" class="journey-description-cell"><strong class="journey-event-title">${escapeHtml(scalar(row.title) || "Activity recorded")}</strong>${badge(row.status)}${detailList(row.details)}</td>
      <td data-label="Who">${scalar(row.actor) ? `<span class="journey-person">${escapeHtml(row.actor)}</span>${scalar(row.actor_role) ? `<span class="journey-subtext">${escapeHtml(row.actor_role)}</span>` : ""}` : absent()}</td>
      <td data-label="Parts &amp; cost" class="journey-parts-cell">${costCell(row)}</td>
      <td data-label="Time taken">${number(row.duration_seconds) === null || number(row.duration_seconds) < 0 ? absent() : `<strong class="journey-duration">${escapeHtml(duration(row.duration_seconds))}</strong>`}${scalar(row.duration_label) ? `<span class="journey-subtext">${escapeHtml(row.duration_label)}</span>` : ""}</td>
    </tr>`;
  }
  function renderSummary(data) {
    const unpriced = number(data.unpriced_manual_part_quantity) || 0;
    const installed = number(data.installed_parts_cost);
    const damaged = number(data.damaged_parts_cost);
    const consumed = installed === null && damaged === null ? null : (installed || 0) + (damaged || 0);
    const costs = [["Purchase", data.purchase_cost], ["Lab materials", data.laboratory_material_cost], ["Glass materials", data.glass_material_cost]];
    summary.innerHTML = `<div><span>${unpriced > 0 ? "Recorded cost · partial total" : "Total recorded cost"}</span><strong>${escapeHtml(money(data.recorded_total_cost))}</strong><small>${costs.map(([name, amount]) => `${name}: ${escapeHtml(money(amount))}`).join("<br>")}</small><small>${escapeHtml(data.cost_note || "Includes recorded purchase and consumed materials. Issuing a part does not charge it twice.")}${unpriced > 0 ? ` ${escapeHtml(unpriced)} manual part(s) have no recorded price.` : ""}</small></div>
      <div><span>Stock received → latest Ready Stock</span><strong>${escapeHtml(duration(data.receipt_to_ready_seconds))}</strong><small>Received: ${escapeHtml(date(data.first_received_at))}<br>Latest ready: ${escapeHtml(date(data.last_ready_at))}</small><small>Elapsed time includes waiting and rework. Work time is shown on the relevant steps above.</small></div>
      <div><span>Parts consumed</span><strong>${escapeHtml(money(consumed))}</strong><small>Installed: ${escapeHtml(money(installed))}<br>Damaged / faulty: ${escapeHtml(money(damaged))}</small><small>Included in the recorded total. Reusable parts returned to inventory are excluded.</small></div>`;
  }
  function renderHistory(data) {
    const device = data.device || {};
    const identity = [device.brand, device.model, number(device.storage_gb) === null ? "" : `${device.storage_gb} GB`, device.color].map(scalar).filter(Boolean).join(" · ");
    const identifiers = [["IMEI", device.imei_1], ["Device", device.device_number], ["Serial", device.serial_number], ["IMEI 2", device.imei_2], ["Region", device.region]];
    header.innerHTML = `<div class="imei-journey-identity"><p class="panel-kicker">Complete device history</p><h2 id="history-device-name">${escapeHtml(identity || "Device details not recorded")}</h2><div class="imei-journey-identifiers">${identifiers.filter(([name, value]) => ["IMEI", "Device", "Serial"].includes(name) || scalar(value)).map(([name, value]) => `<span>${name} <b>${escapeHtml(scalar(value) || missing)}</b></span>`).join("")}</div></div><div class="imei-journey-current"><small>Current status</small>${scalar(device.current_status) ? badge(device.current_status) : absent()}<small>${escapeHtml(scalar(device.current_location) || "Location not recorded")}</small></div>`;
    const rows = (Array.isArray(data.rows) ? data.rows : []).filter(row => row && typeof row === "object").map((row, index) => ({ row, index, stamp: timestamp(row.occurred_at) })).sort((a, b) => (a.stamp === null ? Infinity : a.stamp) - (b.stamp === null ? Infinity : b.stamp) || a.index - b.index).map(item => item.row);
    body.innerHTML = rows.length ? rows.map(renderRow).join("") : '<tr><td colspan="6"><span class="journey-missing">No history steps have been recorded for this phone.</span></td></tr>';
    const undated = rows.filter(row => timestamp(row.occurred_at) === null).length;
    count.textContent = `${rows.length} recorded ${rows.length === 1 ? "step" : "steps"}${undated ? ` · ${undated} without a recorded date, shown last` : ""}`;
    renderSummary(data.summary || {});
    result.hidden = false;
  }
  function setMessage(text = "") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); }
  function setSubmitting(busy) { searchButton.disabled = busy; searchButton.textContent = busy ? "Searching..." : "Search device"; form.setAttribute("aria-busy", String(busy)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function withTimeout(promise) {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("History is taking too long to load. Please search again.")), 25000); })]).finally(() => clearTimeout(timer));
  }
  async function search(event) {
    event?.preventDefault();
    if (!allowed) return;
    window.clearTimeout(autoSearchTimer);
    setMessage(); result.hidden = true;
    const version = ++searchVersion;
    const identifier = query.value.trim();
    const current = () => version === searchVersion && query.value.trim() === identifier;
    if (!identifier) { setSubmitting(false); setMessage("Enter an IMEI, device number, or serial number first."); return; }
    setSubmitting(true);
    try {
      const response = await withTimeout(getClient().rpc("search_imei_journey_v1", { p_imei: identifier }));
      if (!current()) return;
      if (response.error) {
        if (response.error.code === "PGRST202" || response.error.code === "42883") throw new Error("The complete history update is not installed yet. Ask your administrator to install the IMEI History update.");
        throw response.error;
      }
      const raw = response.data;
      const history = Array.isArray(raw) ? raw[0]?.search_imei_journey_v1 || raw[0] : raw;
      if (!history?.found) { setMessage("No active device was found for this IMEI, device number, or serial number."); return; }
      renderHistory(history);
      showToast("Complete device journey loaded.");
    } catch (error) {
      if (current()) setMessage(error.message || "Device history could not be loaded. Please try again.");
    } finally {
      if (version === searchVersion) setSubmitting(false);
    }
  }
  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData, error } = await getClient().auth.getSession();
    if (error) throw error;
    if (!sessionData?.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;
    if (!window.GREENLOOP_PAGE_ACCESS || window.GREENLOOP_PAGE_ACCESS.pageKey !== "imei_search") { permissionMessage.textContent = "Your account does not have IMEI Search permission."; permissionMessage.hidden = false; return; }
    allowed = true; app.hidden = false;
    if (requestedQuery.trim()) { query.value = requestedQuery.trim(); await search(); }
  }
  query.addEventListener("input", () => { ++searchVersion; window.clearTimeout(autoSearchTimer); setSubmitting(false); result.hidden = true; setMessage(); const value = query.value.trim(); if (/^\d{15}$/.test(value) || /^DEV-\d+$/i.test(value)) autoSearchTimer = window.setTimeout(() => search(), 300); });
  form.addEventListener("submit", search);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch(error => { permissionMessage.textContent = error.message || "IMEI Search could not be loaded."; permissionMessage.hidden = false; });
})();
