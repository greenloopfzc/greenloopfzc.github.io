(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const isFrameMode = window.location.hash.toLowerCase() === "#frame";
  const standardParts = ["Case", "Glass", "Touch panel", "NFC flex", "Vibrator", "Speaker", "Camera", "Face ID flex", "LCD display", "Battery", "Charging flex"];
  const standardServices = ["Polish", "Cleaning", "Software", "Testing", "Face ID calibration", "Camera calibration", "Housing repair", "Glass work", "Frame work"];
  const app = document.querySelector("#lab-app");
  const permissionMessage = document.querySelector("#permission-message");
  const technicianCards = document.querySelector("#technician-cards");
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
    document.title = "Frame Department | Greenloop";
    document.querySelector("#breadcrumb-stage").textContent = "Frame Department";
    document.querySelector("#page-title").textContent = "Frame technician workbench";
    document.querySelector("#page-subtitle").textContent = "Phones sent by Final QC appear here and return to Final QC after Frame completion.";
    technicianLinesHelp.textContent = "Complete each Frame line to return that IMEI to Final QC.";
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

  function renderTechnicianLines() {
    const selectedTech = technicians.find((item) => String(item.id) === String(activeTechnicianId));
    const filtered = technicianRows.filter((row) => isFrameMode ? String(row.department) === "frame" : ["laboratory", "glass"].includes(String(row.department)));
    technicianLinesCount.textContent = `${filtered.length} line${filtered.length === 1 ? "" : "s"}`;
    if (!activeTechnicianId) { technicianWorkRows.innerHTML = '<tr><td colspan="12" class="technician-lines-empty">Select a technician.</td></tr>'; return; }
    if (!filtered.length) { technicianWorkRows.innerHTML = `<tr><td colspan="12" class="technician-lines-empty">${escapeHtml(selectedTech?.full_name || "This technician")} has no ${isFrameMode ? "Frame" : "Laboratory"} phones pending.</td></tr>`; return; }
    technicianWorkRows.innerHTML = filtered.map((row) => {
      const qcParts = initialNames(row.initial_parts);
      const qcServices = initialNames(row.initial_services);
      const supplier = [row.supplier_code, row.supplier_name].filter(Boolean).join(" - ");
      const saveCell = isFrameMode
        ? `<button class="line-save frame" type="button" data-complete-frame="${escapeHtml(row.step_id)}">Complete Frame</button><small class="line-status">Returns to Final QC</small>`
        : `<button class="line-save" type="button" data-save-line="${escapeHtml(row.step_id)}">Save</button><button class="line-save complete" type="button" data-complete-lab="${escapeHtml(row.step_id)}">Complete → QC</button><small class="line-status" data-line-status>Not saved</small>`;
      return `<tr data-step-id="${escapeHtml(row.step_id)}"><td><strong class="line-imei">${escapeHtml(row.imei || "—")}</strong><small class="line-supplier">${escapeHtml(supplier || "Supplier not recorded")}</small></td><td>${escapeHtml(row.model || "—")}</td><td>${escapeHtml(row.storage_gb == null ? "—" : `${row.storage_gb} GB`)}</td><td>${escapeHtml(row.color || "—")}</td><td>${escapeHtml(row.battery_health == null ? "—" : `${row.battery_health}%`)}</td><td>${readOnlyList(qcParts)}</td><td>${readOnlyList(qcServices)}</td><td>${isFrameMode ? readOnlyList(labPartNames(row)) : choiceCell("part", partOptions, labPartNames(row))}</td><td>${isFrameMode ? readOnlyList(labServiceNames(row)) : choiceCell("service", standardServices, labServiceNames(row))}</td><td>${isFrameMode ? "—" : '<input class="lab-extra-input" data-extra-parts placeholder="Part(s), comma separated">'}</td><td>${isFrameMode ? "—" : '<input class="lab-extra-input" data-extra-services placeholder="Service(s), comma separated">'}</td><td>${saveCell}</td></tr>`;
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
  async function loadTechnicians(preferredId = activeTechnicianId) {
    const { data, error } = await getClient().rpc("get_lab_technician_workboard_by_stage", { p_stage: isFrameMode ? "frame" : "laboratory" });
    if (error) throw error;
    technicians = data || [];
    activeTechnicianId = technicians.some((item) => String(item.id) === String(preferredId)) ? String(preferredId) : String(technicians.find((item) => Number(item.pending_count || 0) > 0)?.id || technicians[0]?.id || "");
    renderTechnicianCards();
  }
  async function refreshAll() { await loadTechnicians(activeTechnicianId); await loadTechnicianRows(); }

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
  }
  async function saveLine(button) {
    const row = button.closest("tr");
    const status = row.querySelector("[data-line-status]");
    const split = (value) => unique(String(value || "").split(","));
    setSubmitting(button, true, "Saving...");
    const { data, error } = await getClient().rpc("save_lab_technician_line", {
      p_work_order_step_id: row.dataset.stepId,
      p_lab_parts: selectedChoices(row, "part"),
      p_lab_services: selectedChoices(row, "service"),
      p_extra_parts: split(row.querySelector("[data-extra-parts]").value),
      p_extra_services: split(row.querySelector("[data-extra-services]").value)
    });
    setSubmitting(button, false);
    if (error) { status.textContent = error.message; status.className = "line-status error"; return; }
    status.textContent = `${Number(data?.parts_notified || 0)} part notification(s)`;
    status.className = "line-status success";
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    showToast("Lab line saved. Only parts were sent to Parts.");
    await refreshAll();
  }
  async function completeLab(button) {
    setSubmitting(button, true, "Checking...");
    const { error } = await getClient().rpc("complete_lab_technician_line", { p_work_order_step_id: button.dataset.completeLab });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast("Laboratory completed. Phone sent to Final QC.");
    document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    await refreshAll();
  }
  async function completeFrame(button) {
    setSubmitting(button, true, "Saving...");
    const { error } = await getClient().rpc("complete_frame_and_return_to_final_qc", { p_work_order_step_id: button.dataset.completeFrame, p_notes: "Frame work completed" });
    setSubmitting(button, false);
    if (error) { setBoardMessage(error.message); return; }
    showToast("Frame completed. Phone returned to Final QC.");
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
    await loadPartOptions();
    await refreshAll();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-lab").addEventListener("click", () => refreshAll().catch((error) => setBoardMessage(error.message)));
  addTechnicianButton.addEventListener("click", () => addTechnician().catch((error) => setBoardMessage(error.message)));
  removeTechnicianButton.addEventListener("click", () => removeTechnician().catch((error) => setBoardMessage(error.message)));
  technicianCards.addEventListener("click", (event) => { const card = event.target.closest("[data-technician-id]"); if (!card) return; activeTechnicianId = card.dataset.technicianId; renderTechnicianCards(); loadTechnicianRows().catch((error) => setBoardMessage(error.message)); });
  technicianWorkRows.addEventListener("click", (event) => {
    const add = event.target.closest("[data-add-choice]"); if (add) { addChoice(add); return; }
    const remove = event.target.closest("[data-remove-choice]"); if (remove) { remove.remove(); return; }
    const save = event.target.closest("[data-save-line]"); if (save) saveLine(save).catch((error) => setBoardMessage(error.message));
    const completeLabButton = event.target.closest("[data-complete-lab]"); if (completeLabButton) completeLab(completeLabButton).catch((error) => setBoardMessage(error.message));
    const completeFrameButton = event.target.closest("[data-complete-frame]"); if (completeFrameButton) completeFrame(completeFrameButton).catch((error) => setBoardMessage(error.message));
  });
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
