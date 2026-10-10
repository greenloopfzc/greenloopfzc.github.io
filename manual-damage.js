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
    currency: { key: "currencies", name: "currency", label: "Currency", limit: 20, optional: true, defaultLabel: "AED", input: byId("damage-currency") },
    part_source: { key: "part_sources", name: "part source", label: "Part source", limit: 120, optional: true, defaultLabel: "Local", input: byId("damage-part-source") },
    reason: { key: "reasons", name: "reason", label: "Reason", limit: 2000, input: byId("damage-reason") }
  };
  const inputs = {
    employee_id: choices.employee.input,
    department: byId("damage-department"),
    model_id: choices.model.input,
    part_id: choices.part.input,
    quantity: byId("damage-quantity"),
    price_amount: byId("damage-price-amount"),
    currency_id: choices.currency.input,
    part_source_id: choices.part_source.input,
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
  let defaultsPending = true;
  let departmentDefaults = {};
  let catalog = { employees: [], models: [], parts: [], reasons: [], currencies: [], part_sources: [] };
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
  // Keep money as a decimal string: reject excess precision before any rounding.
  function priceValue(value) {
    const text = String(value ?? "").trim();
    if (!text) return null;
    if (!/^(?:\d+|\d*\.\d{1,2})$/.test(text)) return undefined;
    const [integer, fraction = ""] = text.split(".");
    const whole = (integer || "0").replace(/^0+(?=\d)/, "");
    if (whole.length > 8) return undefined;
    return whole + "." + fraction.padEnd(2, "0");
  }
  const priceLabel = value => {
    const price = priceValue(value);
    return price == null ? "Not recorded" : price;
  };
  function quantityValue(value) {
    const text = String(value ?? "").trim();
    return /^\d+$/.test(text) && Number(text) >= 1 && Number(text) <= 99999 ? Number(text) : null;
  }
  const quantityLabel = row => quantityValue(row.quantity ?? 1) ?? "Not recorded";
  function totalPrice(row) {
    const unit = priceValue(row.price_amount), quantity = quantityValue(row.quantity ?? 1);
    if (unit == null || quantity === null) return "Not recorded";
    const cents = Number(unit.replace(".", "")) * quantity;
    return Math.floor(cents / 100) + "." + String(cents % 100).padStart(2, "0");
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
    catalog = { employees: [], models: [], parts: [], reasons: [], currencies: [], part_sources: [] };
    pendingRequest = null;
    optionOperation = null;
    loadVersion += 1;
    loading = false;
    offset = 0;
    hasMore = false;
    if (dialog.open) dialog.close();
    if (byId("damage-record-dialog").open) byId("damage-record-dialog").close();
    byId("damage-record-details").textContent = "";
    recentRows = [];
    // Discard sensitive choices and drafts, including hidden dialog/retry text.
    // In-flight requests also check accessDenied before touching these values.
    Object.values(inputs).forEach((input) => { input.value = ""; input.setCustomValidity(""); });
    window.GREENLOOP_AMPM_INPUT.sync(inputs.occurred_at);
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
    message("permission-message", "Your session or Damage Entry access has changed. Sign in again or ask an administrator to restore access, then reload this page.");
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
      if ((!choice.optional || payload[`${kind}_id`]) && !catalog[choice.key].some((item) => String(item.id) === payload[`${kind}_id`])) choice.input.setCustomValidity(`Select an active ${choice.name}. Use + Add if it is missing.`);
    });
    inputs.department.setCustomValidity(["glass", "other"].includes(payload.department) ? "" : "Select the technician department.");
    const quantity = quantityValue(payload.quantity);
    inputs.quantity.setCustomValidity(quantity === null ? "Enter a whole quantity from 1 to 99,999." : "");
    const price = priceValue(payload.price_amount);
    inputs.price_amount.setCustomValidity(price === undefined ? "Enter a price from 0 to 99,999,999.99 with no more than 2 decimal places, or leave blank if unknown." : "");
    if (price != null && !payload.currency_id) inputs.currency_id.setCustomValidity("Select a currency for this price.");
    const occurredAt = uaeTimestamp(payload.occurred_at);
    if (!occurredAt) window.GREENLOOP_AMPM_INPUT.validity(inputs.occurred_at, "Enter a valid date and time in UAE time.");
    if (!form.reportValidity()) return null;
    payload.quantity = quantity;
    payload.price_amount = price;
    payload.currency_id ||= null;
    payload.part_source_id ||= null;
    payload.occurred_at = occurredAt;
    payload.identifier ||= null;
    return payload;
  }
  function applyNewDefaults() {
    Object.values(choices).filter(choice => choice.defaultLabel).forEach(choice => {
      choice.input.value = String(catalog[choice.key].find(item => item.label.toLowerCase() === choice.defaultLabel.toLowerCase())?.id || "");
    });
  }
  function renderChoices() {
    const removed = [];
    Object.values(choices).forEach((choice) => {
      const selected = choice.input.value;
      const items = catalog[choice.key];
      choice.input.innerHTML = `<option value="">${choice.optional ? "Not recorded" : items.length ? `Select ${choice.name}` : `No ${choice.name} choices — use + Add`}</option>` + items.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.label)}</option>`).join("");
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
      const departments = await api().rpc("get_manual_damage_department_defaults_v1");
      if (accessDenied) return false;
      if (departments.error) throw departments.error;
      departmentDefaults = departments.data || {};
      catalog = result;
      catalogReady = true;
      const removed = renderChoices();
      if (defaultsPending) { applyNewDefaults(); defaultsPending = false; syncControls(); }
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
  let recentRows = [], detailTrigger = null;
  function renderReports(rows) {
    recentRows = rows;
    recent.innerHTML = rows.length ? '<div class="damage-recent-shell"><table class="damage-recent-table"><caption class="sr-only">Recent damage entries</caption><colgroup><col class="recent-date"><col class="recent-employee"><col class="recent-model"><col class="recent-part"><col class="recent-quantity"><col class="recent-price"><col class="recent-source"><col class="recent-reason"><col class="recent-action"></colgroup><thead><tr>' +
      ["Date · UAE", "Employee", "Model", "Part name", "Qty", "Price / part", "Source", "Reason", "Details"].map(label => '<th scope="col">' + label + '</th>').join("") + '</tr></thead><tbody>' + rows.map((row, index) => {
        const cell = (label, value, extra = "") => '<td data-label="' + label + '"' + extra + '><span class="recent-cell-text">' + escapeHtml(value) + '</span></td>';
        return '<tr class="manual-damage-report">' + cell("Date · UAE", dateLabel(row.occurred_at)) + cell("Employee", row.damaged_by) + cell("Model", row.model) + cell("Part name", row.part_name || row.damage) + cell("Qty", quantityLabel(row)) + cell("Price / part", priceLabel(row.price_amount) + (row.currency ? " " + row.currency : "")) + cell("Source", row.part_source || "—") + cell("Reason", row.reason) + '<td data-label="Details"><button type="button" class="secondary-button recent-view" data-damage-details="' + index + '" aria-label="View damage report for ' + escapeHtml(row.damaged_by) + '">View</button></td></tr>';
      }).join("") + '</tbody></table></div>' : '<p class="manual-damage-empty">No manual damage reports yet.</p>';
  }
  recent.addEventListener("click", event => {
    const trigger = event.target.closest("[data-damage-details]");
    if (!trigger || accessDenied) return;
    const row = recentRows[Number(trigger.dataset.damageDetails)];
    if (!row) return;
    detailTrigger = trigger;
    const facts = [["Damaged by", row.damaged_by], ["Model", row.model], ["Part name", row.part_name || row.damage], ["Damaged quantity", quantityLabel(row)], ["Price per part", priceLabel(row.price_amount)], ["Total price", totalPrice(row)], ["Currency", row.currency || "Not recorded"], ["Part source", row.part_source || "Not recorded"], ["Reason", row.reason], ["IMEI / serial / device number", row.identifier || "Not recorded"], ["Damage time · UAE", dateLabel(row.occurred_at)], ["Reported by", row.reported_by || "Unknown reporter"], ["Reported at · UAE", dateLabel(row.created_at)]];
    byId("damage-record-details").innerHTML = '<dl class="damage-record-facts">' + facts.map(([label, value]) => '<div><dt>' + label + '</dt><dd>' + escapeHtml(value) + '</dd></div>').join("") + '</dl>';
    byId("damage-record-dialog").showModal();
    byId("damage-record-close").focus();
  });
  byId("damage-record-close").addEventListener("click", () => byId("damage-record-dialog").close());
  byId("damage-record-dialog").addEventListener("close", () => { byId("damage-record-details").textContent = ""; if (detailTrigger?.isConnected) detailTrigger.focus(); });
  async function loadReports(nextOffset = offset) {
    if (accessDenied) return;
    const version = ++loadVersion;
    loading = true;
    updatePager();
    message("manual-damage-history-message");
    try {
      const { data, error } = await api().rpc("get_manual_damage_report_v2", { p_offset: nextOffset, p_limit: pageSize });
      if (error) throw error;
      const report = Array.isArray(data) ? data[0] : data;
      if (!report || !Array.isArray(report.rows)) throw new Error("The recent reports response could not be read.");
      if (version !== loadVersion) return;
      offset = nextOffset;
      hasMore = report.has_more === true;
      renderReports(report.rows);
      const total = Number(report.record_count);
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
      const { data, error } = await api().rpc("create_manual_damage_report_v5", request.args);
      if (accessDenied) return;
      if (error) throw error;
      const saved = Array.isArray(data) ? data[0] : data;
      if (!saved?.id || saved.quantity !== request.args.p_quantity || saved.department !== request.args.p_department) throw new Error("The server did not confirm the saved report.");
      pendingRequest = null;
      const draftChanged = JSON.stringify(draftValues()) !== request.fingerprint;
      if (!draftChanged) { form.reset(); applyNewDefaults(); inputs.occurred_at.value = uaeLocalNow(); window.GREENLOOP_AMPM_INPUT.sync(inputs.occurred_at); }
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
      summary: Object.values(choices).map((choice) => catalog[choice.key].find((item) => String(item.id) === choice.input.value)?.label || "").concat("Qty " + payload.quantity, priceLabel(payload.price_amount)).join(" · "),
      args: Object.freeze({ p_request_id: requestId(), p_employee_id: payload.employee_id, p_department: payload.department, p_model_id: payload.model_id, p_part_id: payload.part_id, p_quantity: payload.quantity, p_price_amount: payload.price_amount, p_currency_id: payload.currency_id, p_part_source_id: payload.part_source_id, p_reason_id: payload.reason_id, p_identifier: payload.identifier, p_occurred_at: payload.occurred_at })
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
    const changed = () => { input.setCustomValidity(""); if (input === inputs.price_amount) inputs.currency_id.setCustomValidity(""); syncControls(); };
    input.addEventListener("input", changed);
    input.addEventListener("change", changed);
  });
  inputs.employee_id.addEventListener("change", () => {
    inputs.department.value = departmentDefaults[inputs.employee_id.value] || "";
    inputs.department.setCustomValidity("");
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

  function watchAccount() {
    // Lock entry controls on sign-out or account change.
    // No RPC is called from the auth callback.
    let accountId = null;
    api().auth.onAuthStateChange?.((event, session) => {
      const nextId = session?.user?.id;
      if (event === "SIGNED_OUT" || (accountId && nextId !== accountId)) {
        lockRevokedAccess();
      }
      if (nextId) accountId = nextId;
    });
  }

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
    inputs.occurred_at.value = uaeLocalNow(); window.GREENLOOP_AMPM_INPUT.sync(inputs.occurred_at);
    syncControls();
    watchAccount();
    await Promise.all([loadChoices(), loadReports(0)]);
  }
  start().catch((error) => message("permission-message", error.message || "Manual damage entry could not be loaded."));
})();
