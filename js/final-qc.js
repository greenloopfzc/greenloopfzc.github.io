(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#final-qc-app");
  const permissionMessage = document.querySelector("#permission-message");
  const queueCount = document.querySelector("#queue-count");
  const autoPickButton = document.querySelector("#auto-pick-pending");
  const trayCount = document.querySelector("#tray-count");
  const tableBody = document.querySelector("#final-bulk-body");
  const form = document.querySelector("#final-qc-form");
  const message = document.querySelector("#final-qc-message");
  const tableScroll = document.querySelector("#final-table-scroll");
  const topScroll = document.querySelector("#final-top-scroll");
  const topScrollTrack = document.querySelector("#final-top-scroll-track");
  const pendingModal = document.querySelector("#final-pending-modal");
  const pendingSearch = document.querySelector("#final-pending-search");
  const pendingListBody = document.querySelector("#final-pending-list-body");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const rowSteps = new Map();
  const rowTimers = new WeakMap();
  let client;
  let queueSteps = [];
  let gradeItems = [];
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

  function getWorkOrder(step) {
    return Array.isArray(step?.work_order) ? step.work_order[0] : step?.work_order;
  }

  function getJob(step) {
    const workOrder = getWorkOrder(step) || {};
    return Array.isArray(workOrder.job) ? workOrder.job[0] : workOrder.job;
  }

  function getDevice(step) {
    const job = getJob(step) || {};
    return Array.isArray(job.device) ? job.device[0] : job.device;
  }

  function getSupplier(job) {
    return Array.isArray(job?.supplier) ? job.supplier[0] : job?.supplier;
  }

  function supplierLabel(supplier, batch) {
    if (typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function") {
      return window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(supplier?.supplier_code, batch?.planned_quantity, supplier?.company_name, "-");
    }
    return String(supplier?.supplier_code || "").trim() || "-";
  }

  function gradeOptions(selectedValue = "") {
    return `<option value="">Select final grade</option>${gradeItems.map((item) => `<option value="${escapeHtml(item.option_value)}" data-option-id="${escapeHtml(item.id)}"${String(item.option_value) === String(selectedValue) ? " selected" : ""}>${escapeHtml(item.option_value)}</option>`).join("")}`;
  }

  function resultValue(row) {
    const pass = row.querySelector('[data-result="pass"]')?.checked;
    const frame = row.querySelector('[data-result="frame"]')?.checked;
    const fail = row.querySelector('[data-result="fail"]')?.checked;
    if (fail) return "fail";
    if (frame) return "frame";
    if (pass) return "pass";
    return "";
  }

  function setResultSelection(row, value) {
    row.querySelector('[data-result="pass"]').checked = value === "pass";
    row.querySelector('[data-result="frame"]').checked = value === "frame";
    row.querySelector('[data-result="fail"]').checked = value === "fail";
    syncFinalGradeRule(row);
  }

  function syncFinalGradeRule(row) {
    const isFrame = resultValue(row) === "frame";
    const gradeSelect = row.querySelector("[data-final-grade]");
    if (isFrame && gradeSelect) gradeSelect.value = "";
    row.querySelectorAll("[data-final-grade], [data-add-grade], [data-remove-grade]").forEach((control) => {
      control.disabled = isFrame;
      control.title = isFrame ? "Frame Department will decide the Final Grade" : control.dataset.originalTitle || control.title;
    });
  }

  function applyResultRules(row, changedInput) {
    const pass = row.querySelector('[data-result="pass"]');
    const frame = row.querySelector('[data-result="frame"]');
    const fail = row.querySelector('[data-result="fail"]');
    if (changedInput.checked) {
      [pass, frame, fail].filter((input) => input !== changedInput).forEach((input) => { input.checked = false; });
    }
    syncFinalGradeRule(row);
  }

  function rowMarkup() {
    rowSequence += 1;
    const rowId = `final-qc-row-${rowSequence}`;
    return `<tr data-row-id="${rowId}">
      <td class="final-imei-cell"><input class="final-row-imei" inputmode="numeric" autocomplete="off" maxlength="15" placeholder="Scan IMEI"><small data-row-state>Line ${rowSequence} - Waiting</small></td>
      <td class="final-auto-cell" data-auto="model">-</td>
      <td class="final-auto-cell" data-auto="storage">-</td>
      <td class="final-auto-cell" data-auto="color">-</td>
      <td class="final-auto-cell" data-auto="battery">-</td>
      <td class="final-battery-cell"><input type="number" min="0" max="100" step="1" inputmode="numeric" data-final-battery placeholder="BH %" aria-label="Final Battery Health"></td>
      <td class="final-supplier-cell" data-auto="supplier">-</td>
      <td class="final-auto-cell" data-auto="supplier-grade">-</td>
      <td class="final-auto-cell" data-auto="initial-grade">-</td>
      <td class="final-grade-cell"><div class="final-grade-control"><select data-final-grade>${gradeOptions()}</select><button type="button" data-add-grade title="Add final grade">+</button><button type="button" class="remove" data-remove-grade title="Remove final grade">−</button></div></td>
      <td class="final-result-cell pass"><label><input type="checkbox" data-result="pass"><span>Pass</span></label></td>
      <td class="final-result-cell frame"><label><input type="checkbox" data-result="frame"><span>Frame</span></label></td>
      <td class="final-result-cell fail"><label><input type="checkbox" data-result="fail"><span>Fail</span></label></td>
      <td class="final-save-cell"><button type="button" class="final-row-save" data-save-row>Save</button></td>
    </tr>`;
  }

  function createRows(quantity) {
    const templateRow = tableBody.firstElementChild;
    const inheritedGrade = templateRow?.querySelector("[data-final-grade]")?.value || "";
    const inheritedResult = templateRow ? resultValue(templateRow) : "";
    tableBody.insertAdjacentHTML("beforeend", Array.from({ length: quantity }, rowMarkup).join(""));
    [...tableBody.rows].slice(-quantity).forEach((row) => {
      row.querySelector("[data-final-grade]").value = inheritedGrade;
      setResultSelection(row, inheritedResult);
    });
    trayCount.textContent = `${tableBody.rows.length} lines`;
    window.requestAnimationFrame(syncHorizontalScrollWidth);
  }

  function setRowState(row, text, state = "") {
    const element = row.querySelector("[data-row-state]");
    element.textContent = text;
    element.className = state;
  }

  function clearRowData(row) {
    ["serial", "region", "model", "storage", "color", "battery", "supplier", "supplier-grade", "initial-grade"].forEach((field) => {
      row.querySelector(`[data-auto="${field}"]`).textContent = "-";
    });
    row.querySelector("[data-final-battery]").value = "";
    row.classList.remove("is-loaded", "is-error");
    rowSteps.delete(row.dataset.rowId);
    setRowState(row, `Line ${[...tableBody.rows].indexOf(row) + 1} - Waiting`);
  }

  function focusNextScan(row) {
    let next = row.nextElementSibling;
    while (next) {
      const input = next.querySelector(".final-row-imei");
      if (!input.disabled && !input.value) {
        input.focus();
        return;
      }
      next = next.nextElementSibling;
    }
    const firstGrade = [...tableBody.rows].find((candidate) => rowSteps.has(candidate.dataset.rowId) && candidate.dataset.completed !== "yes");
    firstGrade?.querySelector("[data-final-grade]")?.focus();
  }

  function focusNextInspection(row) {
    let next = row.nextElementSibling;
    while (next) {
      if (rowSteps.has(next.dataset.rowId) && next.dataset.completed !== "yes") {
        next.querySelector("[data-final-grade]")?.focus();
        return;
      }
      next = next.nextElementSibling;
    }
    const nextScan = [...tableBody.querySelectorAll(".final-row-imei:not(:disabled)")].find((input) => !input.value);
    nextScan?.focus();
  }

  function carryGrade(row) {
    // Only line 1 supplies defaults. Later-row grade changes are individual.
    if (row !== tableBody.firstElementChild) return;
    const value = row.querySelector("[data-final-grade]").value;
    let next = row.nextElementSibling;
    while (next) {
      if (next.dataset.manualGrade !== "yes" && next.dataset.completed !== "yes") next.querySelector("[data-final-grade]").value = value;
      next = next.nextElementSibling;
    }
  }

  function carryResult(row) {
    // Pass/Fail corrections on a middle row must not modify following rows.
    if (row !== tableBody.firstElementChild) return;
    const value = resultValue(row);
    let next = row.nextElementSibling;
    while (next) {
      if (next.dataset.manualResult !== "yes" && next.dataset.completed !== "yes") {
        setResultSelection(next, value);
      }
      next = next.nextElementSibling;
    }
  }

  async function loadFinalGrades(preferredRow, preferredValue = "") {
    const preserved = [...tableBody.querySelectorAll("[data-final-grade]")].map((select) => select.value);
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "grade" });
    if (error) throw error;
    gradeItems = data || [];
    tableBody.querySelectorAll("[data-final-grade]").forEach((select, index) => {
      const chosen = select.closest("tr") === preferredRow ? preferredValue : preserved[index];
      select.innerHTML = gradeOptions(chosen);
      if ([...select.options].some((option) => option.value === chosen)) select.value = chosen;
    });
  }

  async function addFinalGrade(row) {
    const value = window.prompt("Enter a new Final QC grade.");
    if (!value?.trim()) return;
    const { data, error } = await getClient().rpc("add_entry_option", { p_option_group: "grade", p_option_value: value.trim() });
    if (error) throw error;
    const result = Array.isArray(data) ? data[0] : data;
    await loadFinalGrades(row, result?.saved_value || value.trim());
    row.dataset.manualGrade = "yes";
    carryGrade(row);
    showToast("Final QC grade is ready to use.");
  }

  async function removeFinalGrade(row) {
    const select = row.querySelector("[data-final-grade]");
    const option = select.options[select.selectedIndex];
    const optionId = option?.dataset.optionId;
    if (!optionId) {
      setMessage("Select a Final Grade before removing it.");
      return;
    }
    const code = window.prompt(`Enter deletion code to remove ${option.text}.`);
    if (code === null) return;
    const { error } = await getClient().rpc("delete_entry_option", { p_option_id: optionId, p_deletion_code: code });
    if (error) throw error;
    await loadFinalGrades();
    showToast("Final QC grade was removed.");
  }

  async function loadScannedRow(row) {
    const input = row.querySelector(".final-row-imei");
    const imei = input.value.trim();
    if (!/^\d{15}$/.test(imei) || row.dataset.loading === "yes" || row.dataset.completed === "yes") return;
    const duplicate = [...tableBody.querySelectorAll(".final-row-imei")].find((other) => other !== input && other.value.trim() === imei);
    if (duplicate) {
      row.classList.add("is-error");
      setRowState(row, "Duplicate IMEI in this tray", "is-error");
      input.focus();
      return;
    }

    row.dataset.loading = "yes";
    setRowState(row, "Loading...", "is-loading");
    let step = queueSteps.find((candidate) => String(getDevice(candidate)?.imei_1 || "") === imei);
    if (!step) {
      await loadQueue();
      step = queueSteps.find((candidate) => String(getDevice(candidate)?.imei_1 || "") === imei);
    }
    row.dataset.loading = "";
    if (!step) {
      row.classList.add("is-error");
      setRowState(row, "Not waiting in Final QC", "is-error");
      input.focus();
      return;
    }

    const job = getJob(step) || {};
    const device = getDevice(step) || {};
    const supplier = getSupplier(job) || {};
    rowSteps.set(row.dataset.rowId, step);
    row.querySelector('[data-auto="model"]').textContent = device.model || "-";
    row.querySelector('[data-auto="storage"]').textContent = device.storage_gb ? `${device.storage_gb} GB` : "-";
    row.querySelector('[data-auto="color"]').textContent = device.color || "-";
    row.querySelector('[data-auto="battery"]').textContent = device.battery_health !== null && device.battery_health !== undefined ? `${device.battery_health}%` : "-";
    row.querySelector("[data-final-battery]").value = device.battery_health !== null && device.battery_health !== undefined ? String(device.battery_health) : "";
    row.querySelector('[data-auto="supplier"]').textContent = supplierLabel(supplier, job.receiving_batch);
    row.querySelector('[data-auto="supplier-grade"]').textContent = job.supplier_grade || "-";
    row.querySelector('[data-auto="initial-grade"]').textContent = device.gc_grade || "-";
    row.classList.remove("is-error");
    row.classList.add("is-loaded");
    setRowState(row, "Loaded", "is-loaded");
    const { error: receivedError } = await getClient().rpc("receive_final_qc_phone", { p_final_qc_step_id: step.id });
    if (receivedError) throw receivedError;
  }

  async function loadQueue() {
    const { data, error } = await getClient()
      .from("job_work_order_steps")
      .select("id, work_order:job_work_orders!inner(work_order_number, job:jobs!inner(id, job_number, supplier_grade, supplier:suppliers(supplier_code, company_name), receiving_batch:receiving_batches(planned_quantity), device:devices(device_number, imei_1, brand, model, storage_gb, color, battery_health, gc_grade)))")
      .eq("department", "final_qc")
      .eq("step_status", "in_progress")
      .order("created_at", { ascending: true });
    if (error) throw error;
    queueSteps = data || [];
    queueCount.textContent = `${queueSteps.length} waiting`;
    queueCount.setAttribute("aria-label", `View ${queueSteps.length} phones waiting for Final QC`);
    if (!pendingModal.hidden) renderPendingJobs(pendingSearch.value);
  }

  async function autoPickAllPending() {
    setMessage();
    setSubmitting(autoPickButton, true, "Loading...");
    try {
      await loadQueue();
      const pending = queueSteps
        .map((step) => ({ step, imei: String(getDevice(step)?.imei_1 || "").trim() }))
        .filter((item) => /^\d{15}$/.test(item.imei));

      if (!pending.length) {
        setMessage("No valid IMEIs are waiting in Final QC.");
        return;
      }

      const trayHasData = rowSteps.size > 0 || [...tableBody.querySelectorAll(".final-row-imei")].some((input) => input.value.trim());
      if (trayHasData && !window.confirm(`Replace the current tray and load all ${pending.length} pending Final QC IMEIs? Unsaved tray entries will be cleared.`)) return;

      tableBody.innerHTML = "";
      rowSteps.clear();
      rowSequence = 0;
      createRows(pending.length);
      const rows = [...tableBody.rows];
      const batchSize = 20;

      for (let start = 0; start < pending.length; start += batchSize) {
        const end = Math.min(start + batchSize, pending.length);
        await Promise.all(pending.slice(start, end).map((item, offset) => {
          const row = rows[start + offset];
          row.querySelector(".final-row-imei").value = item.imei;
          return loadScannedRow(row);
        }));
        autoPickButton.textContent = `Loading ${end}/${pending.length}`;
      }

      const loadedCount = rows.filter((row) => rowSteps.has(row.dataset.rowId)).length;
      if (loadedCount === pending.length) {
        setMessage(`${loadedCount} pending Final QC IMEIs loaded. Review Final Grade, Battery Health, and result before saving.`, true);
      } else {
        setMessage(`${loadedCount} of ${pending.length} pending Final QC IMEIs loaded. Check the highlighted rows.`);
      }
      rows.find((row) => rowSteps.has(row.dataset.rowId))?.querySelector("[data-final-grade]")?.focus();
      window.requestAnimationFrame(syncHorizontalScrollWidth);
    } catch (error) {
      setMessage(error.message || "Pending Final QC IMEIs could not be loaded.");
    } finally {
      setSubmitting(autoPickButton, false);
    }
  }

  function pendingData(step) {
    const job = getJob(step) || {};
    const device = getDevice(step) || {};
    return {
      imei: device.imei_1 || "-",
      supplier: supplierLabel(getSupplier(job) || {}, job.receiving_batch),
      model: device.model || "-",
      storage: device.storage_gb ? `${device.storage_gb} GB` : "-",
      color: device.color || "-",
      battery: device.battery_health !== null && device.battery_health !== undefined ? `${device.battery_health}%` : "-",
      supplierGrade: job.supplier_grade || "-",
      initialGrade: device.gc_grade || "-"
    };
  }

  function renderPendingJobs(filter = "") {
    const search = String(filter || "").trim().toLocaleLowerCase();
    const rows = queueSteps.map(pendingData).filter((row) => !search || Object.values(row).some((value) => String(value).toLocaleLowerCase().includes(search)));
    pendingListBody.innerHTML = rows.length
      ? rows.map((row, index) => `<tr><td>${index + 1}</td><td>${escapeHtml(row.imei)}</td><td>${escapeHtml(row.supplier)}</td><td>${escapeHtml(row.model)}</td><td>${escapeHtml(row.storage)}</td><td>${escapeHtml(row.color)}</td><td>${escapeHtml(row.battery)}</td><td>${escapeHtml(row.supplierGrade)}</td><td>${escapeHtml(row.initialGrade)}</td></tr>`).join("")
      : '<tr><td colspan="9" class="final-pending-empty">No pending phones match this search.</td></tr>';
  }

  function openPendingModal() {
    pendingSearch.value = "";
    renderPendingJobs();
    pendingModal.hidden = false;
    document.body.classList.add("final-modal-open");
    window.setTimeout(() => pendingSearch.focus(), 0);
  }

  function closePendingModal() {
    pendingModal.hidden = true;
    document.body.classList.remove("final-modal-open");
    queueCount.focus();
  }

  async function saveOneRow(row, progressText = "Saving...") {
    if (!row || row.dataset.saving === "yes" || row.dataset.completed === "yes") return { ok: false, error: "This row is already complete." };
    const step = rowSteps.get(row.dataset.rowId);
    if (!step) {
      const errorText = "Scan and load this IMEI before saving.";
      setRowState(row, errorText, "is-error");
      row.querySelector(".final-row-imei")?.focus();
      return { ok: false, error: errorText };
    }
    const result = resultValue(row);
    const finalGrade = row.querySelector("[data-final-grade]").value;
    const finalBatteryInput = row.querySelector("[data-final-battery]");
    const finalBatteryText = finalBatteryInput.value.trim();
    const finalBattery = finalBatteryText === "" ? null : Number(finalBatteryText);
    if (!result) {
      const errorText = "Tick Pass, Frame, or Fail.";
      row.classList.add("is-error");
      setRowState(row, errorText, "is-error");
      return { ok: false, error: errorText };
    }
    if (result === "pass" && !finalGrade) {
      const errorText = "Select the Final Grade before passing this phone.";
      row.classList.add("is-error");
      setRowState(row, errorText, "is-error");
      row.querySelector("[data-final-grade]").focus();
      return { ok: false, error: errorText };
    }
    if ((result === "pass" || result === "frame") && (!Number.isInteger(finalBattery) || finalBattery < 0 || finalBattery > 100)) {
      const errorText = "Enter Final Battery Health from 0 to 100 before passing this phone.";
      row.classList.add("is-error");
      setRowState(row, errorText, "is-error");
      finalBatteryInput.focus();
      return { ok: false, error: errorText };
    }
    if (finalBattery !== null && (!Number.isInteger(finalBattery) || finalBattery < 0 || finalBattery > 100)) {
      const errorText = "Final Battery Health must be from 0 to 100.";
      row.classList.add("is-error");
      setRowState(row, errorText, "is-error");
      finalBatteryInput.focus();
      return { ok: false, error: errorText };
    }

    const rowButton = row.querySelector("[data-save-row]");
    row.dataset.saving = "yes";
    setSubmitting(rowButton, true, "Saving...");
    setRowState(row, progressText, "is-loading");
    const rpcResponse = result === "frame"
      ? await getClient().rpc("route_final_qc_pass_to_frame_v2", {
        p_job_id: getJob(step).id,
        p_final_grade: null,
        p_final_battery_health: finalBattery,
        p_notes: "Final QC routed to Frame for required work"
      })
      : await getClient().rpc("complete_final_qc_with_final_grade", {
        p_job_id: getJob(step).id,
        p_result: result,
        p_final_grade: result === "pass" ? finalGrade : null,
        p_final_battery_health: finalBattery,
        p_notes: result === "pass" ? "Final QC passed" : "Final QC failed",
        p_failure_department: result === "fail" ? "laboratory" : null,
        p_failure_reason: result === "fail" ? "Final QC failed - return to Laboratory" : null,
        p_checks: []
      });
    const { data, error } = rpcResponse;
    row.dataset.saving = "";
    if (error) {
      setSubmitting(rowButton, false);
      row.classList.add("is-error");
      setRowState(row, error.message || "Could not save", "is-error");
      return { ok: false, error: error.message || "Could not save" };
    }

    const response = data?.[0];
    row.dataset.completed = "yes";
    row.classList.remove("is-error");
    row.classList.add("is-completed");
    row.querySelectorAll("input, select, button").forEach((control) => { control.disabled = true; });
    rowButton.textContent = "Saved";
    setRowState(row, result === "pass"
      ? `Passed - Attempt ${response?.attempt_number || "-"}`
      : result === "frame" ? "Sent to Frame - Grade pending" : "Failed - Laboratory rework", "is-completed");
    queueSteps = queueSteps.filter((candidate) => candidate.id !== step.id);
    queueCount.textContent = `${queueSteps.length} waiting`;
    return { ok: true, result };
  }

  async function saveRowFromButton(row) {
    setMessage();
    const result = await saveOneRow(row);
    if (!result.ok) {
      setMessage(result.error);
      return;
    }
    renderPendingJobs(pendingSearch.value);
    showToast(result.result === "pass"
      ? "Final QC passed. Phone sent to Ready Stock."
      : result.result === "frame"
        ? "Phone sent to Frame. A Frame Pass will send it to Ready Stock."
        : "Final QC failed. Phone returned to Laboratory.");
    focusNextInspection(row);
  }

  async function submitAll(event) {
    event.preventDefault();
    setMessage();
    const rows = [...tableBody.rows].filter((row) => rowSteps.has(row.dataset.rowId) && row.dataset.completed !== "yes");
    if (!rows.length) {
      setMessage("Scan at least one IMEI that is waiting in Final QC.");
      tableBody.querySelector(".final-row-imei:not(:disabled)")?.focus();
      return;
    }

    const button = document.querySelector("#complete-final-qc");
    setSubmitting(button, true, "Saving Final QC...");
    let passed = 0;
    let framed = 0;
    let failed = 0;
    const errors = [];
    for (let index = 0; index < rows.length; index += 1) {
      const result = await saveOneRow(rows[index], `Saving ${index + 1}/${rows.length}...`);
      if (!result.ok) {
        errors.push(`Line ${[...tableBody.rows].indexOf(rows[index]) + 1}: ${result.error}`);
      } else if (result.result === "pass") {
        passed += 1;
      } else if (result.result === "frame") {
        framed += 1;
      } else {
        failed += 1;
      }
    }
    setSubmitting(button, false);
    renderPendingJobs(pendingSearch.value);
    if (passed + framed + failed) showToast(`${passed} ready, ${framed} sent to Frame, and ${failed} failed.`);
    if (errors.length) setMessage(`${passed + framed + failed} completed. ${errors.length} row(s) need correction. ${errors[0]}`);
    else setMessage(`${passed + framed + failed} scanned Final QC row(s) completed successfully.`, true);
  }

  function resetTray() {
    const unfinished = [...tableBody.rows].some((row) => rowSteps.has(row.dataset.rowId) && row.dataset.completed !== "yes");
    if (unfinished && !window.confirm("Clear the unfinished Final QC tray? No database records will be deleted.")) return;
    tableBody.innerHTML = "";
    rowSteps.clear();
    rowSequence = 0;
    createRows(10);
    setMessage();
    tableBody.querySelector(".final-row-imei")?.focus();
  }

  function syncHorizontalScrollWidth() {
    topScrollTrack.style.width = `${tableScroll.scrollWidth}px`;
    topScroll.hidden = tableScroll.scrollWidth <= tableScroll.clientWidth + 2;
  }

  function setupHorizontalScroll() {
    let syncing = false;
    topScroll.addEventListener("scroll", () => {
      if (syncing) return;
      syncing = true;
      tableScroll.scrollLeft = topScroll.scrollLeft;
      window.requestAnimationFrame(() => { syncing = false; });
    });
    tableScroll.addEventListener("scroll", () => {
      if (syncing) return;
      syncing = true;
      topScroll.scrollLeft = tableScroll.scrollLeft;
      window.requestAnimationFrame(() => { syncing = false; });
    });
    if (window.ResizeObserver) new ResizeObserver(syncHorizontalScrollWidth).observe(tableScroll);
    window.addEventListener("resize", syncHorizontalScrollWidth);
    syncHorizontalScrollWidth();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }
    const { data: canInspect, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "final_qc"] });
    if (error) throw error;
    if (!canInspect) throw new Error("Your account does not have Final QC permission.");
    await Promise.all([loadFinalGrades(), loadQueue()]);
    createRows(10);
    app.hidden = false;
    setupHorizontalScroll();
    tableBody.querySelector(".final-row-imei")?.focus();
  }

  tableBody.addEventListener("input", (event) => {
    const input = event.target.closest(".final-row-imei");
    if (!input) return;
    input.value = input.value.replace(/\D/g, "").slice(0, 15);
    const row = input.closest("tr");
    window.clearTimeout(rowTimers.get(row));
    if (input.value.length !== 15) {
      clearRowData(row);
      return;
    }
    focusNextScan(row);
    rowTimers.set(row, window.setTimeout(() => loadScannedRow(row).catch((error) => setRowState(row, error.message || "Could not load IMEI", "is-error")), 120));
  });

  tableBody.addEventListener("keydown", (event) => {
    const input = event.target.closest(".final-row-imei");
    if (!input || event.key !== "Enter") return;
    event.preventDefault();
    // The scanner's trailing Enter reaches the next row because the final
    // digit already advanced focus. Ignore Enter on that empty row so scanning
    // continues line-by-line without skipping a line.
    if (!/^\d{15}$/.test(input.value.trim())) return;
    focusNextScan(input.closest("tr"));
    loadScannedRow(input.closest("tr")).catch((error) => setRowState(input.closest("tr"), error.message || "Could not load IMEI", "is-error"));
  });

  tableBody.addEventListener("change", (event) => {
    const row = event.target.closest("tr");
    if (!row || row.dataset.completed === "yes") return;
    if (event.target.matches("[data-final-grade]")) {
      row.dataset.manualGrade = "yes";
      carryGrade(row);
      return;
    }
    if (event.target.matches("[data-result]")) {
      applyResultRules(row, event.target);
      row.dataset.manualResult = "yes";
      carryResult(row);
    }
  });

  tableBody.addEventListener("click", (event) => {
    const row = event.target.closest("tr");
    if (!row || row.dataset.completed === "yes") return;
    if (event.target.closest("[data-save-row]")) {
      saveRowFromButton(row).catch((error) => setMessage(error.message || "Final QC row could not be saved."));
      return;
    }
    if (event.target.closest("[data-add-grade]")) {
      addFinalGrade(row).catch((error) => setMessage(error.message || "Final Grade could not be added."));
      return;
    }
    if (event.target.closest("[data-remove-grade]")) {
      removeFinalGrade(row).catch((error) => setMessage(error.message || "Final Grade could not be removed."));
    }
  });

  document.querySelector("#add-ten-rows").addEventListener("click", () => createRows(10));
  document.querySelector("#clear-tray").addEventListener("click", resetTray);
  autoPickButton.addEventListener("click", autoPickAllPending);
  document.querySelector("#refresh-queue").addEventListener("click", () => loadQueue().then(() => showToast("Final QC queue refreshed.")).catch((error) => setMessage(error.message || "Queue could not be refreshed.")));
  queueCount.addEventListener("click", openPendingModal);
  pendingSearch.addEventListener("input", () => renderPendingJobs(pendingSearch.value));
  pendingModal.addEventListener("click", (event) => { if (event.target.closest("[data-close-pending]")) closePendingModal(); });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !pendingModal.hidden) closePendingModal(); });
  form.addEventListener("submit", submitAll);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Final QC could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
