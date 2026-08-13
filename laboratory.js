(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#lab-app");
  const permissionMessage = document.querySelector("#permission-message");
  const stepSelect = document.querySelector("#lab-step-select");
  const imeiScan = document.querySelector("#lab-imei-scan");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#lab-empty");
  const workspace = document.querySelector("#lab-workspace");
  const deviceSummary = document.querySelector("#lab-device-summary");
  const findingsList = document.querySelector("#lab-findings");
  const plannedPartsList = document.querySelector("#lab-planned-parts");
  const partsList = document.querySelector("#lab-parts");
  const form = document.querySelector("#lab-form");
  const message = document.querySelector("#lab-message");
  const startButton = document.querySelector("#start-lab-work");
  const pauseButton = document.querySelector("#pause-lab-work");
  const resumeButton = document.querySelector("#resume-lab-work");
  const completeButton = document.querySelector("#complete-lab-work");
  const statusTitle = document.querySelector("#lab-status-title");
  const statusText = document.querySelector("#lab-status-text");
  const activeTime = document.querySelector("#lab-active-time");
  const reworkCount = document.querySelector("#lab-rework-count");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let queueSteps = [];
  let selectedStep;
  let currentRecord;
  let timer;
  let toastTimer;

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function escapeHtml(value) {
    return String(value || "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function showToast(text) {
    window.clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400);
  }

  function setMessage(text = "", type = "error") {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
    message.classList.toggle("is-success", type === "success");
  }

  function setSubmitting(button, isSubmitting, label) {
    button.disabled = isSubmitting;
    if (isSubmitting) button.dataset.originalLabel = button.textContent.trim();
    button.textContent = isSubmitting ? label : button.dataset.originalLabel || button.textContent.trim();
  }

  function getWorkOrder(step) { return Array.isArray(step.work_order) ? step.work_order[0] : step.work_order; }
  function getJob(step) { const workOrder = getWorkOrder(step) || {}; return Array.isArray(workOrder.job) ? workOrder.job[0] : workOrder.job; }
  function getDevice(step) { const job = getJob(step) || {}; return Array.isArray(job.device) ? job.device[0] : job.device; }
  function getSupplier(job) { return Array.isArray(job?.supplier) ? job.supplier[0] : job?.supplier; }
  function supplierLabel(supplier) { return [supplier?.supplier_code, supplier?.company_name].filter((value) => String(value || "").trim()).join(" - ") || "Not recorded"; }

  function money(value) {
    return `AED ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }

  function secondsToClock(seconds) {
    const safe = Math.max(0, Number(seconds) || 0);
    const hours = Math.floor(safe / 3600);
    const minutes = Math.floor((safe % 3600) / 60);
    const remainingSeconds = safe % 60;
    return [hours, minutes, remainingSeconds].map((value) => String(value).padStart(2, "0")).join(":");
  }

  function currentActiveSeconds(record) {
    if (!record?.started_at) return 0;
    const end = record.completed_at ? new Date(record.completed_at) : new Date();
    const started = new Date(record.started_at);
    const currentPause = record.paused_at ? Math.max(0, Math.floor((end - new Date(record.paused_at)) / 1000)) : 0;
    return Math.max(0, Math.floor((end - started) / 1000) - Number(record.paused_seconds || 0) - currentPause);
  }

  function refreshTimer() {
    activeTime.textContent = secondsToClock(currentActiveSeconds(currentRecord));
  }

  function setWorkState(record) {
    currentRecord = record || null;
    window.clearInterval(timer);
    const started = Boolean(record?.started_at && !record?.completed_at);
    const paused = Boolean(record?.paused_at && !record?.completed_at);
    startButton.hidden = started;
    pauseButton.hidden = !started || paused;
    resumeButton.hidden = !paused;
    completeButton.disabled = !started || paused;
    reworkCount.textContent = String(selectedStep?.rework_count || record?.rework_cycle || 0);

    if (paused) {
      statusTitle.textContent = "Work paused";
      statusText.textContent = "Paused time is excluded from active repair time. Resume before completing the job.";
    } else if (started) {
      statusTitle.textContent = "Work in progress";
      statusText.textContent = "Technician assignment and start time are saved. Complete only after all technical work is finished.";
    } else {
      statusTitle.textContent = "Ready to start";
      statusText.textContent = "Start work to save the assigned technician and automatic start time.";
    }
    refreshTimer();
    if (started) timer = window.setInterval(refreshTimer, 1000);
  }

  async function loadFindings(jobId) {
    const { data, error } = await getClient()
      .from("initial_qc_inspections")
      .select("id, initial_qc_findings(check_item, action_required, department, priority, notes)")
      .eq("job_id", jobId)
      .maybeSingle();
    if (error) throw error;
    return (data?.initial_qc_findings || []).filter((finding) => finding.department === "laboratory");
  }

  async function loadIssuedParts(jobId) {
    const { data: requests, error: requestError } = await getClient()
      .from("job_part_requests")
      .select("id, part_name, quantity_requested, quantity_issued, quantity_installed, quantity_returned, status")
      .eq("job_id", jobId)
      .order("requested_at", { ascending: true });
    if (requestError) throw requestError;
    const requestIds = (requests || []).map((request) => request.id);
    if (!requestIds.length) return [];
    const { data: issues, error: issueError } = await getClient()
      .from("part_issue_transactions")
      .select("id, part_request_id, quantity_issued, quantity_returned, unit_cost, status, inventory:part_inventory(sku, part_name, notes)")
      .in("part_request_id", requestIds)
      .order("issued_at", { ascending: true });
    if (issueError) throw issueError;
    const issueIds = (issues || []).map((issue) => issue.id);
    const { data: installations, error: installationError } = issueIds.length
      ? await getClient().from("part_installations").select("part_issue_id, quantity_installed").in("part_issue_id", issueIds)
      : { data: [], error: null };
    if (installationError) throw installationError;
    const installedByIssue = (installations || []).reduce((totals, installation) => {
      totals[installation.part_issue_id] = (totals[installation.part_issue_id] || 0) + Number(installation.quantity_installed || 0);
      return totals;
    }, {});
    return (issues || []).map((issue) => ({
      ...issue,
      part: (requests || []).find((request) => request.id === issue.part_request_id),
      installed: installedByIssue[issue.id] || 0
    }));
  }

  async function loadPlannedParts(jobId) {
    const { data, error } = await getClient()
      .from("initial_qc_part_requirements")
      .select("id, part_name, quantity_required, notes, status, part_request_id")
      .eq("job_id", jobId)
      .order("identified_at", { ascending: true });
    if (error) throw error;
    return data || [];
  }

  function renderPlannedParts(requirements) {
    if (!requirements.length) {
      plannedPartsList.innerHTML = '<p class="history-empty">No parts were identified by Initial QC.</p>';
      return;
    }

    plannedPartsList.innerHTML = requirements.map((requirement) => {
      const isPending = requirement.status === "identified";
      const statusLabel = requirement.status === "requested"
        ? "Requested from Parts"
        : requirement.status === "not_required" ? "Not required" : "Waiting for Laboratory review";
      const actions = isPending
        ? `<div class="lab-planned-actions"><button type="button" data-request-planned-part="${requirement.id}">Request from Parts</button><button type="button" data-skip-planned-part="${requirement.id}">Not required</button></div>`
        : `<span class="lab-plan-status ${requirement.status}">${statusLabel}</span>`;
      return `<article class="lab-planned-row"><div><strong>${escapeHtml(requirement.part_name)}</strong><span>Quantity ${Number(requirement.quantity_required || 1)}${requirement.notes ? ` · ${escapeHtml(requirement.notes)}` : ""}</span></div>${actions}</article>`;
    }).join("");
  }

  function renderIssuedParts(issues) {
    if (!issues.length) {
      partsList.innerHTML = '<p class="history-empty">No issued parts for this job.</p>';
      return;
    }
    partsList.innerHTML = issues.map((issue) => {
      const available = Math.max(0, Number(issue.quantity_issued) - Number(issue.quantity_returned) - Number(issue.installed));
      const part = issue.part || {};
      const inventoryPart = Array.isArray(issue.inventory) ? issue.inventory[0] : issue.inventory || {};
      const invoice = String(inventoryPart.notes || "").match(/\[Inventory invoice:\s*([^|\]]+)/i)?.[1]?.trim() || "Legacy stock";
      part.part_name = `${part.part_name || inventoryPart.part_name || "Part"} | Invoice ${invoice}`;
      return `<article class="lab-part-row"><div><strong>${escapeHtml(part.part_name || "Part")}</strong><span>Issued ${issue.quantity_issued} · Installed ${issue.installed} · Returned ${issue.quantity_returned} · ${money(issue.unit_cost)} each</span></div><div class="lab-part-actions"><input data-issue-quantity="${issue.id}" type="number" min="1" max="${available}" step="1" value="${available || 1}" ${available ? "" : "disabled"}><button type="button" data-install-part="${issue.id}" ${available ? "" : "disabled"}>Install</button><button type="button" data-return-part="${issue.id}" ${available ? "" : "disabled"}>Return</button></div></article>`;
    }).join("");
  }

  async function loadSelectedStep() {
    selectedStep = queueSteps.find((step) => step.id === stepSelect.value);
    workspace.hidden = !selectedStep;
    setMessage();
    form.reset();
    if (!selectedStep) {
      setWorkState(null);
      return;
    }
    const job = getJob(selectedStep) || {};
    const device = getDevice(selectedStep) || {};
    const supplier = getSupplier(job) || {};
    const workOrder = getWorkOrder(selectedStep) || {};
    deviceSummary.innerHTML = `<dl><div><dt>IMEI</dt><dd>${escapeHtml(device.imei_1 || "—")}</dd></div><div><dt>Supplier code</dt><dd>${escapeHtml(supplierLabel(supplier))}</dd></div><div><dt>Model</dt><dd>${escapeHtml(device.model || "—")}</dd></div><div><dt>GB</dt><dd>${escapeHtml(device.storage_gb ? `${device.storage_gb} GB` : "—")}</dd></div><div><dt>Color</dt><dd>${escapeHtml(device.color || "—")}</dd></div><div><dt>Grade</dt><dd>${escapeHtml(job.supplier_grade || device.original_grade || "—")}</dd></div><div><dt>Technician</dt><dd>${escapeHtml(selectedStep.assigned_technician_name || "Not assigned")}</dd></div></dl>`;

    const [findings, plannedParts, recordResponse, issuedParts] = await Promise.all([
      loadFindings(job.id),
      loadPlannedParts(job.id),
      getClient().from("laboratory_work_records").select("id, rework_cycle, started_at, paused_at, paused_seconds, completed_at").eq("work_order_step_id", selectedStep.id).eq("rework_cycle", selectedStep.rework_count).maybeSingle(),
      loadIssuedParts(job.id)
    ]);
    if (recordResponse.error) throw recordResponse.error;
    findingsList.innerHTML = findings.length
      ? findings.map((finding) => `<li><strong>${escapeHtml(finding.check_item)}</strong><span>${escapeHtml(finding.action_required)} · ${escapeHtml(finding.priority)} priority${finding.notes ? ` · ${escapeHtml(finding.notes)}` : ""}</span></li>`).join("")
      : "<li><strong>Laboratory work required</strong><span>Review the work order and complete the assigned technical repair.</span></li>";
    renderPlannedParts(plannedParts);
    renderIssuedParts(issuedParts);
    setWorkState(recordResponse.data);
  }

  async function loadQueue() {
    const selectedId = stepSelect.value;
    const { data, error } = await getClient()
      .from("job_work_order_steps")
      .select("id, step_order, rework_count, assigned_technician_name, work_order:job_work_orders!inner(work_order_number, job:jobs!inner(id, job_number, current_status, supplier_grade, supplier:suppliers(supplier_code, company_name), device:devices(device_number, imei_1, model, storage_gb, color, original_grade)))")
      .eq("department", "laboratory")
      .eq("step_status", "in_progress")
      .order("created_at", { ascending: true });
    if (error) throw error;
    queueSteps = (data || []).filter((step) => ["laboratory_pending", "laboratory_in_progress"].includes(getJob(step)?.current_status));
    queueCount.textContent = `${queueSteps.length} waiting`;
    stepSelect.replaceChildren(new Option(queueSteps.length ? "Select a Laboratory work order" : "No Laboratory jobs waiting", ""));
    queueSteps.forEach((step) => {
      const job = getJob(step) || {};
      const device = getDevice(step) || {};
      const supplier = getSupplier(job) || {};
      stepSelect.add(new Option(`${supplierLabel(supplier)} · ${job.job_number} · ${device.device_number || "Device"} · ${device.brand || "Unknown"} ${device.model || ""}`.trim(), step.id));
    });
    emptyState.hidden = queueSteps.length !== 0;
    if (selectedId && queueSteps.some((step) => step.id === selectedId)) {
      stepSelect.value = selectedId;
      await loadSelectedStep();
    } else {
      stepSelect.value = "";
      selectedStep = undefined;
      workspace.hidden = true;
      setMessage();
    }
  }

  function selectScannedImei() {
    const identifier = imeiScan.value.trim();
    if (!identifier) return;
    const match = queueSteps.find((step) => {
      const device = getDevice(step) || {};
      return device.imei_1 === identifier || String(device.device_number || "").toUpperCase() === identifier.toUpperCase();
    });
    if (!match) {
      setMessage("This IMEI is not currently waiting in the Laboratory queue.");
      return;
    }
    stepSelect.value = match.id;
    loadSelectedStep().catch((error) => setMessage(error.message || "Could not load this Laboratory job."));
  }

  async function runAction(button, label, rpcName) {
    if (!selectedStep) return null;
    setMessage();
    setSubmitting(button, true, label);
    const { data, error } = await getClient().rpc(rpcName, { p_work_order_step_id: selectedStep.id });
    setSubmitting(button, false);
    if (error) { setMessage(error.message || "Laboratory action could not be saved."); return null; }
    return data?.[0];
  }

  async function startWork() {
    const result = await runAction(startButton, "Starting...", "start_laboratory_work");
    if (result) { showToast("Laboratory work started."); await loadSelectedStep(); }
  }

  async function pauseWork() {
    const result = await runAction(pauseButton, "Pausing...", "pause_laboratory_work");
    if (result) { showToast("Laboratory work paused."); await loadSelectedStep(); }
  }

  async function resumeWork() {
    const result = await runAction(resumeButton, "Resuming...", "resume_laboratory_work");
    if (result) { showToast("Laboratory work resumed."); await loadSelectedStep(); }
  }

  async function completeWork(event) {
    event.preventDefault();
    setMessage();
    if (!selectedStep || !currentRecord?.started_at || currentRecord?.paused_at) return;
    const workDoneInput = document.querySelector("#lab-work-done");
    if (!workDoneInput.value.trim()) workDoneInput.value = "Laboratory work completed";
    if (!form.checkValidity()) { form.reportValidity(); return; }
    setSubmitting(completeButton, true, "Completing...");
    const { data, error } = await getClient().rpc("complete_laboratory_work", {
      p_work_order_step_id: selectedStep.id,
      p_work_done: workDoneInput.value,
      p_material_cost: Number(document.querySelector("#lab-material-cost").value || 0),
      p_notes: document.querySelector("#lab-notes").value
    });
    setSubmitting(completeButton, false);
    if (error) { setMessage(error.message || "Laboratory work could not be completed."); return; }
    const result = data?.[0];
    showToast(`Laboratory work completed. Active time: ${secondsToClock(result?.active_seconds)}. Next: ${String(result?.next_department || "next department").replaceAll("_", " ")}.`);
    await loadQueue();
  }

  async function handlePartAction(event) {
    const installButton = event.target.closest("[data-install-part]");
    const returnButton = event.target.closest("[data-return-part]");
    if (!installButton && !returnButton) return;
    if (!selectedStep) return;
    const issueId = (installButton || returnButton).dataset.installPart || (installButton || returnButton).dataset.returnPart;
    const quantityInput = partsList.querySelector(`[data-issue-quantity="${issueId}"]`);
    const quantity = Number(quantityInput?.value);
    if (!Number.isInteger(quantity) || quantity < 1) { setMessage("Enter a valid part quantity."); return; }
    const button = installButton || returnButton;
    button.disabled = true;
    const rpcName = installButton ? "record_part_installation" : "return_unused_part";
    const args = installButton
      ? { p_part_issue_id: issueId, p_quantity: quantity, p_notes: null }
      : { p_part_issue_id: issueId, p_quantity: quantity, p_notes: null };
    const { error } = await getClient().rpc(rpcName, args);
    button.disabled = false;
    if (error) { setMessage(error.message || "Part action could not be saved."); return; }
    showToast(installButton ? "Installed part recorded." : "Unused part returned to Parts inventory.");
    await loadSelectedStep();
  }

  async function requestAdditionalPart(event) {
    event.preventDefault();
    if (!selectedStep) return;
    const name = document.querySelector("#additional-part-name").value.trim();
    const quantity = Number(document.querySelector("#additional-part-quantity").value);
    if (!name || !Number.isInteger(quantity) || quantity < 1) { setMessage("Enter an additional part name and valid quantity."); return; }
    const button = document.querySelector("#additional-part-button");
    setSubmitting(button, true, "Requesting...");
    const { error } = await getClient().rpc("request_additional_part", {
      p_job_id: getJob(selectedStep).id,
      p_part_name: name,
      p_quantity: quantity,
      p_notes: document.querySelector("#additional-part-notes").value
    });
    setSubmitting(button, false);
    if (error) { setMessage(error.message || "The additional part request could not be created."); return; }
    document.querySelector("#additional-part-name").value = "";
    document.querySelector("#additional-part-notes").value = "";
    document.querySelector("#additional-part-quantity").value = 1;
    showToast("Additional part requested from Laboratory. The mobile remains in Laboratory.");
    await loadSelectedStep();
  }

  async function handlePlannedPartAction(event) {
    const requestButton = event.target.closest("[data-request-planned-part]");
    const skipButton = event.target.closest("[data-skip-planned-part]");
    if (!requestButton && !skipButton) return;

    const button = requestButton || skipButton;
    const requirementId = requestButton
      ? requestButton.dataset.requestPlannedPart
      : skipButton.dataset.skipPlannedPart;
    const rpcName = requestButton
      ? "request_initial_qc_part_from_lab"
      : "mark_initial_qc_part_not_required";

    setMessage();
    setSubmitting(button, true, requestButton ? "Requesting..." : "Saving...");
    const { error } = await getClient().rpc(rpcName, { p_requirement_id: requirementId });
    setSubmitting(button, false);
    if (error) {
      setMessage(error.message || "The Initial QC part could not be reviewed.");
      return;
    }

    showToast(requestButton
      ? "Part requested from Laboratory. It is now visible to the Parts Department."
      : "Part marked as not required by Laboratory.");
    await loadSelectedStep();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canWork, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "technician"] });
    if (error) throw error;
    if (!canWork) {
      permissionMessage.textContent = "Your account does not have Laboratory permission.";
      permissionMessage.hidden = false;
      return;
    }
    app.hidden = false;
    await loadQueue();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelectorAll(".module-link").forEach((button) => button.addEventListener("click", () => showToast(`${button.dataset.module} will be added in the next workflow steps.`)));
  document.querySelector("#refresh-queue").addEventListener("click", () => loadQueue().catch((error) => showToast(error.message || "Could not refresh the queue.")));
  stepSelect.addEventListener("change", () => loadSelectedStep().catch((error) => setMessage(error.message || "Could not load this Laboratory job.")));
  imeiScan.addEventListener("input", () => { if (/^\d{15}$/.test(imeiScan.value.trim())) selectScannedImei(); });
  imeiScan.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); selectScannedImei(); } });
  startButton.addEventListener("click", startWork);
  pauseButton.addEventListener("click", pauseWork);
  resumeButton.addEventListener("click", resumeWork);
  form.addEventListener("submit", completeWork);
  plannedPartsList.addEventListener("click", handlePlannedPartAction);
  partsList.addEventListener("click", handlePartAction);
  document.querySelector("#additional-part-button").addEventListener("click", requestAdditionalPart);
  initialize().catch((error) => { permissionMessage.textContent = error.message || "Laboratory could not be loaded."; permissionMessage.hidden = false; });
})();
