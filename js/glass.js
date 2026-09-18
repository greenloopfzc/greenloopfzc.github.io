(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#glass-app");
  const permissionMessage = document.querySelector("#permission-message");
  const stepSelect = document.querySelector("#glass-step-select");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#glass-empty");
  const workspace = document.querySelector("#glass-workspace");
  const deviceSummary = document.querySelector("#glass-device-summary");
  const findingsList = document.querySelector("#glass-findings");
  const form = document.querySelector("#glass-form");
  const message = document.querySelector("#glass-message");
  const startButton = document.querySelector("#start-glass-work");
  const completeButton = document.querySelector("#complete-glass-work");
  const statusTitle = document.querySelector("#glass-status-title");
  const statusText = document.querySelector("#glass-status-text");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let queueSteps = [];
  let selectedStep;
  let isStarted = false;
  let toastTimer;
  let selectionVersion = 0;
  let workBusy = false;

  function getClient() {
    if (!client) client = window.GREENLOOP_GET_CLIENT();
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
    toastTimer = window.setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3400);
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

  function getWorkOrder(step) {
    return Array.isArray(step.work_order) ? step.work_order[0] : step.work_order;
  }

  function getJob(step) {
    const workOrder = getWorkOrder(step) || {};
    return Array.isArray(workOrder.job) ? workOrder.job[0] : workOrder.job;
  }

  function getDevice(step) {
    const job = getJob(step) || {};
    return Array.isArray(job.device) ? job.device[0] : job.device;
  }

  function setWorkState(started, startedAt) {
    isStarted = started;
    startButton.hidden = started;
    completeButton.disabled = !started;
    statusTitle.textContent = started ? "Work in progress" : "Ready to start";
    statusText.textContent = started
      ? `Started ${startedAt ? new Date(startedAt).toLocaleString() : "just now"}. Complete the record when all Glass work is finished.`
      : "Start the work to record the assigned worker and automatic start time.";
  }

  async function loadFindings(jobId) {
    const { data, error } = await getClient()
      .from("initial_qc_inspections")
      .select("id, initial_qc_findings(check_item, action_required, department, priority, notes)")
      .eq("job_id", jobId)
      .maybeSingle();

    if (error) throw error;
    const allFindings = data?.initial_qc_findings || [];
    return allFindings.filter((finding) => finding.department === "glass" || !finding.department);
  }

  async function loadSelectedStep() {
    const version = ++selectionVersion;
    const step = queueSteps.find((item) => item.id === stepSelect.value);
    selectedStep = undefined;
    isStarted = false;
    startButton.disabled = true;
    completeButton.disabled = true;
    workspace.hidden = !step;
    setMessage();
    form.reset();
    if (!step) return;

    const job = getJob(step) || {};
    const device = getDevice(step) || {};
    const workOrder = getWorkOrder(step) || {};
    const details = [device.brand, device.model, device.original_grade ? `Grade ${device.original_grade}` : ""].filter(Boolean).join(" - ");
    deviceSummary.innerHTML = `
      <div><p class="panel-kicker">Selected device</p><h2>${escapeHtml(device.device_number || "Device")}</h2><p>${escapeHtml(details || "No model details recorded")}</p></div>
      <dl><div><dt>Job</dt><dd>${escapeHtml(job.job_number)}</dd></div><div><dt>IMEI</dt><dd>${escapeHtml(device.imei_1 || "—")}</dd></div><div><dt>Work order</dt><dd>${escapeHtml(workOrder.work_order_number || "—")}</dd></div></dl>
    `;

    findingsList.textContent = "Loading Glass details...";
    statusTitle.textContent = "Loading job";
    statusText.textContent = "Wait for this phone’s work record to load.";
    const [findings, recordResponse] = await Promise.all([
      loadFindings(job.id),
      getClient().from("glass_work_records").select("id, started_at, completed_at").eq("work_order_step_id", step.id).maybeSingle()
    ]);
    if (version !== selectionVersion || stepSelect.value !== step.id) return;
    if (recordResponse.error) throw recordResponse.error;
    selectedStep = step;
    startButton.disabled = false;
    findingsList.innerHTML = findings.length
      ? findings.map((finding) => `<li><strong>${escapeHtml(finding.check_item)}</strong><span>${escapeHtml(finding.action_required)} - ${escapeHtml(finding.priority)} priority${finding.notes ? ` - ${escapeHtml(finding.notes)}` : ""}</span></li>`).join("")
      : "<li><strong>Glass work required</strong><span>Review the work order and complete the assigned Glass repair.</span></li>";
    setWorkState(Boolean(recordResponse.data?.started_at && !recordResponse.data?.completed_at), recordResponse.data?.started_at);
  }

  async function loadQueue() {
    if (workBusy) return;
    const selectedId = stepSelect.value;
    const version = selectionVersion;
    const { data, error } = await getClient()
      .from("job_work_order_steps")
      .select("id, step_order, work_order:job_work_orders!inner(work_order_number, job:jobs!inner(id, job_number, device:devices(device_number, imei_1, brand, model, original_grade)))")
      .eq("department", "glass")
      .eq("step_status", "in_progress")
      .order("created_at", { ascending: true });

    if (error) throw error;
    if (version !== selectionVersion || selectedId !== stepSelect.value || workBusy) return;
    queueSteps = data || [];
    queueCount.textContent = `${queueSteps.length} waiting`;
    stepSelect.replaceChildren(new Option(queueSteps.length ? "Select a Glass work order" : "No Glass jobs waiting", ""));
    queueSteps.forEach((step) => {
      const job = getJob(step) || {};
      const device = getDevice(step) || {};
      stepSelect.add(new Option(`${job.job_number} - ${device.device_number || "Device"} - ${device.brand || "Unknown"} ${device.model || ""}`.trim(), step.id));
    });
    emptyState.hidden = queueSteps.length !== 0;
    if (selectedId && queueSteps.some((step) => step.id === selectedId)) {
      stepSelect.value = selectedId;
      await loadSelectedStep();
    } else {
      stepSelect.value = "";
      selectionVersion += 1;
      selectedStep = undefined;
      isStarted = false;
      workspace.hidden = true;
      setMessage();
    }
  }

  async function runWorkAction(button, label, action) {
    if (workBusy || button.disabled || !selectedStep) return;
    workBusy = true;
    stepSelect.disabled = true;
    document.querySelector("#refresh-queue").disabled = true;
    setSubmitting(button, true, label);
    try { await action(selectedStep); }
    catch (error) { setMessage(error.message || "Glass work could not be saved."); }
    finally {
      workBusy = false;
      stepSelect.disabled = false;
      document.querySelector("#refresh-queue").disabled = false;
      setSubmitting(button, false);
      completeButton.disabled = !isStarted;
    }
  }

  async function startWork() {
    if (!selectedStep || isStarted) return;
    setMessage();
    await runWorkAction(startButton, "Starting...", async (step) => {
      const { data, error } = await getClient().rpc("start_glass_work", { p_work_order_step_id: step.id });
      if (error) throw error;
      setWorkState(true, data?.[0]?.started_at);
      showToast("Glass work started.");
    });
  }

  async function completeWork(event) {
    event.preventDefault();
    if (!selectedStep || !isStarted || workBusy) return;
    setMessage();
    if (!form.checkValidity()) { form.reportValidity(); return; }
    let completed = false;
    await runWorkAction(completeButton, "Completing...", async (step) => {
      const { data, error } = await getClient().rpc("complete_glass_work", {
        p_work_order_step_id: step.id,
        p_work_done: document.querySelector("#glass-work-done").value,
        p_material_cost: Number.parseFloat(document.querySelector("#glass-material-cost").value || "0"),
        p_notes: document.querySelector("#glass-notes").value
      });
      if (error) throw error;
      completed = true;
      selectedStep = undefined;
      isStarted = false;
      workspace.hidden = true;
      const next = data?.[0]?.next_department || "next department";
      showToast("Glass work completed. Next: " + String(next).replaceAll("_", " ") + ".");
      document.dispatchEvent(new CustomEvent("greenloop:notifications-changed"));
    });
    if (completed) await loadQueue().catch((error) => setMessage("Glass work saved. Queue refresh failed: " + error.message));
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }
    const { data: canWork, error } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner", "manager", "glass"]
    });
    if (error) throw error;
    if (!canWork) {
      permissionMessage.textContent = "Your account does not have Glass Department permission.";
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
  stepSelect.addEventListener("change", () => loadSelectedStep().catch((error) => setMessage(error.message || "Could not load this Glass job.")));
  startButton.addEventListener("click", startWork);
  form.addEventListener("submit", completeWork);

  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Glass Department could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
