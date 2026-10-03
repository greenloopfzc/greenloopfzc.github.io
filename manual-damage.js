(() => {
  "use strict";

  const pageSize = 8;
  const byId = (id) => document.getElementById(id);
  const form = byId("manual-damage-form");
  const fields = byId("manual-damage-fields");
  const saveButton = byId("save-manual-damage");
  const recent = byId("manual-damage-recent");
  const previousButton = byId("manual-damage-previous");
  const nextButton = byId("manual-damage-next");
  const refreshButton = byId("refresh-manual-damage");
  const inputs = {
    damaged_by: byId("damage-person"),
    model: byId("damage-model"),
    identifier: byId("damage-identifier"),
    damage: byId("damage-description"),
    reason: byId("damage-reason"),
    occurred_at: byId("damage-occurred-at")
  };
  let client;
  let canEdit = false;
  let saving = false;
  let pendingRequest = null;
  let offset = 0;
  let hasMore = false;
  let loading = false;
  let loadVersion = 0;
  let accessDenied = false;

  const api = () => (client ||= window.GREENLOOP_GET_CLIENT());
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const dateFormatter = new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: true });
  function dateLabel(value) {
    const date = new Date(value);
    return value && Number.isFinite(date.getTime()) ? dateFormatter.format(date) : "Time unavailable";
  }
  function uaeLocalNow() {
    return new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString().slice(0, 16);
  }
  function uaeTimestamp(value) {
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) return null;
    // datetime-local has no timezone. Always interpret the entered wall time as UAE.
    const instant = new Date(`${value}:00+04:00`);
    if (!Number.isFinite(instant.getTime())) return null;
    const roundTrip = new Date(instant.getTime() + 4 * 60 * 60 * 1000).toISOString().slice(0, 16);
    return roundTrip === value ? instant.toISOString() : null;
  }
  function message(id, text = "", success = false) {
    const element = byId(id);
    element.textContent = text;
    element.hidden = !text;
    element.classList.toggle("is-success", success);
  }
  function setSaving(value) {
    saving = value;
    fields.disabled = value || !canEdit;
    saveButton.disabled = value || !canEdit;
    saveButton.textContent = value ? "Saving…" : "Save damage report";
    form.setAttribute("aria-busy", String(value));
  }
  function updatePager() {
    previousButton.disabled = accessDenied || loading || offset === 0;
    nextButton.disabled = accessDenied || loading || !hasMore;
    refreshButton.disabled = accessDenied || loading;
    recent.setAttribute("aria-busy", String(loading));
  }
  function isAccessError(error) {
    return [error?.code, error?.status, error?.statusCode].some((value) => ["42501", "401", "403", "PGRST301", "PGRST302"].includes(String(value)));
  }
  function lockRevokedAccess() {
    accessDenied = true;
    canEdit = false;
    loadVersion += 1;
    loading = false;
    offset = 0;
    hasMore = false;
    setSaving(false);
    updatePager();
    recent.innerHTML = '<p class="manual-damage-empty">Reports are hidden because your session or access has changed.</p>';
    byId("manual-damage-page-label").textContent = "Access unavailable";
    byId("manual-damage-view-only").hidden = true;
    message("manual-damage-message");
    message("manual-damage-history-message");
    message("permission-message", "Your session or Lab Live Board access has changed. Sign in again or ask an administrator to restore access, then reload this page.");
  }
  function requestId() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID();
    const bytes = new Uint8Array(16);
    window.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  function readPayload() {
    const payload = {};
    Object.entries(inputs).forEach(([key, input]) => {
      input.setCustomValidity("");
      payload[key] = input.value.trim();
      if (input.required && !payload[key]) input.setCustomValidity("Please complete this field.");
    });
    const occurredAt = uaeTimestamp(payload.occurred_at);
    if (!occurredAt) inputs.occurred_at.setCustomValidity("Enter a valid date and time in UAE time.");
    if (!form.reportValidity()) return null;
    payload.occurred_at = occurredAt;
    payload.identifier ||= null;
    return payload;
  }
  function renderReports(rows) {
    recent.innerHTML = rows.length ? rows.map((row) => `<article class="manual-damage-report">
      <div class="manual-damage-report-heading"><div><h3>${escapeHtml(row.model)}</h3><p>Damaged by <strong>${escapeHtml(row.damaged_by)}</strong> · ${row.identifier ? `Identifier: ${escapeHtml(row.identifier)}` : "Identifier unavailable"}</p></div><time datetime="${escapeHtml(row.occurred_at)}">${escapeHtml(dateLabel(row.occurred_at))}</time></div>
      <dl><div><dt>Damage</dt><dd>${escapeHtml(row.damage)}</dd></div><div><dt>Reason</dt><dd>${escapeHtml(row.reason)}</dd></div></dl>
      <p class="manual-damage-report-footer">Reported by ${escapeHtml(row.reported_by || "Unknown reporter")} · ${escapeHtml(dateLabel(row.created_at))}</p>
    </article>`).join("") : '<p class="manual-damage-empty">No manual damage reports yet.</p>';
  }
  async function loadReports(nextOffset = offset) {
    if (accessDenied) return;
    const version = ++loadVersion;
    loading = true;
    updatePager();
    message("manual-damage-history-message");
    try {
      const { data, error } = await api().rpc("get_manual_damage_report_v1", { p_offset: nextOffset, p_limit: pageSize });
      if (error) throw error;
      const report = Array.isArray(data) ? data[0] : data;
      if (!report || !Array.isArray(report.rows)) throw new Error("The recent reports response could not be read.");
      if (version !== loadVersion) return;
      offset = nextOffset;
      hasMore = report.has_more === true;
      renderReports(report.rows);
      const total = Number(report.total_count);
      byId("manual-damage-page-label").textContent = report.rows.length
        ? `Reports ${offset + 1}–${offset + report.rows.length}${Number.isFinite(total) ? ` of ${total}` : ""}`
        : "No reports on this page";
    } catch (error) {
      if (version !== loadVersion) return;
      if (isAccessError(error)) { lockRevokedAccess(); return; }
      message("manual-damage-history-message", error.message || "Recent reports could not be loaded. Select Refresh to retry.");
      if (!recent.querySelector(".manual-damage-report")) {
        recent.innerHTML = '<p class="manual-damage-empty">Recent reports are unavailable. Select Refresh to retry.</p>';
        byId("manual-damage-page-label").textContent = "Reports unavailable";
      }
    } finally {
      if (version === loadVersion) {
        loading = false;
        updatePager();
      }
    }
  }
  async function saveReport(event) {
    event.preventDefault();
    if (saving || !canEdit || !window.GREENLOOP_PAGE_ACCESS?.canEdit) return;
    message("manual-damage-message");
    const payload = readPayload();
    if (!payload) return;
    const fingerprint = JSON.stringify(payload);
    setSaving(true);
    try {
      // An ambiguous failure may already have committed. Retry the same payload
      // with the same UUID so the server can return the original saved report.
      if (!pendingRequest || pendingRequest.fingerprint !== fingerprint) pendingRequest = { id: requestId(), fingerprint };
      const { data, error } = await api().rpc("create_manual_damage_report_v1", {
        p_request_id: pendingRequest.id,
        p_damaged_by: payload.damaged_by,
        p_model: payload.model,
        p_identifier: payload.identifier,
        p_damage: payload.damage,
        p_reason: payload.reason,
        p_occurred_at: payload.occurred_at
      });
      if (error) throw error;
      const saved = Array.isArray(data) ? data[0] : data;
      if (!saved?.id) throw new Error("The server did not confirm the saved report.");
      pendingRequest = null;
      form.reset();
      inputs.occurred_at.value = uaeLocalNow();
      message("manual-damage-message", "Damage report saved. It is now available in Damage Report.", true);
      await loadReports(0);
    } catch (error) {
      if (isAccessError(error)) { lockRevokedAccess(); return; }
      message("manual-damage-message", `${error.message || "The report could not be saved."} Your details are still here. Retry with the same details to avoid a duplicate report.`);
    } finally {
      setSaving(false);
    }
  }
  function setMenu(open) {
    byId("sidebar").classList.toggle("is-open", open);
    byId("menu-backdrop").hidden = !open;
    document.body.classList.toggle("menu-open", open);
  }
  byId("open-menu").addEventListener("click", () => setMenu(true));
  byId("close-menu").addEventListener("click", () => setMenu(false));
  byId("menu-backdrop").addEventListener("click", () => setMenu(false));
  form.addEventListener("submit", saveReport);
  Object.values(inputs).forEach((input) => input.addEventListener("input", () => input.setCustomValidity("")));
  previousButton.addEventListener("click", () => { if (!loading && offset > 0) loadReports(Math.max(0, offset - pageSize)); });
  nextButton.addEventListener("click", () => { if (!loading && hasMore) loadReports(offset + pageSize); });
  refreshButton.addEventListener("click", () => { if (!loading) loadReports(offset); });

  async function start() {
    if (!window.GREENLOOP_CONFIG?.supabaseUrl || !window.GREENLOOP_CONFIG?.supabaseAnonKey || !window.supabase) {
      message("permission-message", "The database connection is not configured.");
      return;
    }
    await window.GREENLOOP_ACCESS_READY;
    const access = window.GREENLOOP_PAGE_ACCESS;
    if (!access || access.pageKey !== "lab_live_board") return;
    canEdit = access.canEdit === true;
    byId("manual-damage-app").hidden = false;
    byId("manual-damage-view-only").hidden = canEdit;
    inputs.occurred_at.value = uaeLocalNow();
    setSaving(false);
    await loadReports(0);
  }
  start().catch((error) => message("permission-message", error.message || "Manual damage entry could not be loaded."));
})();
