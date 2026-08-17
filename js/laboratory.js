(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const isFrameMode = window.location.hash.toLowerCase() === "#frame";
  window.addEventListener("hashchange", () => window.location.reload());
  const standardParts = ["Case", "Glass", "Touch panel", "NFC flex", "Vibrator", "Speaker", "Camera", "Face ID flex", "LCD display", "Battery", "Charging flex"];
  const standardServices = ["Polish", "Cleaning", "Software", "Testing", "Face ID calibration", "Camera calibration", "Housing repair", "Glass work", "Frame work"];
  const app = document.querySelector("#lab-app");
  const permissionMessage = document.querySelector("#permission-message");
  const technicianCards = document.querySelector("#technician-cards");
  const technicianBoard = document.querySelector("#technician-board");
  const linesKicker = document.querySelector("#lines-kicker");
  const linesHead = document.querySelector("#technician-lines-head");
  const refreshFrameButton = document.querySelector("#refresh-frame");
  const technicianBoardTitle = document.querySelector("#technician-board-title");
  const technicianLinesTitle = document.querySelector("#technician-lines-title");
  const technicianLinesHelp = document.querySelector("#technician-lines-help");
  const technicianLinesCount = document.querySelector("#technician-lines-count");
  const technicianWorkRows = document.querySelector("#technician-work-rows");
  const boardMessage = document.querySelector("#lab-board-message");
  const addTechnicianButton = document.querySelector("#add-lab-technician");
  const removeTechnicianButton = document.querySelector("#remove-lab-technician");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let technicians = [];
  let technicianRows = [];
  let activeTechnicianId = "";
  let partOptions = [...standardParts];
  let toastTimer;

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]); }
  function normalise(value) { return String(value || "").trim().replace(/\s+/g, " ").toLowerCase(); }
  function unique(values) { const seen = new Set(); return values.map((value) => String(value || "").trim()).filter((value) => value && !seen.has(normalise(value)) && seen.add(normalise(value))); }
  function asList(value) { if (Array.isArray(value)) return value; if (!value) return []; try { return JSON.parse(value); } catch { return []; } }
  function initials(value) { return String(value || "T").trim().split(/\s+/).slice(0,2).map((part) => part[0] || "").join("").toUpperCase() || "T"; }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function setBoardMessage(text = "", success = false) { boardMessage.textContent = text; boardMessage.classList.toggle("is-visible", Boolean(text)); boardMessage.classList.toggle("is-success", success); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3500); }
  function setSubmitting(button, busy, text) { if (busy) button.dataset.label = button.textContent.trim(); button.disabled = busy; button.textContent = busy ? text : button.dataset.label || button.textContent; }

  function configureMode() {
    if (!isFrameMode) return;
    document.body.classList.add("frame-mode");
    document.title = "Frame Department | Greenloop";
    document.querySelector("#breadcrumb-stage").textContent = "Frame Department";
    document.querySelector("#page-title").textContent = "Frame Department";
    document.querySelector("#page-subtitle").textContent = "Phones selected as Pass + Frame in Final QC appear here as compact lines.";
    document.querySelector(".lab-heading .quiet-link").href = "final-qc.html";
    document.querySelector(".lab-heading .quiet-link").textContent = "← Back to Final QC";
    technicianBoard.hidden = true;
    linesKicker.textContent = "Frame queue";
    technicianLinesTitle.textContent = "Phones waiting for Frame completion";
    technicianLinesHelp.textContent = "Tick Pass and save only after Frame work is complete. Unchecked phones stay here.";
    refreshFrameButton.hidden = false;
    linesHead.innerHTML = "<th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>BH</th><th>Supplier code</th><th>Supplier grade</th><th>Initial grade</th><th>Final grade</th><th>Pass</th><th>Save</th>";
    document.querySelector("#workflow-rule-text").textContent = "A checked Frame Pass sends the phone directly to Ready Stock. An unchecked phone remains pending in Frame.";
  }

  function renderTechnicianCards() {
    technicianCards.innerHTML = technicians.length ? technicians.map((technician) => {
      const count = Number(technician.pending_count || 0);
      const active = String(technician.id) === String(activeTechnicianId);
      return `<button class="technician-card${active ? " is-active" : ""}" type="button" data-technician-id="${escapeHtml(technician.id)}" aria-pressed="${active}"><span class="technician-avatar">${escapeHtml(initials(technician.full_name))}</span><span class="technician-card-copy"><strong>${escapeHtml(technician.full_name)}</strong><span>${count} assigned IMEI${count === 1 ? "" : "s"}</span></span><span class="technician-card-count${count ? "" : " is-zero"}">${count > 99 ? "99+" : count}</span></button>`;
    }).join("") : '<p class="technician-lines-empty">No technicians are available.</p>';
    const selected = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    technicianBoardTitle.textContent = selected ? `${selected.full_name}'s assigned work` : "Select a technician";
    technicianLinesTitle.textContent = selected ? `${selected.full_name}'s phone lines` : "Assigned phone lines";
    removeTechnicianButton.disabled = !selected;
  }

  function optionsMarkup(options, placeholder) { return `<option value="">${escapeHtml(placeholder)}</option>${options.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("")}`; }
  function initialNames(items, requiredOnly = false) { return unique(asList(items).filter((item) => !requiredOnly || item.lab_decision !== "not_required").map((item) => item.name)); }
  function labPartNames(row) {
    const existing = unique(asList(row.lab_part_requests).filter((item) => item.status !== "cancelled").map((item) => item.name));
    return existing.length ? existing : initialNames(row.initial_parts).filter((name) => !asList(row.initial_parts).some((item) => normalise(item.name) === normalise(name) && item.status === "not_required"));
  }
  function labServiceNames(row) {
    const reviewed = asList(row.lab_services);
    if (reviewed.length) return unique(reviewed.filter((item) => item.required !== false).map((item) => item.name));
    return initialNames(row.initial_services, true);
  }
  function readOnlyList(values) { const list = unique(values); return list.length ? `<div class="line-list">${list.map((value) => `<span>${escapeHtml(value)}</span>`).join("")}</div>` : '<span class="line-empty">None</span>'; }
  function choiceCell(kind, options, selected) {
    return `<div class="lab-choice" data-choice="${kind}"><div class="lab-choice-row"><select>${optionsMarkup(options, kind === "part" ? "Select part" : "Select service")}</select><button type="button" data-add-choice="${kind}" title="Add">+</button></div><div class="lab-choice-tags">${unique(selected).map((value) => `<button type="button" data-remove-choice="${kind}" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`).join("")}</div></div>`;
  }
  function selectedChoices(row, kind) { return unique([...row.querySelectorAll(`[data-choice="${kind}"] [data-remove-choice]`)].map((button) => button.dataset.value)); }
  function labelledStatic(label, value, className = "") {
    return `<div class="lab-static-field ${className}"><span class="lab-field-label">${escapeHtml(label)}</span><div class="lab-static-value">${value}</div></div>`;
  }
  function repeatPartOptions(row) {
    return unique([...partOptions, ...initialNames(row.initial_parts), ...labPartNames(row)]);
  }
  function repeatReasonMarkup() {
    return `<option value="">Select repeat reason</option><option value="faulty_part">Faulty Part</option><option value="technician_damage">Damaged by Technician</option><option value="other">Other</option>`;
  }
  function lineWorkflowState(row) {
    const requests = asList(row.lab_part_requests).filter((item) => item.status !== "cancelled");
    const initialParts = asList(row.initial_parts);
    const submitted = requests.length > 0 || asList(row.lab_services).length > 0 || initialParts.some((item) => ["requested", "not_required"].includes(String(item.status)));
    const allIssued = submitted && requests.every((item) => Number(item.issued || 0) >= Number(item.quantity || 1));
    return { requests, submitted, allIssued, hasParts: requests.length > 0 };
  }
  function actionCell(row) {
    const state = lineWorkflowState(row);
    if (!state.submitted) {
      return `<button class="line-save order-parts" type="button" data-order-parts="${escapeHtml(row.step_id)}">Order Parts</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}" disabled>✓ Job Completed</button><small class="line-status" data-line-status>Order parts and save services first</small>`;
    }
    if (!state.allIssued) {
      return `<button class="line-save line-state parts-ordered" type="button" data-order-parts="${escapeHtml(row.step_id)}" disabled>Parts Ordered</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}" disabled>✓ Job Completed</button><small class="line-status" data-line-status>Waiting for Parts Department</small>`;
    }
    const issuedLabel = state.hasParts ? "✓ Parts Issued" : "✓ No Parts Required";
    return `<button class="line-save line-state parts-issued" type="button" data-order-parts="${escapeHtml(row.step_id)}" disabled>${issuedLabel}</button><button class="line-save job-completed" type="button" data-complete-lab="${escapeHtml(row.step_id)}">✓ Job Completed</button><small class="line-status success" data-line-status>Ready to send to Final QC</small>`;
  }

  function renderTechnicianLines() {
    const selectedTech = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    const filtered = technicianRows.filter((row) => isFrameMode ? String(row.department) === "frame" : ["laboratory", "glass"].includes(String(row.department)));
    technicianLinesCount.textContent = `${filtered.length} line${filtered.length === 1 ? "" : "s"}`;
    if (!activeTechnicianId) { technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">Select a technician.</td></tr>'; return; }
    if (!filtered.length) { technicianWorkRows.innerHTML = `<tr><td colspan="12" class="technician-lines-empty">${escapeHtml(selectedTech?.full_name || "This technician")} has no ${isFrameMode ? "Frame" : "Laboratory"} phones pending.</td></tr>`; return; }
    technicianWorkRows.innerHTML = filtered.map((row) => {
      const qcParts = initialNames(row.initial_parts);
      const qcServices = initialNames(row.initial_services);
      const supplier = row.supplier_code || row.supplier_name || "—";
      const saveCell = isFrameMode
        ? `<button class="line-save frame" type="button" data-complete-frame="${escapeHtml(row.step_id)}">Complete Frame</button><small class="line-status">Returns to Final QC</small>`
        : actionCell(row);
      if (isFrameMode) {
        return `<tr data-step-id="${escapeHtml(row.step_id)}"><td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong><small class="line-supplier">${escapeHtml(supplier)}</small></td><td>${escapeHtml(row.model || "—")}</td><td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td><td>${escapeHtml(row.color || "—")}</td><td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td><td>${readOnlyList(qcParts)}</td><td>${readOnlyList(qcServices)}</td><td>${readOnlyList(labPartNames(row))}</td><td>${readOnlyList(labServiceNames(row))}</td><td>—</td><td>—</td><td>${saveCell}</td></tr>`;
      }
      const staticLine = [
        labelledStatic("IMEI", `<strong class="line-imei">${escapeHtml(row.imei || "—")}</strong>`, "imei"),
        labelledStatic("Model", escapeHtml(row.model || "—")),
        labelledStatic("GB", escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)),
        labelledStatic("Color", escapeHtml(row.color || "—")),
        labelledStatic("BH", escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)),
        labelledStatic("Supplier Code", escapeHtml(supplier), "supplier"),
        labelledStatic("Initial QC Parts", readOnlyList(qcParts)),
        labelledStatic("Initial QC Service", readOnlyList(qcServices))
      ].join("");
      return `<tr class="lab-phone-row" data-step-id="${escapeHtml(row.step_id)}"><td colspan="12"><article class="lab-phone-card"><div class="lab-static-grid">${staticLine}</div><div class="lab-edit-grid"><div class="lab-edit-field"><span class="lab-field-label">Lab Parts</span>${choiceCell("part", partOptions, labPartNames(row))}</div><div class="lab-edit-field"><span class="lab-field-label">Lab Service</span>${choiceCell("service", standardServices, labServiceNames(row))}</div><div class="lab-edit-field"><span class="lab-field-label">Same Part Ordered Again</span><select class="lab-repeat-select" data-repeat-part>${optionsMarkup(repeatPartOptions(row), "Select repeated part")}</select><small>Use only for the second or later order.</small></div><div class="lab-edit-field"><span class="lab-field-label">Repeat Reason</span><select class="lab-repeat-select" data-repeat-reason disabled>${repeatReasonMarkup()}</select><small data-repeat-help>Required when the same part is ordered again.</small></div><div class="lab-line-actions">${saveCell}</div></div></article></td></tr>`;
    }).join("");
  }

  function renderFrameLines() {
    technicianLinesCount.textContent = `${technicianRows.length} waiting`;
    if (!technicianRows.length) {
      technicianWorkRows.innerHTML = '<tr><td colspan="11" class="technician-lines-empty">No phones are waiting in Frame.</td></tr>';
      return;
    }
    technicianWorkRows.innerHTML = technicianRows.map((row) => {
      const supplier = [row.supplier_code, row.supplier_name].filter(Boolean).join(" - ") || "—";
      return `<tr data-step-id="${escapeHtml(row.step_id)}">
        <td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong></td>
        <td>${escapeHtml(row.model || "—")}</td>
        <td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td>
        <td>${escapeHtml(row.color || "—")}</td>
        <td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td>
        <td class="frame-supplier">${escapeHtml(supplier)}</td>
        <td>${escapeHtml(row.supplier_grade || "—")}</td>
        <td>${escapeHtml(row.initial_grade || "—")}</td>
        <td>${escapeHtml(row.final_grade || "—")}</td>
        <td><label class="frame-pass-check"><input type="checkbox" data-frame-pass><span>Pass</span></label></td>
        <td><button class="line-save frame-ready" type="button" data-complete-frame="${escapeHtml(row.step_id)}" disabled>Save</button><small class="line-status">Stays pending until Pass</small></td>
      </tr>`;
    }).join("");
  }

  async function loadPartOptions() {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "part_name" });
    if (!error && data?.length) partOptions = unique([...standardParts, ...data.map((item) => item.option_value)]);
  }
  async function loadTechnicianRows() {
    setBoardMessage();
    if (!activeTechnicianId) { technicianRows = []; renderTechnicianLines(); return; }
    const { data, error } = await getClient().rpc("get_lab_technician_rows", { p_technician_id: activeTechnicianId });
    if (error) throw error;
    technicianRows = data || [];
    renderTechnicianLines();
  }
  async function loadFrameRows() {
    setBoardMessage();
    const { data, error } = await getClient().rpc("get_frame_department_rows");
    if (error) throw error;
    technicianRows = data || [];
    renderFrameLines();
  }
  async function loadTechnicians(preferredId = activeTechnicianId) {
    const { data, error } = await getClient().rpc("get_lab_technician_workboard_by_stage", { p_stage: isFrameMode ? "frame" : "laboratory" });
    if (error) throw error;
    technicians = data || [];
    activeTechnicianId = technicians.some((item) => String(item.id) === String(preferredId)) ? String(preferredId) : String(technicians.find((item) => Number(item.pending_count || 0) > 0)?.id || technicians[0]?.id || "");
    renderTechnicianCards();
  }
  async function refreshAll() {
    if (isFrameMode) { await loadFrameRows(); return; }
    await loadTechnicians(activeTechnicianId);
    await loadTechnicianRows();
  }

  async function addTechnician() {
    const fullName = window.prompt("Enter the technician name:");
    if (!fullName?.trim()) return;
    setSubmitting(addTechnicianButton, true, "Adding...");
    const { data, error } = await getClient().rpc("add_lab_technician", { p_full_name: fullName.trim() });
    setSubmitting(addTechnicianButton, false);
    if (error) throw error;
    const saved = data?.[0] || data;
    activeTechnicianId = String(saved?.id || "");
    await refreshAll();
    showToast("Technician added.");
  }
  async function removeTechnician() {
    const technician = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    if (!technician) return;
    if (Number(technician.pending_count || 0) > 0) throw new Error("Complete or move this technician's pending IMEIs first.");
    if (window.prompt(`Enter deletion code to remove ${technician.full_name}:`) !== "1213") return;
    const { error } = await getClient().rpc("remove_lab_technician", { p_technician_id: technician.id, p_deletion_code: "1213" });
    if (error) throw error;
    activeTechnicianId = "";
    await refreshAll();
  }

  function addChoice(button) {
    const holder = button.closest("[data-choice]");
    const select = holder.querySelector("select");
    const value = select.value;
    if (!value || selectedChoices(button.closest("tr"), holder.dataset.choice).some((item) => normalise(item) === normalise(value))) return;
    holder.querySelector(".lab-choice-tags").insertAdjacentHTML("beforeend", `<button type="button" data-remove-choice="${holder.dataset.choice}" data-value="${escapeHtml(value)}" title="Remove">${escapeHtml(value)}</button>`);
    select.value = "";
    markLineChanged(button.closest("tr"));
  }
  function markLineChanged(row) {
    const orderButton = row.querySelector("[data-order-parts]");
    const completeButton = row.querySelector("[data-complete-lab]");
    const status = row.querySelector("[data-line-status]");
    if (!orderButton) return;
    row.dataset.dirty = "true";
    orderButton.disabled = false;
    orderButton.textContent = "Order Updated Parts";
    orderButton.className = "line-save order-parts";
    if (completeButton) completeButton.disabled = true;
    if (status) {
      status.textContent = "Submit the updated order before completing the job";
      status.className = "line-status";
    }
  }
  async function orderParts(button) {
    const row = button.closest("tr");
    const status = row.querySelector("[data-line-status]");
    const repeatPart = row.querySelector("[data-repeat-part]")?.value || "";
    const repeatReason = row.querySelector("[data-repeat-reason]")?.value || "";
    if (repeatPart && !repeatReason) {
      status.textContent = "Select why the same part is being ordered again.";
      status.className = "line-status error";
      row.querySelector("[data-repeat-reason]").focus();
      return;
    }
    setSubmitting(button, true, "Ordering...");
    const { data, error } = await getClient().rpc("save_lab_technician_line_v2", {
      p_work_order_step_id: row.dataset.stepId,
      p_lab_parts: selectedChoices(row, "part"),
      p_lab_services: selectedChoices(row, "service"),
      p_extra_parts: [],
      p_extra_services: [],
      p_repeat_part: repeatPart || null,
      p_repeat_reason: repeatReason || null
    });
    setSubmitting(button, false);
    if (error) { status.textContent = error.message; status.className = "line-status error"; return; }
    const notifications = Number(data?.parts_notified || 0) + (data?.repeat_part_requested ? 1 : 0);
    status.textContent = data?.repeat_part_requested ? `${notifications} part notification(s); repeat order #${Number(data.repeat_number || 2)}` : `${notifications} part notification(s)`;
    status.className = "line-status success";
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    showToast("Parts order submitted. Services were saved without a Parts notification.");
    await refreshAll();
  }
  async function completeLab(button) {
    setSubmitting(button, true, "Completing...");
    const { error } = await getClient().rpc("complete_lab_technician_line", { p_work_order_step_id: button.dataset.completeLab });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast("Job completed. Phone sent to Final QC.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }
  async function completeFrame(button) {
    const row = button.closest("tr");
    if (!row.querySelector("[data-frame-pass]")?.checked) return;
    setSubmitting(button, true, "Saving...");
    const { error } = await getClient().rpc("complete_frame_to_ready_stock", { p_work_order_step_id: button.dataset.completeFrame, p_notes: "Frame work passed" });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast("Frame passed. Phone sent directly to Ready Stock.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }

  async function initialize() {
    configureMode();
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "technician"] });
    if (error) throw error;
    if (!allowed) { permissionMessage.textContent = "Your account does not have Laboratory permission."; permissionMessage.hidden = false; return; }
    app.hidden = false;
    if (!isFrameMode) await loadPartOptions();
    await refreshAll();
    if (!isFrameMode) {
      window.setInterval(() => {
        if (document.visibilityState !== "visible" || app.hidden || technicianWorkRows.querySelector('tr[data-dirty="true"]')) return;
        loadTechnicianRows().catch(() => {});
      }, 12000);
    }
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-lab").addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  refreshFrameButton.addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  addTechnicianButton.addEventListener("click", () => addTechnician().catch((error) => setBoardMessage(error.message)));
  removeTechnicianButton.addEventListener("click", () => removeTechnician().catch((error) => setBoardMessage(error.message)));
  technicianCards.addEventListener("click", (event) => { const card = event.target.closest("[data-technician-id]"); if (!card) return; activeTechnicianId = card.dataset.technicianId; renderTechnicianCards(); loadTechnicianRows().catch((error) => setBoardMessage(error.message)); });
  technicianWorkRows.addEventListener("click", (event) => {
    const add = event.target.closest("[data-add-choice]"); if (add) { addChoice(add); return; }
    const remove = event.target.closest("[data-remove-choice]"); if (remove) { const row = remove.closest("tr"); remove.remove(); markLineChanged(row); return; }
    const order = event.target.closest("[data-order-parts]"); if (order && !order.disabled) orderParts(order).catch((error) => setBoardMessage(error.message));
    const completeLabButton = event.target.closest("[data-complete-lab]"); if (completeLabButton) completeLab(completeLabButton).catch((error) => setBoardMessage(error.message));
    const completeFrameButton = event.target.closest("[data-complete-frame]"); if (completeFrameButton) completeFrame(completeFrameButton).catch((error) => setBoardMessage(error.message));
  });
  technicianWorkRows.addEventListener("change", (event) => {
    const repeatPart = event.target.closest("[data-repeat-part]");
    if (repeatPart) {
      const reason = repeatPart.closest("tr").querySelector("[data-repeat-reason]");
      reason.disabled = !repeatPart.value;
      if (!repeatPart.value) reason.value = "";
      markLineChanged(repeatPart.closest("tr"));
      return;
    }
    const repeatReason = event.target.closest("[data-repeat-reason]");
    if (repeatReason) { markLineChanged(repeatReason.closest("tr")); return; }
    const checkbox = event.target.closest("[data-frame-pass]");
    if (!checkbox) return;
    const button = checkbox.closest("tr").querySelector("[data-complete-frame]");
    button.disabled = !checkbox.checked;
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
