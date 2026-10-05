(() => {
  "use strict";

  const pageSize = 8;
  const byId = (id) => document.getElementById(id);
  const form = byId("manual-damage-form");
  const fields = byId("manual-damage-fields");
  const saveButton = byId("save-manual-damage");
  const retryButton = byId("retry-manual-damage");
  const recent = byId("manual-damage-recent");
  const previousButton = byId("manual-damage-previous");
  const nextButton = byId("manual-damage-next");
  const refreshButton = byId("refresh-manual-damage");
  const optionsRefresh = byId("refresh-damage-options");
  const dialog = byId("damage-option-dialog");
  const optionForm = byId("damage-option-form");
  const optionInput = byId("damage-option-label");
  const optionButtons = Array.from(document.querySelectorAll("[data-option-action]"));
  const choices = {
    employee: { key: "employees", name: "employee", label: "Employee name", limit: 120, input: byId("damage-person") },
    model: { key: "models", name: "model", label: "Model", limit: 160, input: byId("damage-model") },
    part: { key: "parts", name: "part name", label: "Part Name", limit: 120, input: byId("damage-part") },
    reason: { key: "reasons", name: "reason", label: "Reason", limit: 2000, input: byId("damage-reason") }
  };
  const inputs = {
    employee_id: choices.employee.input,
    model_id: choices.model.input,
    part_id: choices.part.input,
    reason_id: choices.reason.input,
    identifier: byId("damage-identifier"),
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
  let catalogReady = false;
  let catalogLoading = false;
  let catalog = { employees: [], models: [], parts: [], reasons: [] };
  let optionOperation = null;
  let optionBusy = false;
  let dialogTrigger = null;

  const api = () => (client ||= window.GREENLOOP_GET_CLIENT());
  const editable = () => canEdit && !accessDenied && window.GREENLOOP_PAGE_ACCESS?.canEdit === true;
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
  function syncControls() {
    const blocked = saving || optionBusy || !editable() || !catalogReady;
    fields.disabled = blocked;
    saveButton.disabled = blocked || Boolean(pendingRequest) || catalogLoading;
    saveButton.textContent = saving ? "Saving…" : "Save damage report";
    retryButton.disabled = saving || optionBusy || !editable();
    retryButton.textContent = saving ? "Confirming…" : "Retry original report";
    optionsRefresh.disabled = accessDenied || catalogLoading || saving || optionBusy;
    optionButtons.forEach((button) => {
      button.disabled = blocked || catalogLoading || (button.dataset.optionAction === "delete" && !choices[button.dataset.optionKind].input.value);
    });
    byId("damage-option-confirm").disabled = optionBusy || !editable();
    byId("damage-option-cancel").disabled = optionBusy;
    optionInput.disabled = optionBusy;
    form.setAttribute("aria-busy", String(saving));
    optionForm.setAttribute("aria-busy", String(optionBusy));
    byId("manual-damage-pending").hidden = !pendingRequest || accessDenied;
  }
  function setSaving(value) { saving = value; syncControls(); }
  function updatePager() {
    previousButton.disabled = accessDenied || loading || offset === 0;
    nextButton.disabled = accessDenied || loading || !hasMore;
    refreshButton.disabled = accessDenied || loading;
    recent.setAttribute("aria-busy", String(loading));
  }
  function isAccessError(error) {
    return [error?.code, error?.status, error?.statusCode].some((value) => ["42501", "401", "403", "PGRST301", "PGRST302"].includes(String(value)));
  }
  function isValidationError(error) {
    // Explicit server validation failures cannot have committed a report.
    return ["22023", "22P02", "23514", "23503"].includes(String(error?.code)) ||
      [error?.status, error?.statusCode].some((value) => String(value) === "400");
  }
  function lockRevokedAccess() {
    accessDenied = true;
    canEdit = false;
    catalogReady = false;
    catalog = { employees: [], models: [], parts: [], reasons: [] };
    pendingRequest = null;
    optionOperation = null;
    loadVersion += 1;
    loading = false;
    offset = 0;
    hasMore = false;
    if (dialog.open) dialog.close();
    // Discard sensitive choices and drafts, including hidden dialog/retry text.
    // In-flight requests also check accessDenied before touching these values.
    Object.values(inputs).forEach((input) => { input.value = ""; input.setCustomValidity(""); });
    Object.values(choices).forEach((choice) => { choice.input.innerHTML = '<option value="">Access unavailable</option>'; });
    optionInput.value = "";
    message("damage-option-description");
    message("damage-option-message");
    message("manual-damage-pending-summary");
    byId("manual-damage-app").hidden = true;
    setSaving(false);
    updatePager();
    recent.innerHTML = '<p class="manual-damage-empty">Reports are hidden because your session or access has changed.</p>';
    byId("manual-damage-page-label").textContent = "Access unavailable";
    byId("manual-damage-view-only").hidden = true;
    message("manual-damage-message");
    message("manual-damage-history-message");
    message("manual-damage-options-message");
    message("permission-message", "Your session or TV Manual Entry access has changed. Sign in again or ask an administrator to restore access, then reload this page.");
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
  function draftValues() {
    return Object.fromEntries(Object.entries(inputs).map(([key, input]) => [key, input.value.trim()]));
  }
  function readPayload() {
    const payload = draftValues();
    Object.entries(inputs).forEach(([key, input]) => {
      input.setCustomValidity(input.required && !payload[key] ? "Please complete this field." : "");
    });
    Object.entries(choices).forEach(([kind, choice]) => {
      if (!catalog[choice.key].some((item) => String(item.id) === payload[`${kind}_id`])) choice.input.setCustomValidity(`Select an active ${choice.name}. Use + Add if it is missing.`);
    });
    const occurredAt = uaeTimestamp(payload.occurred_at);
    if (!occurredAt) inputs.occurred_at.setCustomValidity("Enter a valid date and time in UAE time.");
    if (!form.reportValidity()) return null;
    payload.occurred_at = occurredAt;
    payload.identifier ||= null;
    return payload;
  }
  function renderChoices() {
    const removed = [];
    Object.values(choices).forEach((choice) => {
      const selected = choice.input.value;
      const items = catalog[choice.key];
      choice.input.innerHTML = `<option value="">${items.length ? `Select ${choice.name}` : `No ${choice.name} choices — use + Add`}</option>` + items.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.label)}</option>`).join("");
      if (items.some((item) => String(item.id) === selected)) choice.input.value = selected;
      else if (selected) { removed.push(choice.label); choice.input.setCustomValidity(""); }
    });
    syncControls();
    return removed;
  }
  async function loadChoices() {
    if (accessDenied || catalogLoading) return false;
    catalogLoading = true;
    syncControls();
    message("manual-damage-options-message", "Refreshing dropdown choices…");
    try {
      const { data, error } = await api().rpc("get_manual_damage_options_v1");
      if (accessDenied) return false;
      if (error) throw error;
      const result = Array.isArray(data) ? data[0] : data;
      if (!result || !Object.values(choices).every((choice) => Array.isArray(result[choice.key]) && result[choice.key].every((item) => item && item.id != null && typeof item.label === "string"))) throw new Error("The dropdown choices response could not be read.");
      catalog = result;
      catalogReady = true;
      const removed = renderChoices();
      message("manual-damage-options-message", removed.length ? `${removed.join(", ")} no longer available. Select another choice; your other details are kept.` : "Choices are shared with the workshop. Use + Add for a missing choice.");
      return true;
    } catch (error) {
      if (accessDenied) return false;
      if (isAccessError(error)) lockRevokedAccess();
      else message("manual-damage-options-message", `${error.message || "Dropdown choices could not be loaded."} Select Refresh choices to retry.`);
      return false;
    } finally {
      catalogLoading = false;
      syncControls();
    }
  }
  function openOptionDialog(button) {
    if (!editable() || saving || optionBusy || catalogLoading || !catalogReady) return;
    const kind = button.dataset.optionKind;
    const choice = choices[kind];
    const action = button.dataset.optionAction;
    const item = catalog[choice.key].find((entry) => String(entry.id) === choice.input.value);
    if (action === "delete" && !item) return;
    dialogTrigger = button;
    optionOperation = { kind, action, item };
    optionInput.value = "";
    optionInput.setCustomValidity("");
    optionInput.maxLength = choice.limit;
    optionInput.required = action === "add";
    byId("damage-option-label-field").hidden = action !== "add";
    byId("damage-option-title").textContent = `${action === "add" ? "Add" : "Delete"} ${choice.name}`;
    byId("damage-option-label-title").textContent = choice.label;
    byId("damage-option-limit").textContent = `Maximum ${choice.limit.toLocaleString()} characters.`;
    byId("damage-option-description").textContent = action === "add"
      ? `Add a ${choice.name} to the shared dropdown.`
      : `Delete “${item.label}” from the ${choice.name} choices${kind === "employee" ? " and employee cards" : ""}? Existing reports and their saved names will remain.`;
    byId("damage-option-confirm").textContent = action === "add" ? "Add" : "Delete choice";
    byId("damage-option-confirm").classList.toggle("is-delete", action === "delete");
    message("damage-option-message");
    syncControls();
    dialog.showModal();
    (action === "add" ? optionInput : byId("damage-option-cancel")).focus();
  }
  async function commitOption(event) {
    event.preventDefault();
    if (!editable() || optionBusy || saving || !optionOperation || !dialog.open) return;
    const operation = optionOperation;
    const choice = choices[operation.kind];
    const label = optionInput.value.trim();
    optionInput.setCustomValidity(operation.action === "add" && (!label || label.length > choice.limit) ? `Enter a ${choice.name} of 1–${choice.limit} characters.` : "");
    if (!optionForm.reportValidity()) return;
    optionBusy = true;
    syncControls();
    message("damage-option-message");
    try {
      const { data, error } = operation.action === "add"
        ? await api().rpc("add_manual_damage_option_v1", { p_kind: operation.kind, p_label: label })
        : await api().rpc("archive_manual_damage_option_v1", { p_kind: operation.kind, p_id: operation.item.id });
      if (accessDenied) return;
      if (error) throw error;
      const result = Array.isArray(data) ? data[0] : data;
      if (!result?.id || (operation.action === "add" && typeof result.label !== "string")) throw new Error("The server did not confirm the change. Refresh choices before trying again.");
      if (operation.action === "add") {
        catalog[choice.key] = catalog[choice.key].filter((item) => String(item.id) !== String(result.id)).concat(result).sort((a, b) => a.label.localeCompare(b.label));
        renderChoices();
        choice.input.value = String(result.id);
        choice.input.setCustomValidity("");
      } else {
        catalog[choice.key] = catalog[choice.key].filter((item) => String(item.id) !== String(operation.item.id));
        renderChoices();
      }
      dialog.close();
      // Refresh the shared catalog, retaining any unrelated form selections.
      await loadChoices();
    } catch (error) {
      if (accessDenied) return;
      if (isAccessError(error)) { lockRevokedAccess(); return; }
      message("damage-option-message", error.message || "The choice could not be changed. Please try again.");
      if (isValidationError(error)) await loadChoices();
    } finally {
      optionBusy = false;
      syncControls();
    }
  }
  function renderReports(rows) {
    recent.innerHTML = rows.length ? rows.map((row) => `<article class="manual-damage-report">
      <div class="manual-damage-report-heading"><div><h3>${escapeHtml(row.model)}</h3><p>Damaged by <strong>${escapeHtml(row.damaged_by)}</strong> · ${row.identifier ? `Identifier: ${escapeHtml(row.identifier)}` : "Identifier unavailable"}</p></div><time datetime="${escapeHtml(row.occurred_at)}">${escapeHtml(dateLabel(row.occurred_at))}</time></div>
      <dl><div><dt>${row.part_name ? "Part Name" : "Damage description"}</dt><dd>${escapeHtml(row.part_name || row.damage)}</dd></div><div><dt>Reason</dt><dd>${escapeHtml(row.reason)}</dd></div></dl>
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
      if (version === loadVersion) { loading = false; updatePager(); }
    }
  }
  async function sendReport(request) {
    if (saving || optionBusy || !editable()) return;
    setSaving(true);
    message("manual-damage-message");
    try {
      // The complete arguments are frozen at the first attempt. A retry remains
      // identical even after catalog refresh, archiving, or edits to the draft.
      const { data, error } = await api().rpc("create_manual_damage_report_v2", request.args);
      if (accessDenied) return;
      if (error) throw error;
      const saved = Array.isArray(data) ? data[0] : data;
      if (!saved?.id) throw new Error("The server did not confirm the saved report.");
      pendingRequest = null;
      const draftChanged = JSON.stringify(draftValues()) !== request.fingerprint;
      if (!draftChanged) { form.reset(); inputs.occurred_at.value = uaeLocalNow(); }
      message("manual-damage-message", draftChanged ? "Original damage report confirmed. Your current draft has been kept." : "Damage report saved. It is now available in Damage Report.", true);
      await loadReports(0);
    } catch (error) {
      if (accessDenied) return;
      if (isAccessError(error)) { lockRevokedAccess(); return; }
      if (isValidationError(error)) {
        pendingRequest = null;
        await loadChoices();
        if (!accessDenied) message("manual-damage-message", `${error.message || "The report needs an updated choice."} Review the dropdowns and save again. Your other details are kept.`);
      } else {
        byId("manual-damage-pending-summary").textContent = `Confirm the original report for ${request.summary}. Retry uses those original details, including any choice since deleted. Any changes you make in the form will be kept as a separate draft.`;
        message("manual-damage-message", `${error.message || "The report could not be confirmed."} It may already be saved. Select Retry original report before saving another report.`);
      }
    } finally { setSaving(false); }
  }
  async function saveReport(event) {
    event.preventDefault();
    if (saving || optionBusy || pendingRequest || catalogLoading || !catalogReady || !editable()) return;
    const payload = readPayload();
    if (!payload) return;
    pendingRequest = {
      fingerprint: JSON.stringify(draftValues()),
      summary: Object.values(choices).map((choice) => catalog[choice.key].find((item) => String(item.id) === choice.input.value)?.label || "").join(" · "),
      args: Object.freeze({ p_request_id: requestId(), p_employee_id: payload.employee_id, p_model_id: payload.model_id, p_part_id: payload.part_id, p_reason_id: payload.reason_id, p_identifier: payload.identifier, p_occurred_at: payload.occurred_at })
    };
    await sendReport(pendingRequest);
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
  retryButton.addEventListener("click", () => { if (pendingRequest) sendReport(pendingRequest); });
  Object.values(inputs).forEach((input) => {
    const changed = () => { input.setCustomValidity(""); syncControls(); };
    input.addEventListener("input", changed);
    input.addEventListener("change", changed);
  });
  optionButtons.forEach((button) => button.addEventListener("click", () => openOptionDialog(button)));
  optionForm.addEventListener("submit", commitOption);
  optionInput.addEventListener("input", () => optionInput.setCustomValidity(""));
  byId("damage-option-cancel").addEventListener("click", () => { if (!optionBusy) dialog.close(); });
  dialog.addEventListener("cancel", (event) => { if (optionBusy) event.preventDefault(); });
  dialog.addEventListener("close", () => { optionOperation = null; if (dialogTrigger && !dialogTrigger.disabled) dialogTrigger.focus(); });
  optionsRefresh.addEventListener("click", () => { if (!saving && !optionBusy) loadChoices(); });
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
    if (!access || access.pageKey !== "tv_manual_entry") return;
    canEdit = access.canEdit === true;
    byId("manual-damage-app").hidden = false;
    byId("manual-damage-view-only").hidden = canEdit;
    inputs.occurred_at.value = uaeLocalNow();
    syncControls();
    await Promise.all([loadChoices(), loadReports(0)]);
  }
  start().catch((error) => message("permission-message", error.message || "Manual damage entry could not be loaded."));
})();
