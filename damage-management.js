(() => {
  "use strict";

  const limit = 10;
  const escape = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
  const formatDate = new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: true });
  const dateLabel = value => value && Number.isFinite(new Date(value).getTime()) ? formatDate.format(new Date(value)) : "Time unavailable";
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
  const localTime = value => value && Number.isFinite(new Date(value).getTime()) ? new Date(new Date(value).getTime() + 14400000).toISOString().slice(0, 16) : "";
  const asObject = data => Array.isArray(data) ? data[0] : data;
  const accessError = error => [error?.code, error?.status, error?.statusCode].some(value => ["42501", "401", "403", "PGRST301", "PGRST302"].includes(String(value)));
  const rejected = error => ["22023", "22P02", "23514", "23503", "40001", "P0002"].includes(String(error?.code));
  const actionName = action => ({ correct: "Correction", delete: "Entry deleted", reset: "History reset" })[action] || "Change";
  let host = null, generation = 0, mode = "home", scope = "single";
  let search = "", offset = 0, rows = [], total = null, more = false, loaded = false, loading = false;
  let canEdit = false, canReset = false, denied = false, options = null, selected = null, preview = null;
  let busy = false, pending = null, notice = "", noticeType = "", conflict = false;
  let auditOpen = false, auditRows = [], auditOffset = 0, auditTotal = null, auditMore = false, auditLoading = false, auditError = "", auditGeneration = 0;
  const query = selector => host?.querySelector(selector);
  const api = () => window.GREENLOOP_GET_CLIENT();
  const blocked = () => busy || Boolean(pending);
  const editable = () => canEdit && !denied && window.GREENLOOP_PAGE_ACCESS?.canEdit === true;
  const fieldKinds = [
    { key: "employee", group: "employees", label: "Employee", saved: "damaged_by" },
    { key: "model", group: "models", label: "Model", saved: "model" },
    { key: "part", group: "parts", label: "Part name", saved: "part_name" },
    { key: "part_source", group: "part_sources", label: "Part source", saved: "part_source", optional: true },
    { key: "currency", group: "currencies", label: "Currency", saved: "currency", optional: true },
    { key: "reason", group: "reasons", label: "Damage reason", saved: "reason" }
  ];

  async function rpc(name, args) {
    const result = await api().rpc(name, args);
    if (result.error) throw result.error;
    return asObject(result.data);
  }
  function announce(text = "", type = "") {
    notice = text; noticeType = type;
    const el = query("#dm-message");
    if (el) { el.textContent = text; el.hidden = !text; el.className = `dm-message ${type ? `is-${type}` : ""}`; }
  }
  function lockAccess(error) {
    denied = true; canEdit = false; canReset = false; pending = null; selected = null; preview = null;
    rows = []; options = null; total = null; auditRows = []; auditTotal = null;
    loading = false; busy = false; auditLoading = false; generation += 1; auditGeneration += 1;
    notice = "Your session or Reports / TV damage access has changed. Reload after your access is restored.";
    noticeType = "error"; render();
  }
  function displayError(error, fallback) {
    if (accessError(error)) { lockAccess(error); return; }
    announce(error?.message || fallback, "error");
  }
  function recordFacts(row, includeId = true) {
    return `<dl class="dm-facts"><div><dt>Employee</dt><dd>${escape(row.damaged_by || "—")}</dd></div><div><dt>Model</dt><dd>${escape(row.model || "—")}</dd></div><div><dt>${row.part_name ? "Part name" : "Damage description"}</dt><dd>${escape(row.part_name || row.damage || "—")}</dd></div><div><dt>Damaged quantity</dt><dd>${escape(quantityLabel(row))}</dd></div><div><dt>Total price</dt><dd>${escape(totalPrice(row))}</dd></div><div><dt>Price per part</dt><dd>${escape(priceLabel(row.price_amount))}</dd></div><div><dt>Currency</dt><dd>${escape(row.currency || "Not recorded")}</dd></div><div><dt>Part source</dt><dd>${escape(row.part_source || "Not recorded")}</dd></div><div><dt>Damage reason</dt><dd>${escape(row.reason || "—")}</dd></div><div><dt>IMEI / serial</dt><dd>${escape(row.identifier || "Not recorded")}</dd></div><div><dt>Damage time · UAE</dt><dd>${escape(dateLabel(row.occurred_at))}</dd></div>${includeId ? `<div class="dm-wide"><dt>Entry ID</dt><dd class="dm-id">${escape(row.id || "—")}</dd></div>` : ""}</dl>`;
  }
  function homeMarkup() {
    return `<p><a class="secondary-button" href="tv.html?download=1">Damage Report PDF</a></p><div class="dm-modes" aria-label="Manual damage actions"><button class="dm-mode" data-dm-mode="correct" data-search-read-only type="button"><span class="dm-mode-icon" aria-hidden="true">✎</span><strong>Data Correction</strong><span>Find an entry and correct its details.</span><span class="dm-mode-link">Open correction <span aria-hidden="true">→</span></span></button><button class="dm-mode" data-dm-mode="remove" data-search-read-only type="button"><span class="dm-mode-icon is-danger" aria-hidden="true">⊘</span><strong>Delete / Reset</strong><span>Delete one entry or reset the entire manual damage history.</span><span class="dm-mode-link">Open delete / reset <span aria-hidden="true">→</span></span></button></div><p class="dm-note">Manual damage entries are separate from stock and workflow records. Employee and dropdown choices are kept when history is deleted.</p>`;
  }
  function pager(prefix, currentOffset, count, hasMore, isLoading) {
    const end = Math.min(currentOffset + limit, count ?? 0);
    return `<div class="dm-pager"><span>${count === null ? "Records unavailable" : count === 0 ? "No entries" : `Entries ${currentOffset + 1}–${end} of ${Number(count).toLocaleString()}`}</span><div><button type="button" data-dm-page="${prefix}-previous" ${isLoading || blocked() || currentOffset === 0 ? "disabled" : ""}>Previous</button><button type="button" data-dm-page="${prefix}-next" ${isLoading || blocked() || !hasMore ? "disabled" : ""}>Next</button></div></div>`;
  }
  function listMarkup() {
    return `<section aria-labelledby="dm-list-title"><div class="dm-section-heading"><h3 id="dm-list-title">${mode === "correct" ? "Select an entry to correct" : "Select one entry to delete"}</h3><span class="dm-muted">${total === null ? "" : `${total.toLocaleString()} ${search ? "matching" : "total"} entries`}</span></div><form id="dm-search-form" class="dm-search"><div class="dm-field"><label for="dm-search">Search manual damage entries</label><input id="dm-search" name="search" type="search" maxlength="200" placeholder="Employee, model, part, IMEI or entry ID" value="${escape(search)}" ${blocked() ? "disabled" : ""}></div><button type="submit" ${blocked() || loading ? "disabled" : ""}>Search</button><button type="button" data-dm-refresh ${blocked() || loading ? "disabled" : ""}>Refresh</button></form><div class="dm-list" aria-busy="${loading}">${loading ? '<p class="dm-empty">Loading damage entries…</p>' : !loaded ? '<p class="dm-empty">Entries could not be loaded. Select Refresh to try again.</p>' : rows.length ? rows.map(row => `<article class="dm-record ${selected?.id === row.id ? "is-selected" : ""}"><div class="dm-record-top"><strong>${escape(row.damaged_by || "Employee unavailable")}</strong><span>${escape(dateLabel(row.occurred_at))} · UAE</span></div><div class="dm-record-values"><span><small>Model</small>${escape(row.model || "—")}</span><span><small>${row.part_name ? "Part name" : "Damage description"}</small>${escape(row.part_name || row.damage || "—")}</span><span><small>Qty</small>${escape(quantityLabel(row))}</span><span><small>Price per part</small>${escape(priceLabel(row.price_amount))}</span><span><small>Currency</small>${escape(row.currency || "Not recorded")}</span><span><small>Part source</small>${escape(row.part_source || "Not recorded")}</span><span><small>IMEI / serial</small>${escape(row.identifier || "Not recorded")}</span><span><small>Reason</small>${escape(row.reason || "—")}</span></div><div class="dm-record-bottom"><span class="dm-id">Entry ${escape(row.id)}</span><button type="button" data-dm-select="${escape(row.id)}" ${blocked() || !editable() ? "disabled" : ""}>${mode === "correct" ? "Correct entry" : "Review deletion"}</button></div></article>`).join("") : '<p class="dm-empty">No damage entries match this search.</p>'}</div>${pager("records", offset, total, more, loading)}</section>`;
  }
  function optionMarkup(kind) {
    const choices = options?.[kind.group] || [];
    const exact = choices.filter(item => item.label.trim().toLowerCase() === String(selected[kind.saved] || "").trim().toLowerCase());
    const savedId = selected[kind.key + "_id"];
    const archived = kind.optional && savedId && !choices.some(item => item.id === savedId);
    // Optional metadata keeps the saved ID, including an archived choice. Never
    // remap it to a replacement that happens to have the same label.
    const value = savedId ? (archived || choices.some(item => item.id === savedId) ? savedId : "") : !kind.optional && exact.length === 1 ? exact[0].id : "";
    return `<div class="dm-field"><label for="dm-${kind.key}">${kind.label}</label><select id="dm-${kind.key}" name="${kind.key}_id" ${kind.optional ? "" : "required"}><option value="">${kind.optional ? "Not recorded" : "Select " + kind.label.toLowerCase()}</option>${archived ? `<option value="${escape(savedId)}" selected>${escape(selected[kind.saved] || "Saved choice")} (archived — keep saved)</option>` : ""}${choices.map(item => `<option value="${escape(item.id)}" ${item.id === value ? "selected" : ""}>${escape(item.label)}</option>`).join("")}</select>${!value && !kind.optional ? `<small>Saved: ${escape(selected[kind.saved] || selected.damage || "Not recorded")}. Select a current choice.</small>` : ""}</div>`;
  }
  function editorMarkup() {
    if (!selected || mode !== "correct") return "";
    return `<section class="dm-detail" id="dm-editor" aria-labelledby="dm-editor-title"><div class="dm-section-heading"><h3 id="dm-editor-title" tabindex="-1">Correct selected entry</h3><button type="button" data-dm-close ${blocked() ? "disabled" : ""}>Close</button></div><p class="dm-id">Entry ${escape(selected.id)}</p><details class="dm-snapshot"><summary>View saved entry</summary>${recordFacts(selected)}</details><form id="dm-correction-form" data-entry="${escape(selected.id)}"><fieldset ${blocked() || !editable() ? "disabled" : ""}><div class="dm-fields"><div class="dm-field"><label for="dm-quantity">Damaged quantity</label><input id="dm-quantity" name="quantity" type="number" inputmode="numeric" min="1" max="99999" step="1" required value="${escape(quantityLabel(selected))}"></div>${fieldKinds.map(kind => (kind.key === "currency" ? `<div class="dm-field"><label for="dm-price-amount">Price per part <span class="dm-muted">(optional)</span></label><input id="dm-price-amount" name="price_amount" type="text" inputmode="decimal" autocomplete="off" aria-describedby="dm-price-help" value="${escape(selected.price_amount == null ? "" : priceValue(selected.price_amount) ?? "")}" placeholder="e.g. 125.00"><small id="dm-price-help">Leave blank if unknown, or clear to remove the price. 0 is valid. Up to 99,999,999.99 with 2 decimal places. A price requires currency.</small></div>` : "") + optionMarkup(kind)).join("")}<div class="dm-field"><label for="dm-identifier">IMEI / serial <span class="dm-muted">(optional)</span></label><input id="dm-identifier" name="identifier" maxlength="120" value="${escape(selected.identifier || "")}"></div><div class="dm-field"><label for="dm-occurred-at">Damage date and time · UAE</label><input id="dm-occurred-at" name="occurred_at" type="datetime-local" required value="${escape(localTime(selected.occurred_at))}"></div><div class="dm-field dm-wide"><label for="dm-correction-reason">Reason for correction</label><textarea id="dm-correction-reason" name="correction_reason" required minlength="3" maxlength="2000" rows="2" placeholder="Explain what changed and why"></textarea></div></div><div class="dm-actions"><button class="dm-primary" type="submit">Save audited correction</button><span class="dm-muted">Original and corrected values stay in permanent audit history.</span></div></fieldset></form></section>`;
  }
  function removalMarkup() {
    if (mode !== "remove") return "";
    return `<div class="dm-scopes" role="group" aria-label="Deletion scope"><button type="button" data-dm-scope="single" data-search-read-only aria-pressed="${scope === "single"}" ${blocked() ? "disabled" : ""}>Delete one entry</button><button type="button" data-dm-scope="all" data-search-read-only aria-pressed="${scope === "all"}" ${blocked() || !canReset || !editable() ? "disabled" : ""}>Reset entire history</button></div>${!canReset ? '<p class="dm-note">Reset requires owner or administrator access.</p>' : ""}${scope === "single" ? listMarkup() : `<section class="dm-reset-intro"><h3>Reset entire manual damage history</h3><p>Removes all manual damage entries across every date and employee. Current search filters do not limit this reset.</p><p>Employee cards, dropdown choices, permanent audit history, and operational records are kept.</p><button type="button" data-dm-preview-all ${blocked() || !editable() || !canReset ? "disabled" : ""}>Review entire history</button></section>`}${previewMarkup()}`;
  }
  function previewMarkup() {
    if (!preview || mode !== "remove") return "";
    const all = preview.scope === "all";
    return `<section class="dm-detail dm-danger-detail" id="dm-preview" aria-labelledby="dm-preview-title"><div class="dm-section-heading"><h3 id="dm-preview-title" tabindex="-1">${all ? "Review entire history reset" : "Review this entry's deletion"}</h3><button type="button" data-dm-close ${blocked() ? "disabled" : ""}>Cancel</button></div><p class="dm-delete-count">${Number(preview.count).toLocaleString()} ${preview.count === 1 ? "entry" : "entries"} will be permanently deleted.</p>${all ? '<p>All dates and employees are included. Saved audit snapshots remain available below.</p>' : preview.rows.map(row => recordFacts(row)).join("")}${all && preview.rows.length ? `<details class="dm-snapshot"><summary>View ${preview.rows.length} preview entries${preview.count > preview.rows.length ? ` of ${Number(preview.count).toLocaleString()}` : ""}</summary>${preview.rows.map(row => recordFacts(row)).join("")}</details>` : ""}<form id="dm-removal-form" data-entry="${escape(preview.snapshot)}"><fieldset ${blocked() || !editable() ? "disabled" : ""}><div class="dm-fields"><div class="dm-field dm-wide"><label for="dm-deletion-reason">Reason for ${all ? "reset" : "deletion"}</label><textarea id="dm-deletion-reason" name="reason" required minlength="3" maxlength="2000" rows="2" placeholder="Explain why these entries are being removed"></textarea></div><div class="dm-field dm-wide"><label for="dm-confirmation">Type <strong>${escape(preview.confirmation)}</strong> to confirm</label><input id="dm-confirmation" name="confirmation" required autocomplete="off" spellcheck="false" placeholder="${escape(preview.confirmation)}"></div></div><div class="dm-actions"><button class="dm-danger" type="submit" ${preview.count < 1 ? "disabled" : ""}>${all ? "Reset manual damage history" : "Delete this entry"}</button><span class="dm-muted">This action cannot be undone.</span></div></fieldset></form></section>`;
  }
  function auditMarkup() {
    return `<section class="dm-audit" aria-labelledby="dm-audit-title"><div class="dm-section-heading"><div><h3 id="dm-audit-title">Permanent audit history</h3><p>Corrections, deletions and resets remain visible here.</p></div><button type="button" data-dm-audit aria-expanded="${auditOpen}" aria-controls="dm-audit-content" ${blocked() ? "disabled" : ""}>${auditOpen ? "Hide history" : "View history"}</button></div><div id="dm-audit-content" ${auditOpen ? "" : "hidden"} aria-busy="${auditLoading}">${auditError ? `<p class="dm-message is-error">${escape(auditError)}</p><button type="button" data-dm-audit-refresh>Retry audit history</button>` : auditLoading ? '<p class="dm-empty">Loading audit history…</p>' : auditRows.length ? auditRows.map(row => `<article class="dm-audit-entry"><div class="dm-record-top"><strong>${escape(actionName(row.action))}</strong><span>${escape(dateLabel(row.created_at))} · UAE</span></div><p>By ${escape(row.actor_name || row.actor_user_id || "Recorded user")} · ${Number(row.affected_count || 1).toLocaleString()} ${Number(row.affected_count || 1) === 1 ? "entry" : "entries"} in this action</p><p><strong>Reason:</strong> ${escape(row.reason || "—")}</p><p class="dm-id">Entry ${escape(row.report_id)} · Action ${escape(row.operation_id)}</p><details class="dm-snapshot"><summary>View saved values</summary><div class="dm-audit-snapshots"><section><h4>Before</h4>${row.before ? recordFacts(row.before, false) : '<p>No earlier values.</p>'}</section><section><h4>After</h4>${row.after ? recordFacts(row.after, false) : '<p>Entry deleted. The original values are retained above.</p>'}</section></div></details></article>`).join("") : '<p class="dm-empty">No corrections, deletions or resets have been recorded.</p>'}${pager("audit", auditOffset, auditTotal, auditMore, auditLoading)}</div></section>`;
  }
  function render() {
    if (!host) return;
    const drafts = [...host.querySelectorAll('#dm-correction-form, #dm-removal-form')].map(form => ({
      id: form.id, entry: form.dataset.entry,
      values: [...form.elements].filter(control => control.name).map(control => [control.name, control.value])
    }));
    host.innerHTML = `<div class="damage-management">${denied ? `<p class="dm-message is-error" role="alert">${escape(notice)}</p>` : `${mode !== "home" ? `<div class="dm-toolbar"><button type="button" data-dm-home ${blocked() ? "disabled" : ""}>← Manual Damage Report</button><strong>${mode === "correct" ? "Data Correction" : "Delete / Reset"}</strong></div>` : ""}<p id="dm-message" class="dm-message ${noticeType ? `is-${noticeType}` : ""}" role="status" aria-live="polite" ${notice ? "" : "hidden"}>${escape(notice)}</p>${pending ? `<div class="dm-pending" role="alert"><strong>The result is not confirmed.</strong><p>Retry the original action to confirm its result. The entry, reason and request stay exactly the same.</p><button type="button" data-dm-retry ${busy ? "disabled" : ""}>${busy ? "Confirming…" : "Retry original action"}</button></div>` : ""}${loaded && !editable() ? '<p class="dm-note">Viewing only. Changes require Reports and Damage Entry edit permission.</p>' : ""}${mode === "home" ? homeMarkup() : mode === "correct" ? listMarkup() + editorMarkup() : removalMarkup()}${auditMarkup()}`}</div>`;
    for (const draft of drafts) {
      const form = query(`#${draft.id}`);
      if (form && form.dataset.entry === draft.entry) draft.values.forEach(([name, value]) => { const control = form.elements.namedItem(name); if (control) control.value = value; });
    }
  }
  async function load() {
    if (!host || denied || loading || blocked()) return;
    const token = ++generation; loading = true; render();
    try {
      const data = await rpc("get_manual_damage_management_v1", { p_search: search, p_offset: offset, p_limit: limit });
      if (token !== generation || !host || denied) return;
      if (!data || !Array.isArray(data.rows) || !Number.isSafeInteger(Number(data.total_count)) || Number(data.total_count) < 0 || !data.options || !fieldKinds.every(kind => Array.isArray(data.options[kind.group]) && data.options[kind.group].every(item => item && typeof item.id === "string" && typeof item.label === "string")) || !data.rows.every(row => row && typeof row.id === "string" && typeof row.version === "string")) throw new Error("The damage entries response could not be read. Select Refresh to retry.");
      rows = data.rows; total = Number(data.total_count); more = data.has_more === true; options = data.options;
      canEdit = data.can_edit === true; canReset = data.can_reset === true; loaded = true;
      if (offset >= total && offset > 0) { offset = Math.max(0, Math.floor(Math.max(0, total - 1) / limit) * limit); loading = false; return load(); }
    } catch (error) {
      if (token !== generation || !host) return;
      rows = []; total = null; more = false; loaded = false;
      displayError(error, "Damage entries could not be loaded. Select Refresh to retry.");
    } finally { if (token === generation) { loading = false; render(); } }
  }
  async function loadAudit() {
    if (!host || denied || blocked()) return;
    const token = ++auditGeneration; auditLoading = true; auditError = ""; render();
    try {
      const data = await rpc("get_manual_damage_management_audit_v1", { p_id: null, p_offset: auditOffset, p_limit: limit });
      if (!host || denied || token !== auditGeneration) return;
      if (!data || !Array.isArray(data.rows) || !Number.isSafeInteger(Number(data.total_count)) || Number(data.total_count) < 0) throw new Error("The audit response could not be read.");
      auditRows = data.rows; auditTotal = Number(data.total_count); auditMore = data.has_more === true;
    } catch (error) { if (host && token === auditGeneration) { if (accessError(error)) lockAccess(error); else { auditRows = []; auditTotal = null; auditMore = false; auditError = error.message || "Audit history could not be loaded."; } } }
    finally { if (token === auditGeneration) { auditLoading = false; render(); } }
  }
  async function review(id) {
    if (!editable() || blocked() || (id === null && !canReset)) return;
    busy = true; preview = null; announce("Loading deletion preview…"); render();
    const token = generation;
    try {
      const data = await rpc("preview_manual_damage_removal_v1", { p_id: id });
      if (!host || denied || token !== generation) return;
      if (!data || data.scope !== (id ? "single" : "all") || data.id !== id || !Number.isSafeInteger(Number(data.count)) || Number(data.count) < 0 || typeof data.snapshot !== "string" || !data.snapshot || data.confirmation !== (id ? "DELETE ENTRY" : "RESET MANUAL DAMAGE HISTORY") || !Array.isArray(data.rows) || (id && (Number(data.count) !== 1 || data.rows.length !== 1 || data.rows[0].id !== id))) throw new Error("The deletion preview could not be verified. Review the selection again.");
      preview = data; preview.count = Number(data.count); announce();
    } catch (error) { if (host && token === generation) displayError(error, "The deletion preview could not be loaded."); }
    finally { busy = false; render(); query("#dm-preview-title")?.focus(); }
  }
  function uuid() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID();
    const bytes = window.crypto.getRandomValues(new Uint8Array(16)); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, n => n.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  function correctionPayload(form) {
    const data = new FormData(form), payload = { p_request_id: uuid(), p_id: selected.id, p_expected_version: selected.version };
    for (const kind of fieldKinds) {
      const value = String(data.get(`${kind.key}_id`) || "");
      const control = form.elements.namedItem(`${kind.key}_id`);
      const valid = options[kind.group].some(item => item.id === value) || (kind.optional && (!value || value === selected[kind.key + "_id"]));
      control.setCustomValidity(valid ? "" : "Select a current dropdown choice.");
      payload[`p_${kind.key}_id`] = value || null;
    }
    const quantity = quantityValue(data.get("quantity"));
    form.elements.quantity.setCustomValidity(quantity === null ? "Enter a whole quantity from 1 to 99,999." : "");
    payload.p_quantity = quantity;
    const price = priceValue(data.get("price_amount"));
    form.elements.price_amount.setCustomValidity(price === undefined ? "Enter a price from 0 to 99,999,999.99 with no more than 2 decimal places, or leave blank if unknown." : "");
    payload.p_price_amount = price;
    if (price != null && !payload.p_currency_id) form.elements.currency_id.setCustomValidity("Select a currency for this price.");
    const wallTime = String(data.get("occurred_at") || ""), instant = new Date(`${wallTime}:00+04:00`);
    const validTime = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(wallTime) && Number.isFinite(instant.getTime()) && localTime(instant) === wallTime;
    form.elements.occurred_at.setCustomValidity(validTime ? "" : "Enter a valid date and time in UAE time.");
    const reason = String(data.get("correction_reason") || "").trim();
    form.elements.correction_reason.setCustomValidity(reason.length >= 3 ? "" : "Explain the correction in at least 3 characters.");
    if (!form.reportValidity()) return null;
    // A correction to another field must not truncate the original seconds or
    // fractional seconds merely because datetime-local displays whole minutes.
    const occurredAt = wallTime === localTime(selected.occurred_at) ? selected.occurred_at : instant.toISOString();
    return { ...payload, p_identifier: String(data.get("identifier") || "").trim() || null, p_occurred_at: occurredAt, p_correction_reason: reason };
  }
  async function mutate(operation) {
    if (!editable() || busy) return;
    pending = operation; busy = true; conflict = false;
    // Keep drafts in place while sending. An ambiguous response keeps this exact
    // immutable payload and UUID; never generate another operation on retry.
    query("#dm-correction-form fieldset")?.setAttribute("disabled", "");
    query("#dm-removal-form fieldset")?.setAttribute("disabled", "");
    host.querySelectorAll("button").forEach(button => { button.disabled = true; });
    announce("Saving audited action…");
    let success = false;
    try {
      const data = await rpc(operation.rpc, operation.args);
      if (denied || !host) return;
      if (!data || typeof data.operation_id !== "string" || !data.operation_id || !["correct", "delete", "reset"].includes(data.action) || !Number.isSafeInteger(Number(data.affected_count)) || (operation.rpc === "correct_manual_damage_report_v3" && (data.action !== "correct" || Number(data.affected_count) !== 1 || data.row?.id !== operation.args.p_id || data.row?.quantity !== operation.args.p_quantity || typeof data.row?.version !== "string" || !data.row.version)) || (operation.rpc === "remove_manual_damage_reports_v1" && (data.action !== (operation.args.p_id ? "delete" : "reset") || Number(data.affected_count) !== operation.args.p_expected_count))) throw new Error("The server response did not confirm the action.");
      pending = null; selected = null; preview = null; success = true;
      announce(`${actionName(data.action)} saved. ${Number(data.affected_count).toLocaleString()} ${Number(data.affected_count) === 1 ? "entry" : "entries"} affected. Permanent audit history is available below.`, "success");
    } catch (error) {
      if (denied || !host) return;
      if (accessError(error)) { lockAccess(error); return; }
      if (rejected(error)) {
        pending = null;
        if (String(error.code) === "40001" || String(error.code) === "P0002") { conflict = true; selected = null; preview = null; }
        announce(`${error.message || "The action was rejected."}${conflict ? " Refresh and select the entry again before making changes." : " Review the values and try again."}`, "error");
      } else announce(error.message || "The connection ended before the action could be confirmed.", "error");
    } finally {
      busy = false;
      if (host && !denied) {
        render();
      }
    }
    if (success && host && !denied) { await load(); if (auditOpen) { auditOffset = 0; await loadAudit(); } }
  }
  function onSubmit(event) {
    const form = event.target;
    if (!["dm-search-form", "dm-correction-form", "dm-removal-form"].includes(form.id)) return;
    event.preventDefault(); if (blocked() || denied) return;
    if (form.id === "dm-search-form") { search = String(new FormData(form).get("search") || "").trim(); offset = 0; selected = null; preview = null; announce(); load(); return; }
    if (!editable()) return;
    if (form.id === "dm-correction-form" && selected) {
      const args = correctionPayload(form); if (args) mutate({ rpc: "correct_manual_damage_report_v3", args: Object.freeze(args) });
    } else if (form.id === "dm-removal-form" && preview && preview.count > 0 && (preview.scope !== "all" || canReset)) {
      const values = new FormData(form), reason = String(values.get("reason") || "").trim(), confirmation = String(values.get("confirmation") || "");
      form.elements.reason.setCustomValidity(reason.length >= 3 ? "" : "Explain the deletion in at least 3 characters.");
      form.elements.confirmation.setCustomValidity(confirmation === preview.confirmation ? "" : `Type ${preview.confirmation} exactly.`);
      if (!form.reportValidity()) return;
      mutate({ rpc: "remove_manual_damage_reports_v1", args: Object.freeze({ p_request_id: uuid(), p_id: preview.id, p_expected_snapshot: preview.snapshot, p_expected_count: preview.count, p_confirmation: confirmation, p_reason: reason }) });
    }
  }
  function onClick(event) {
    const button = event.target.closest("button"); if (!button || !host.contains(button) || button.disabled || denied) return;
    if (button.hasAttribute("data-dm-retry")) { if (pending && !busy) mutate(pending); return; }
    if (blocked()) return;
    if (button.dataset.dmMode || button.hasAttribute("data-dm-home")) {
      mode = button.dataset.dmMode || "home"; selected = null; preview = null; scope = "single"; announce(); render(); if (!loaded && !loading) load();
    } else if (button.dataset.dmScope) { scope = button.dataset.dmScope; selected = null; preview = null; announce(); render(); }
    else if (button.hasAttribute("data-dm-refresh")) { selected = null; preview = null; announce(); load(); }
    else if (button.dataset.dmSelect) {
      if (!editable()) return; selected = rows.find(row => row.id === button.dataset.dmSelect) || null;
      if (!selected) return;
      announce(); if (mode === "remove") review(selected.id); else { render(); query("#dm-editor-title")?.focus(); }
    } else if (button.hasAttribute("data-dm-preview-all")) review(null);
    else if (button.hasAttribute("data-dm-close")) { selected = null; preview = null; announce(); render(); }
    else if (button.hasAttribute("data-dm-audit")) { auditOpen = !auditOpen; render(); if (auditOpen) loadAudit(); }
    else if (button.hasAttribute("data-dm-audit-refresh")) loadAudit();
    else if (button.dataset.dmPage) {
      const [kind, direction] = button.dataset.dmPage.split("-");
      if (kind === "audit") { auditOffset = Math.max(0, auditOffset + (direction === "next" ? limit : -limit)); loadAudit(); }
      else { offset = Math.max(0, offset + (direction === "next" ? limit : -limit)); selected = null; preview = null; announce(); load(); }
    }
  }
  function onInput(event) {
    if (event.target.setCustomValidity) event.target.setCustomValidity("");
    if (event.target.name === "price_amount") query("#dm-currency")?.setCustomValidity("");
  }
  function unmount() {
    if (!host || blocked()) return;
    host.removeEventListener("click", onClick); host.removeEventListener("submit", onSubmit); host.removeEventListener("input", onInput);
    host = null; generation += 1; auditGeneration += 1; loading = false; auditLoading = false;
    selected = null; preview = null; auditOpen = false; auditRows = []; options = null; loaded = false;
  }
  function mount(container) {
    if (host === container) return;
    unmount(); host = container; denied = false; canEdit = false; canReset = false; mode = "home"; scope = "single"; notice = ""; noticeType = ""; offset = 0; search = ""; total = null; rows = []; loaded = false;
    auditRows = []; auditOffset = 0; auditTotal = null; auditMore = false; auditError = "";
    host.addEventListener("click", onClick); host.addEventListener("submit", onSubmit); host.addEventListener("input", onInput);
    render(); load();
  }
  window.addEventListener("beforeunload", event => { if (blocked()) { event.preventDefault(); event.returnValue = ""; } });
  window.GREENLOOP_DAMAGE_MANAGEMENT = Object.freeze({ mount, unmount, isBusy: blocked, refresh: load });
})();
