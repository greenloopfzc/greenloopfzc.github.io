(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const serviceItems = [
    { label: "Case", partName: "Case", action: "Replace case" },
    { label: "Glass", partName: "Glass", action: "Replace glass" },
    { label: "Polish", partName: null, action: "Polish device" },
    { label: "TP", partName: "Touch panel", action: "Replace touch panel" },
    { label: "NFC", partName: "NFC flex", action: "Replace or repair NFC" },
    { label: "Vibrator", partName: "Vibrator", action: "Replace vibrator" },
    { label: "Speaker", partName: "Speaker", action: "Replace speaker" },
    { label: "Camera", partName: "Camera", action: "Replace or repair camera" },
    { label: "Face ID", partName: "Face ID flex", action: "Repair Face ID" },
    { label: "LCD", partName: "LCD display", action: "Replace LCD display" }
  ];

  const app = document.querySelector("#qc-app");
  const permissionMessage = document.querySelector("#permission-message");
  const imeiInput = document.querySelector("#qc-imei");
  const pendingImeiSelect = document.querySelector("#qc-pending-imei");
  const scanMessage = document.querySelector("#qc-scan-message");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#qc-empty");
  const workspace = document.querySelector("#qc-workspace");
  const autoValues = document.querySelector("#qc-auto-values");
  const inspectionLines = document.querySelector("#qc-inspection-lines");
  const form = document.querySelector("#qc-form");
  const message = document.querySelector("#qc-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let selectedJob;
  let technicians = [];
  let lineSequence = 0;
  let scanTimer;
  let toastTimer;

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function supplierLabel(code, name) { return [code, name].filter((value) => String(value || "").trim()).join(" - ") || "—"; }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function setMessage(text = "", success = false) { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); message.classList.toggle("is-success", success); }
  function setScanMessage(text = "", success = false) { scanMessage.textContent = text; scanMessage.classList.toggle("is-visible", Boolean(text)); scanMessage.classList.toggle("is-success", success); }
  function showToast(text) { window.clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3600); }
  function setSubmitting(button, isSubmitting, label) { if (isSubmitting) button.dataset.originalLabel = button.textContent.trim(); button.disabled = isSubmitting; button.textContent = isSubmitting ? label : button.dataset.originalLabel || button.textContent.trim(); }
  function nextLineId() { lineSequence += 1; return `qc-line-${lineSequence}`; }

  function gradeOptions(selectedValue = "", includeUnsorted = false) {
    const grades = includeUnsorted
      ? [["", "Select grade"], ["A+", "A+"], ["A", "A"], ["B", "B"], ["C", "C"], ["UNSORTED", "Unsorted"]]
      : [["", "Select grade"], ["A+", "A+"], ["A", "A"], ["B", "B"], ["C", "C"]];
    return grades.map(([value, label]) => `<option value="${value}"${selectedValue === value ? " selected" : ""}>${label}</option>`).join("");
  }

  function technicianOptions(selectedValue = "") {
    return ["<option value=\"\">Select technician</option>", ...technicians.map((technician) => `<option value="${escapeHtml(technician.id)}"${selectedValue === technician.id ? " selected" : ""}>${escapeHtml(technician.full_name || technician.email || "Technician")}</option>`)].join("");
  }

  function requirementOptions(selectedValue = "") {
    return ["<option value=\"\">Select part or service</option>", ...serviceItems.map((item) => `<option value="${escapeHtml(item.label)}"${selectedValue === item.label ? " selected" : ""}>${escapeHtml(item.label)}</option>`)].join("");
  }

  function requirementMenu(selectedValue = "") {
    return `<div class="qc-requirement-menu"><select data-requirement>${requirementOptions(selectedValue)}</select><button class="qc-requirement-add" type="button" title="Add part or service" aria-label="Add part or service">+</button><button class="qc-requirement-remove" type="button" title="Remove part or service" aria-label="Remove part or service">−</button></div>`;
  }

  function createLine(values = {}) {
    return {
      id: values.id || nextLineId(),
      supplierGrade: values.supplierGrade || "",
      gcGrade: values.gcGrade || "",
      requirements: values.requirements?.length ? values.requirements : [""],
      technicianId: values.technicianId || ""
    };
  }

  function lineMarkup(line, index) {
    return `<tr class="qc-inspection-line" data-line-id="${escapeHtml(line.id)}">
      <td class="qc-line-name"><strong>Initial QC ${index + 1}</strong><small>${index ? "Additional inspection" : "Primary inspection"}</small></td>
      <td class="qc-grade-cell"><select data-supplier-grade class="qc-grade-select">${gradeOptions(line.supplierGrade, true)}</select></td>
      <td class="qc-grade-cell"><select data-gc-grade class="qc-grade-select">${gradeOptions(line.gcGrade)}</select></td>
      <td class="qc-requirements-cell"><div class="qc-requirement-menus">${line.requirements.map((value) => requirementMenu(value)).join("")}</div></td>
      <td class="qc-technician-cell"><div class="qc-technician-control"><select data-technician-select>${technicianOptions(line.technicianId)}</select><button class="qc-technician-add" type="button" title="Add technician" aria-label="Add technician">+</button><button class="qc-technician-remove" type="button" title="Remove selected technician" aria-label="Remove selected technician">−</button></div></td>
      <td class="qc-line-remove-cell"><button class="qc-line-remove" type="button" title="Remove this Initial QC line" aria-label="Remove this Initial QC line">−</button></td>
    </tr>`;
  }

  function currentLines() {
    return [...inspectionLines.querySelectorAll(".qc-inspection-line")].map((row) => ({
      id: row.dataset.lineId || nextLineId(),
      supplierGrade: row.querySelector("[data-supplier-grade]")?.value || "",
      gcGrade: row.querySelector("[data-gc-grade]")?.value || "",
      requirements: [...row.querySelectorAll("[data-requirement]")].map((select) => select.value),
      technicianId: row.querySelector("[data-technician-select]")?.value || ""
    }));
  }

  function renderInspectionLines(lines) {
    inspectionLines.innerHTML = lines.map(lineMarkup).join("");
  }

  function resetSheet() {
    form.reset();
    autoValues.innerHTML = '<tr><td colspan="6" class="qc-sheet-placeholder">Scan an IMEI to load this QC sheet.</td></tr>';
    inspectionLines.innerHTML = '<tr><td colspan="6" class="qc-sheet-placeholder">Initial QC lines appear after an IMEI is loaded.</td></tr>';
    setMessage();
  }

  function clearInspection() {
    if (!selectedJob) return;
    const device = selectedJob.device || {};
    renderInspectionLines([createLine({ supplierGrade: selectedJob.supplier_grade || "", gcGrade: device.gc_grade || "" })]);
    document.querySelector("#qc-notes").value = "";
    setMessage();
  }

  function renderSheet(data) {
    selectedJob = { ...(data?.job || {}), supplier_display: supplierLabel(data?.job?.supplier_code, data?.supplier), device: data?.device || {} };
    const device = selectedJob.device;
    workspace.hidden = false;
    emptyState.hidden = true;

    const values = [
      device.imei_1,
      selectedJob.supplier_display,
      device.model,
      device.storage_gb ? `${device.storage_gb} GB` : "—",
      device.color,
      device.battery_health !== null && device.battery_health !== undefined ? `${device.battery_health}%` : "—"
    ];
    autoValues.innerHTML = `<tr>${values.map((value) => `<td class="qc-auto-value">${escapeHtml(value || "—")}</td>`).join("")}</tr>`;
    renderInspectionLines([createLine({ supplierGrade: String(selectedJob.supplier_grade || "").toUpperCase(), gcGrade: String(device.gc_grade || "").toUpperCase() })]);
    if ([...pendingImeiSelect.options].some((option) => option.value === device.imei_1)) pendingImeiSelect.value = device.imei_1;
    document.querySelector("#qc-notes").value = "";
    setScanMessage("Stock Received information loaded. Complete Initial QC 1, then add another line only if needed.", true);
  }

  async function scanIdentifier() {
    const identifier = imeiInput.value.trim();
    if (!/^\d{15}$/.test(identifier)) return;
    setScanMessage("Loading Stock Received information...", true);
    const { data, error } = await getClient().rpc("get_initial_qc_job_by_identifier", { p_identifier: identifier });
    if (error) throw error;
    const result = Array.isArray(data) ? data[0] : data;
    if (!result?.found) {
      selectedJob = null;
      workspace.hidden = true;
      emptyState.hidden = false;
      setScanMessage("No device waiting for Initial QC was found for this IMEI.");
      return;
    }
    sessionStorage.removeItem("greenloop-next-initial-qc-imei");
    renderSheet(result);
  }

  async function loadTechnicians() {
    const { data, error } = await getClient().rpc("get_assignable_technicians");
    if (error) throw error;
    technicians = data || [];
  }

  function refreshTechnicianSelects(preferredRow, preferredValue) {
    document.querySelectorAll("[data-technician-select]").forEach((select) => {
      const currentValue = select.value;
      select.innerHTML = technicianOptions(select.closest(".qc-inspection-line") === preferredRow ? preferredValue : currentValue);
    });
  }

  async function addTechnician(row) {
    const fullName = window.prompt("Enter the new technician name:");
    if (!fullName?.trim()) return;
    const { data, error } = await getClient().rpc("add_technician_roster", { p_full_name: fullName.trim() });
    if (error) throw error;
    await loadTechnicians();
    const created = Array.isArray(data) ? data[0] : data;
    refreshTechnicianSelects(row, created?.id || "");
    showToast("Technician saved.");
  }

  async function removeTechnician(row) {
    const select = row.querySelector("[data-technician-select]");
    if (!select?.value) { setMessage("Select a technician before removing it."); return; }
    const code = window.prompt("Enter deletion code to remove this technician:");
    if (code !== "1213") { showToast("Technician was not removed. Deletion code is incorrect."); return; }
    const { error } = await getClient().rpc("delete_technician_roster", { p_technician_id: select.value, p_deletion_code: code });
    if (error) throw error;
    await loadTechnicians();
    refreshTechnicianSelects();
    showToast("Technician removed.");
  }

  async function loadPendingImeis() {
    const selectedImei = pendingImeiSelect.value;
    const { data, error } = await getClient()
      .from("jobs")
      .select("job_number, supplier:suppliers(supplier_code, company_name), device:devices!inner(imei_1, model, storage_gb, color)")
      .eq("current_status", "initial_qc_pending")
      .is("deleted_at", null)
      .order("received_at", { ascending: true });
    if (error) throw error;

    const pendingJobs = data || [];
    pendingImeiSelect.replaceChildren(new Option(pendingJobs.length ? "Select a pending IMEI" : "No IMEIs waiting for QC", ""));
    pendingJobs.forEach((job) => {
      const device = Array.isArray(job.device) ? job.device[0] : job.device;
      const supplier = Array.isArray(job.supplier) ? job.supplier[0] : job.supplier;
      if (!device?.imei_1) return;
      const details = [supplierLabel(supplier?.supplier_code, supplier?.company_name), device.model, device.storage_gb ? `${device.storage_gb} GB` : "", device.color].filter(Boolean).join(" · ");
      pendingImeiSelect.add(new Option(`${device.imei_1} · ${details || job.job_number}`, device.imei_1));
    });
    queueCount.textContent = `${pendingJobs.length} waiting`;
    if ([...pendingImeiSelect.options].some((option) => option.value === selectedImei)) pendingImeiSelect.value = selectedImei;
  }

  function buildSubmission() {
    const lines = currentLines();
    const selections = [];
    const technicianIds = new Set();
    lines.forEach((line, index) => {
      if (line.technicianId) technicianIds.add(line.technicianId);
      line.requirements.filter(Boolean).forEach((label) => selections.push({ label, lineLabel: `Initial QC ${index + 1}` }));
    });

    const duplicate = selections.find((selection, index) => selections.findIndex((item) => item.label === selection.label) !== index);
    if (duplicate) throw new Error(`${duplicate.label} is selected more than once. Select each part or service on one Initial QC line only.`);
    if (technicianIds.size > 1) throw new Error("A device can be assigned to one Laboratory technician. Use the same technician on all Initial QC lines.");
    if (selections.length > 0 && technicianIds.size === 0) throw new Error("Select the Laboratory technician because an issue, part, or service was identified.");

    const findings = selections.map((selection) => {
      const item = serviceItems.find((service) => service.label === selection.label);
      return { check_item: item.label, action_required: item.action, priority: "normal", notes: selection.lineLabel };
    });
    const parts = selections.map((selection) => {
      const item = serviceItems.find((service) => service.label === selection.label);
      return item.partName ? { part_name: item.partName, quantity: 1, notes: `${selection.lineLabel}: ${item.label}` } : null;
    }).filter(Boolean);
    const supplierGrade = [...lines].reverse().find((line) => line.supplierGrade)?.supplierGrade || null;
    const gcGrade = [...lines].reverse().find((line) => line.gcGrade)?.gcGrade || null;
    const lineSummary = lines.map((line, index) => {
      const requirements = line.requirements.filter(Boolean).join(", ") || "No parts or services";
      const technician = technicians.find((person) => person.id === line.technicianId)?.full_name || "No technician";
      return `Initial QC ${index + 1}: ${requirements}; ${technician}.`;
    }).join(" ");
    const notes = [document.querySelector("#qc-notes").value.trim(), lineSummary].filter(Boolean).join("\n\n");
    return { findings, parts, technicianId: [...technicianIds][0] || null, supplierGrade, gcGrade, notes };
  }

  async function submitInitialQc(event) {
    event.preventDefault();
    setMessage();
    if (!selectedJob) { setMessage("Scan an IMEI that is waiting for Initial QC first."); return; }
    let submission;
    try { submission = buildSubmission(); } catch (error) { setMessage(error.message); return; }

    const button = document.querySelector("#complete-qc");
    setSubmitting(button, true, "Saving QC...");
    const hasWork = submission.findings.length > 0 || submission.parts.length > 0;
    const rpcName = hasWork ? "complete_initial_qc_lab_first" : "complete_scanned_initial_qc_with_roster_and_grades";
    const { data, error } = await getClient().rpc(rpcName, {
      p_job_id: selectedJob.id,
      p_overall_condition: "",
      p_cosmetic_condition: "",
      p_notes: submission.notes,
      p_findings: submission.findings,
      p_part_requests: submission.parts,
      p_assigned_technician_roster_id: submission.technicianId,
      p_supplier_grade: submission.supplierGrade,
      p_gc_grade: submission.gcGrade
    });
    setSubmitting(button, false);
    if (error) { setMessage(error.message || "Initial QC could not be completed."); return; }

    const result = data?.[0];
    const identifiedCount = Number(result?.parts_requested || 0);
    const successText = !hasWork
      ? "Initial QC passed with no issues. Mobile sent directly to Final QC."
      : identifiedCount
      ? `Initial QC saved. Mobile sent to Laboratory with ${identifiedCount} identified part(s). Parts will be notified only after Laboratory requests them.`
      : "Initial QC saved. Mobile sent to Laboratory for technician review.";
    showToast(successText);
    setScanMessage(successText, true);
    selectedJob = null;
    workspace.hidden = true;
    emptyState.hidden = false;
    imeiInput.value = "";
    resetSheet();
    await loadPendingImeis();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canInspect, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "initial_qc"] });
    if (error) throw error;
    if (!canInspect) throw new Error("Your account does not have Initial QC permission.");
    await Promise.all([loadTechnicians(), loadPendingImeis()]);
    app.hidden = false;
    if (!selectedJob) imeiInput.focus();
  }

  imeiInput.addEventListener("input", () => {
    window.clearTimeout(scanTimer);
    if (/^\d{15}$/.test(imeiInput.value.trim())) scanTimer = window.setTimeout(() => scanIdentifier().catch((error) => setScanMessage(error.message || "The IMEI could not be read.")), 280);
  });
  imeiInput.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); scanIdentifier().catch((error) => setScanMessage(error.message || "The IMEI could not be read.")); } });
  pendingImeiSelect.addEventListener("change", () => { if (!pendingImeiSelect.value) return; imeiInput.value = pendingImeiSelect.value; scanIdentifier().catch((error) => setScanMessage(error.message || "The selected IMEI could not be loaded.")); });
  document.querySelector("#clear-qc").addEventListener("click", clearInspection);
  document.querySelector("#add-qc-line").addEventListener("click", () => { if (!selectedJob) return; const lines = currentLines(); lines.push(createLine()); renderInspectionLines(lines); inspectionLines.lastElementChild?.querySelector("[data-requirement]")?.focus(); });
  workspace.addEventListener("click", (event) => {
    const row = event.target.closest(".qc-inspection-line");
    if (!row) return;
    if (event.target.closest(".qc-technician-add")) { addTechnician(row).catch((error) => setMessage(error.message || "Technician could not be added.")); return; }
    if (event.target.closest(".qc-technician-remove")) { removeTechnician(row).catch((error) => setMessage(error.message || "Technician could not be removed.")); return; }
    if (event.target.closest(".qc-line-remove")) {
      const lines = currentLines();
      if (lines.length === 1) { setMessage("Initial QC 1 must remain on the sheet."); return; }
      if (window.prompt("Enter deletion code to remove this Initial QC line:") !== "1213") { showToast("Initial QC line was not removed. Deletion code is incorrect."); return; }
      renderInspectionLines(lines.filter((line) => line.id !== row.dataset.lineId));
      return;
    }
    const menus = row.querySelector(".qc-requirement-menus");
    if (event.target.closest(".qc-requirement-add")) { menus.insertAdjacentHTML("beforeend", requirementMenu()); return; }
    const removeRequirement = event.target.closest(".qc-requirement-remove");
    if (removeRequirement) {
      if (menus.querySelectorAll(".qc-requirement-menu").length === 1) {
        const select = removeRequirement.closest(".qc-requirement-menu").querySelector("select");
        if (!select.value) return;
        if (window.prompt("Enter deletion code to clear this part or service:") !== "1213") { showToast("Part or service was not cleared. Deletion code is incorrect."); return; }
        select.value = "";
        return;
      }
      if (window.prompt("Enter deletion code to remove this part or service:") !== "1213") { showToast("Part or service was not removed. Deletion code is incorrect."); return; }
      removeRequirement.closest(".qc-requirement-menu")?.remove();
    }
  });
  form.addEventListener("submit", submitInitialQc);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Initial QC could not be loaded."; permissionMessage.hidden = false; });
})();
