(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const workItems = [
    { label: "Case", kind: "part", partName: "Case", action: "Replace case" },
    { label: "Glass", kind: "part", partName: "Glass", action: "Replace glass" },
    { label: "TP", kind: "part", partName: "Touch panel", action: "Replace touch panel" },
    { label: "NFC", kind: "part", partName: "NFC flex", action: "Replace or repair NFC" },
    { label: "Vibrator", kind: "part", partName: "Vibrator", action: "Replace vibrator" },
    { label: "Speaker", kind: "part", partName: "Speaker", action: "Replace speaker" },
    { label: "Camera", kind: "part", partName: "Camera", action: "Replace or repair camera" },
    { label: "Face ID", kind: "part", partName: "Face ID flex", action: "Repair Face ID" },
    { label: "LCD", kind: "part", partName: "LCD display", action: "Replace LCD display" },
    { label: "Polish", kind: "service", partName: null, action: "Polish device" },
    { label: "Cleaning", kind: "service", partName: null, action: "Clean device" },
    { label: "Software", kind: "service", partName: null, action: "Complete software service" },
    { label: "Testing", kind: "service", partName: null, action: "Complete technical testing" }
  ];

  const app = document.querySelector("#qc-app");
  const permissionMessage = document.querySelector("#permission-message");
  const queueCount = document.querySelector("#queue-count");
  const trayCount = document.querySelector("#tray-count");
  const tableBody = document.querySelector("#qc-bulk-body");
  const form = document.querySelector("#qc-form");
  const message = document.querySelector("#qc-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const rowJobs = new Map();
  const rowTimers = new WeakMap();
  let client;
  let technicians = [];
  let rowSequence = 0;
  let toastTimer;

  function getClient() {
    return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function supplierLabel(code, name) {
    return [code, name].filter((value) => String(value || "").trim()).join(" - ") || "-";
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function setMessage(text = "", success = false) {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
    message.classList.toggle("is-success", success);
  }

  function showToast(text) {
    window.clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3800);
  }

  function setSubmitting(button, isSubmitting, label) {
    if (isSubmitting) button.dataset.originalLabel = button.textContent.trim();
    button.disabled = isSubmitting;
    button.textContent = isSubmitting ? label : button.dataset.originalLabel || button.textContent.trim();
  }

  function gradeOptions(includeUnsorted = false) {
    const grades = includeUnsorted ? ["A+", "A", "B", "C", "UNSORTED"] : ["A+", "A", "B", "C"];
    return `<option value="">Select grade</option>${grades.map((grade) => `<option value="${grade}">${grade === "UNSORTED" ? "Unsorted" : grade}</option>`).join("")}`;
  }

  function technicianOptions(selectedValue = "") {
    return `<option value="">Select technician</option>${technicians.map((technician) => `<option value="${escapeHtml(technician.id)}"${String(selectedValue) === String(technician.id) ? " selected" : ""}>${escapeHtml(technician.full_name || technician.email || "Technician")}</option>`).join("")}`;
  }

  function requirementOptions(kind, selectedValue = "") {
    const items = workItems.filter((item) => item.kind === kind);
    const placeholder = kind === "part" ? "Select part" : "Select service";
    return `<option value="">${placeholder}</option>${items.map((item) => `<option value="${escapeHtml(item.label)}"${selectedValue === item.label ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}`;
  }

  function requirementSelect(kind, selectedValue = "") {
    return `<select data-requirement="${kind}">${requirementOptions(kind, selectedValue)}</select>`;
  }

  function requirementGroup(kind, values = []) {
    const selectedValues = values.length ? values : [""];
    return `<div class="qc-bulk-requirement-group" data-requirement-group="${kind}"><div class="qc-bulk-requirement-list">${selectedValues.map((value) => requirementSelect(kind, value)).join("")}</div><button type="button" data-add-requirement="${kind}" title="Add another ${kind}">+</button><button type="button" class="remove" data-remove-requirement="${kind}" title="Remove ${kind}">−</button></div>`;
  }

  function rowMarkup() {
    rowSequence += 1;
    const rowId = `initial-qc-row-${rowSequence}`;
    return `<tr data-row-id="${rowId}">
      <td class="qc-bulk-imei-cell"><input class="qc-bulk-imei" inputmode="numeric" autocomplete="off" maxlength="15" placeholder="Scan IMEI"><small data-row-state>Line ${rowSequence} · Waiting</small></td>
      <td class="qc-bulk-auto" data-auto="model">-</td>
      <td class="qc-bulk-auto" data-auto="storage">-</td>
      <td class="qc-bulk-auto" data-auto="color">-</td>
      <td class="qc-bulk-auto" data-auto="battery">-</td>
      <td class="qc-bulk-supplier" data-auto="supplier">-</td>
      <td><select data-carry-field="supplierGrade">${gradeOptions(true)}</select></td>
      <td><select data-carry-field="gcGrade">${gradeOptions(false)}</select></td>
      <td>${requirementGroup("part")}</td>
      <td>${requirementGroup("service")}</td>
      <td><div class="qc-bulk-technician"><select data-carry-field="technician">${technicianOptions()}</select><button type="button" data-add-technician title="Add technician">+</button><button type="button" class="remove" data-remove-technician title="Remove technician">−</button></div></td>
    </tr>`;
  }

  function setRowState(row, text, state = "") {
    const element = row.querySelector("[data-row-state]");
    element.textContent = text;
    element.className = state;
  }

  function valuesForGroup(row, kind) {
    return [...row.querySelectorAll(`[data-requirement="${kind}"]`)].map((select) => select.value).filter(Boolean);
  }

  function setGroupValues(row, kind, values) {
    const group = row.querySelector(`[data-requirement-group="${kind}"]`);
    if (!group) return;
    const list = group.querySelector(".qc-bulk-requirement-list");
    const selectedValues = values.length ? values : [""];
    list.innerHTML = selectedValues.map((value) => requirementSelect(kind, value)).join("");
  }

  function rowSnapshot(row) {
    return {
      supplierGrade: row.querySelector('[data-carry-field="supplierGrade"]')?.value || "",
      gcGrade: row.querySelector('[data-carry-field="gcGrade"]')?.value || "",
      technician: row.querySelector('[data-carry-field="technician"]')?.value || "",
      parts: valuesForGroup(row, "part"),
      services: valuesForGroup(row, "service")
    };
  }

  function applySnapshot(row, snapshot) {
    row.querySelector('[data-carry-field="supplierGrade"]').value = snapshot.supplierGrade;
    row.querySelector('[data-carry-field="gcGrade"]').value = snapshot.gcGrade;
    row.querySelector('[data-carry-field="technician"]').value = snapshot.technician;
    setGroupValues(row, "part", snapshot.parts);
    setGroupValues(row, "service", snapshot.services);
  }

  function createRows(quantity) {
    const previousRow = tableBody.lastElementChild;
    const inherited = previousRow ? rowSnapshot(previousRow) : null;
    tableBody.insertAdjacentHTML("beforeend", Array.from({ length: quantity }, rowMarkup).join(""));
    if (inherited) {
      [...tableBody.querySelectorAll("tr")].slice(-quantity).forEach((row) => applySnapshot(row, inherited));
    }
    trayCount.textContent = `${tableBody.rows.length} lines`;
  }

  function manualKey(field) {
    return `manual${field.charAt(0).toUpperCase()}${field.slice(1)}`;
  }

  function carrySimpleField(row, field) {
    const source = row.querySelector(`[data-carry-field="${field}"]`);
    let nextRow = row.nextElementSibling;
    const key = manualKey(field);
    while (nextRow) {
      if (nextRow.dataset[key] === "yes") break;
      if (nextRow.dataset.completed !== "yes") nextRow.querySelector(`[data-carry-field="${field}"]`).value = source.value;
      nextRow = nextRow.nextElementSibling;
    }
  }

  function carryRequirementGroup(row, kind) {
    const values = valuesForGroup(row, kind);
    let nextRow = row.nextElementSibling;
    const key = manualKey(kind === "part" ? "parts" : "services");
    while (nextRow) {
      if (nextRow.dataset[key] === "yes") break;
      if (nextRow.dataset.completed !== "yes") setGroupValues(nextRow, kind, values);
      nextRow = nextRow.nextElementSibling;
    }
  }

  function clearAutoData(row) {
    ["model", "storage", "color", "battery", "supplier"].forEach((key) => {
      row.querySelector(`[data-auto="${key}"]`).textContent = "-";
    });
    row.classList.remove("is-loaded", "is-error");
    rowJobs.delete(row.dataset.rowId);
    setRowState(row, `Line ${[...tableBody.rows].indexOf(row) + 1} · Waiting`);
  }

  function focusNextScan(row) {
    let nextRow = row.nextElementSibling;
    while (nextRow) {
      const input = nextRow.querySelector(".qc-bulk-imei");
      if (!input.disabled && !input.value) {
        input.focus();
        return;
      }
      nextRow = nextRow.nextElementSibling;
    }
    const firstInspection = [...tableBody.rows].find((candidate) => rowJobs.has(candidate.dataset.rowId) && candidate.dataset.completed !== "yes");
    firstInspection?.querySelector('[data-carry-field="supplierGrade"]')?.focus();
  }

  async function loadScannedRow(row) {
    const input = row.querySelector(".qc-bulk-imei");
    const imei = input.value.trim();
    if (!/^\d{15}$/.test(imei) || row.dataset.loading === "yes" || row.dataset.completed === "yes") return;

    const duplicate = [...tableBody.querySelectorAll(".qc-bulk-imei")].find((other) => other !== input && other.value.trim() === imei);
    if (duplicate) {
      row.classList.add("is-error");
      setRowState(row, "Duplicate IMEI in this tray", "is-error");
      input.focus();
      return;
    }

    row.dataset.loading = "yes";
    setRowState(row, "Loading...", "is-loading");
    const { data, error } = await getClient().rpc("get_initial_qc_job_by_identifier", { p_identifier: imei });
    row.dataset.loading = "";
    if (error) {
      row.classList.add("is-error");
      setRowState(row, error.message || "Could not load IMEI", "is-error");
      return;
    }
    const result = Array.isArray(data) ? data[0] : data;
    if (!result?.found) {
      row.classList.add("is-error");
      setRowState(row, "Not waiting in Initial QC", "is-error");
      input.focus();
      return;
    }

    const job = result.job || {};
    const device = result.device || {};
    const selectedJob = {
      ...job,
      supplierDisplay: supplierLabel(job.supplier_code, result.supplier),
      device
    };
    rowJobs.set(row.dataset.rowId, selectedJob);
    row.querySelector('[data-auto="model"]').textContent = device.model || "-";
    row.querySelector('[data-auto="storage"]').textContent = device.storage_gb ? `${device.storage_gb} GB` : "-";
    row.querySelector('[data-auto="color"]').textContent = device.color || "-";
    row.querySelector('[data-auto="battery"]').textContent = device.battery_health !== null && device.battery_health !== undefined ? `${device.battery_health}%` : "-";
    row.querySelector('[data-auto="supplier"]').textContent = selectedJob.supplierDisplay;
    const supplierGrade = row.querySelector('[data-carry-field="supplierGrade"]');
    const gcGrade = row.querySelector('[data-carry-field="gcGrade"]');
    if (!supplierGrade.value && job.supplier_grade) supplierGrade.value = String(job.supplier_grade).toUpperCase();
    if (!gcGrade.value && device.gc_grade) gcGrade.value = String(device.gc_grade).toUpperCase();
    row.classList.remove("is-error");
    row.classList.add("is-loaded");
    setRowState(row, "Loaded", "is-loaded");
  }

  async function loadTechnicians() {
    const { data, error } = await getClient().rpc("get_assignable_technicians");
    if (error) throw error;
    technicians = data || [];
  }

  function refreshTechnicianSelects(preferredRow, preferredValue = "") {
    tableBody.querySelectorAll('[data-carry-field="technician"]').forEach((select) => {
      const current = select.value;
      select.innerHTML = technicianOptions(select.closest("tr") === preferredRow ? preferredValue : current);
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
    row.dataset[manualKey("technician")] = "yes";
    carrySimpleField(row, "technician");
    showToast("Technician saved.");
  }

  async function removeTechnician(row) {
    const select = row.querySelector('[data-carry-field="technician"]');
    if (!select.value) return;
    if (window.prompt("Enter deletion code to remove this technician:") !== "1213") return;
    const { error } = await getClient().rpc("delete_technician_roster", { p_technician_id: select.value, p_deletion_code: "1213" });
    if (error) throw error;
    await loadTechnicians();
    refreshTechnicianSelects();
    showToast("Technician removed.");
  }

  async function loadPendingCount() {
    const { count, error } = await getClient().from("jobs").select("id", { count: "exact", head: true }).eq("current_status", "initial_qc_pending").is("deleted_at", null);
    if (error) throw error;
    queueCount.textContent = `${Number(count || 0)} waiting`;
  }

  function uniqueValues(values) {
    return [...new Set(values.filter(Boolean))];
  }

  function buildRowSubmission(row) {
    const partsSelected = uniqueValues(valuesForGroup(row, "part"));
    const servicesSelected = uniqueValues(valuesForGroup(row, "service"));
    const selectedLabels = [...partsSelected, ...servicesSelected];
    const technicianId = row.querySelector('[data-carry-field="technician"]').value || null;
    if (selectedLabels.length && !technicianId) throw new Error("Select a technician because parts or services are required.");

    const findings = selectedLabels.map((label) => {
      const item = workItems.find((entry) => entry.label === label);
      return { check_item: item.label, action_required: item.action, priority: "normal", notes: "Initial QC 1" };
    });
    const parts = partsSelected.map((label) => {
      const item = workItems.find((entry) => entry.label === label);
      return { part_name: item.partName, quantity: 1, notes: `Initial QC 1: ${item.label}` };
    });
    const summary = selectedLabels.length ? selectedLabels.join(", ") : "No parts or services";
    return {
      findings,
      parts,
      technicianId,
      supplierGrade: row.querySelector('[data-carry-field="supplierGrade"]').value || null,
      gcGrade: row.querySelector('[data-carry-field="gcGrade"]').value || null,
      notes: `Initial QC 1: ${summary}.`
    };
  }

  async function submitInitialQc(event) {
    event.preventDefault();
    setMessage();
    const rows = [...tableBody.rows].filter((row) => rowJobs.has(row.dataset.rowId) && row.dataset.completed !== "yes");
    if (!rows.length) {
      setMessage("Scan at least one IMEI that is waiting in Initial QC.");
      tableBody.querySelector(".qc-bulk-imei:not(:disabled)")?.focus();
      return;
    }

    const button = document.querySelector("#complete-qc");
    setSubmitting(button, true, "Saving Initial QC...");
    let completed = 0;
    let directFinalQc = 0;
    let sentToLab = 0;
    const errors = [];

    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      const selectedJob = rowJobs.get(row.dataset.rowId);
      let submission;
      try {
        submission = buildRowSubmission(row);
      } catch (error) {
        row.classList.add("is-error");
        setRowState(row, error.message, "is-error");
        errors.push(`Line ${[...tableBody.rows].indexOf(row) + 1}: ${error.message}`);
        continue;
      }

      const hasWork = submission.findings.length > 0 || submission.parts.length > 0;
      setRowState(row, `Saving ${index + 1}/${rows.length}...`, "is-loading");
      const rpcName = hasWork ? "complete_initial_qc_lab_first" : "complete_scanned_initial_qc_with_roster_and_grades";
      const { error } = await getClient().rpc(rpcName, {
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

      if (error) {
        row.classList.add("is-error");
        setRowState(row, error.message || "Could not save", "is-error");
        errors.push(`Line ${[...tableBody.rows].indexOf(row) + 1}: ${error.message || "Could not save"}`);
        continue;
      }

      completed += 1;
      if (hasWork) sentToLab += 1; else directFinalQc += 1;
      row.dataset.completed = "yes";
      row.classList.remove("is-error");
      row.classList.add("is-completed");
      row.querySelectorAll("input, select, button").forEach((control) => { control.disabled = true; });
      setRowState(row, hasWork ? "Completed · Laboratory" : "Completed · Final QC", "is-completed");
    }

    setSubmitting(button, false);
    await loadPendingCount();
    if (completed) showToast(`${completed} Initial QC completed: ${sentToLab} to Laboratory, ${directFinalQc} direct to Final QC.`);
    if (errors.length) {
      setMessage(`${completed} completed. ${errors.length} row(s) need correction. ${errors[0]}`);
    } else {
      setMessage(`${completed} scanned Initial QC row(s) completed successfully.`, true);
    }
  }

  function resetTray() {
    const hasUnfinished = [...tableBody.rows].some((row) => rowJobs.has(row.dataset.rowId) && row.dataset.completed !== "yes");
    if (hasUnfinished && !window.confirm("Clear the unfinished Initial QC tray? No database records will be deleted.")) return;
    tableBody.innerHTML = "";
    rowJobs.clear();
    rowSequence = 0;
    createRows(10);
    setMessage();
    tableBody.querySelector(".qc-bulk-imei")?.focus();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }
    const { data: canInspect, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "initial_qc"] });
    if (error) throw error;
    if (!canInspect) throw new Error("Your account does not have Initial QC permission.");
    await Promise.all([loadTechnicians(), loadPendingCount()]);
    createRows(10);
    app.hidden = false;
    tableBody.querySelector(".qc-bulk-imei")?.focus();
  }

  tableBody.addEventListener("input", (event) => {
    const input = event.target.closest(".qc-bulk-imei");
    if (!input) return;
    input.value = input.value.replace(/\D/g, "").slice(0, 15);
    const row = input.closest("tr");
    window.clearTimeout(rowTimers.get(row));
    if (input.value.length !== 15) {
      clearAutoData(row);
      return;
    }
    focusNextScan(row);
    rowTimers.set(row, window.setTimeout(() => loadScannedRow(row).catch((error) => setRowState(row, error.message || "Could not load IMEI", "is-error")), 120));
  });

  tableBody.addEventListener("keydown", (event) => {
    const input = event.target.closest(".qc-bulk-imei");
    if (!input || event.key !== "Enter") return;
    event.preventDefault();
    focusNextScan(input.closest("tr"));
    loadScannedRow(input.closest("tr")).catch((error) => setRowState(input.closest("tr"), error.message || "Could not load IMEI", "is-error"));
  });

  tableBody.addEventListener("change", (event) => {
    const row = event.target.closest("tr");
    if (!row || row.dataset.completed === "yes") return;
    const simpleSelect = event.target.closest("[data-carry-field]");
    if (simpleSelect) {
      const field = simpleSelect.dataset.carryField;
      row.dataset[manualKey(field)] = "yes";
      carrySimpleField(row, field);
      return;
    }
    const requirement = event.target.closest("[data-requirement]");
    if (requirement) {
      const kind = requirement.dataset.requirement;
      row.dataset[manualKey(kind === "part" ? "parts" : "services")] = "yes";
      carryRequirementGroup(row, kind);
    }
  });

  tableBody.addEventListener("click", (event) => {
    const row = event.target.closest("tr");
    if (!row || row.dataset.completed === "yes") return;
    const addRequirement = event.target.closest("[data-add-requirement]");
    if (addRequirement) {
      const kind = addRequirement.dataset.addRequirement;
      row.querySelector(`[data-requirement-group="${kind}"] .qc-bulk-requirement-list`).insertAdjacentHTML("beforeend", requirementSelect(kind));
      row.dataset[manualKey(kind === "part" ? "parts" : "services")] = "yes";
      return;
    }
    const removeRequirement = event.target.closest("[data-remove-requirement]");
    if (removeRequirement) {
      const kind = removeRequirement.dataset.removeRequirement;
      const list = row.querySelector(`[data-requirement-group="${kind}"] .qc-bulk-requirement-list`);
      const selects = list.querySelectorAll("select");
      if (selects.length === 1 && !selects[0].value) return;
      if (window.prompt(`Enter deletion code to remove this ${kind}:`) !== "1213") return;
      if (selects.length > 1) selects[selects.length - 1].remove(); else selects[0].value = "";
      row.dataset[manualKey(kind === "part" ? "parts" : "services")] = "yes";
      carryRequirementGroup(row, kind);
      return;
    }
    if (event.target.closest("[data-add-technician]")) {
      addTechnician(row).catch((error) => setMessage(error.message || "Technician could not be added."));
      return;
    }
    if (event.target.closest("[data-remove-technician]")) {
      removeTechnician(row).catch((error) => setMessage(error.message || "Technician could not be removed."));
    }
  });

  document.querySelector("#add-ten-rows").addEventListener("click", () => createRows(10));
  document.querySelector("#clear-tray").addEventListener("click", resetTray);
  form.addEventListener("submit", submitInitialQc);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Initial QC could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
