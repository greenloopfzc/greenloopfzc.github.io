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
    selectedStep = queueSteps.find((step) => step.id === stepSelect.value);
    workspace.hidden = !selectedStep;
    setMessage();
    form.reset();
    if (!selectedStep) return;

    const job = getJob(selectedStep) || {};
    const device = getDevice(selectedStep) || {};
    const workOrder = getWorkOrder(selectedStep) || {};
    const details = [device.brand, device.model, device.original_grade ? `Grade ${device.original_grade}` : ""].filter(Boolean).join(" - ");
    deviceSummary.innerHTML = `
      <div><p class="panel-kicker">Selected device</p><h2>${escapeHtml(device.device_number || "Device")}</h2><p>${escapeHtml(details || "No model details recorded")}</p></div>
      <dl><div><dt>Job</dt><dd>${escapeHtml(job.job_number)}</dd></div><div><dt>IMEI</dt><dd>${escapeHtml(device.imei_1 || "—")}</dd></div><div><dt>Work order</dt><dd>${escapeHtml(workOrder.work_order_number || "—")}</dd></div></dl>
    `;

    const [findings, recordResponse] = await Promise.all([
      loadFindings(job.id),
      getClient().from("glass_work_records").select("id, started_at, completed_at").eq("work_order_step_id", selectedStep.id).maybeSingle()
    ]);
    if (recordResponse.error) throw recordResponse.error;
    findingsList.innerHTML = findings.length
      ? findings.map((finding) => `<li><strong>${escapeHtml(finding.check_item)}</strong><span>${escapeHtml(finding.action_required)} - ${escapeHtml(finding.priority)} priority${finding.notes ? ` - ${escapeHtml(finding.notes)}` : ""}</span></li>`).join("")
      : "<li><strong>Glass work required</strong><span>Review the work order and complete the assigned Glass repair.</span></li>";
    setWorkState(Boolean(recordResponse.data?.started_at && !recordResponse.data?.completed_at), recordResponse.data?.started_at);
  }

  async function loadQueue() {
    const selectedId = stepSelect.value;
    const { data, error } = await getClient()
      .from("job_work_order_steps")
      .select("id, step_order, work_order:job_work_orders!inner(work_order_number, job:jobs!inner(id, job_number, device:devices(device_number, imei_1, brand, model, original_grade)))")
      .eq("department", "glass")
      .eq("step_status", "in_progress")
      .order("created_at", { ascending: true });

    if (error) throw error;
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
      selectedStep = undefined;
      workspace.hidden = true;
      setMessage();
    }
  }

  async function startWork() {
    if (!selectedStep || isStarted) return;
    setMessage();
    setSubmitting(startButton, true, "Starting...");
    const { data, error } = await getClient().rpc("start_glass_work", { p_work_order_step_id: selectedStep.id });
    setSubmitting(startButton, false);
    if (error) {
      setMessage(error.message || "Glass work could not be started.");
      return;
    }
    setWorkState(true, data?.[0]?.started_at);
    showToast("Glass work started.");
  }

  async function completeWork(event) {
    event.preventDefault();
    setMessage();
    if (!selectedStep || !isStarted) return;
    if (!form.checkValidity()) {
      form.reportValidity();
      return;
    }
    setSubmitting(completeButton, true, "Completing...");
    const { data, error } = await getClient().rpc("complete_glass_work", {
      p_work_order_step_id: selectedStep.id,
      p_work_done: document.querySelector("#glass-work-done").value,
      p_material_cost: Number.parseFloat(document.querySelector("#glass-material-cost").value || "0"),
      p_notes: document.querySelector("#glass-notes").value
    });
    setSubmitting(completeButton, false);
    if (error) {
      setMessage(error.message || "Glass work could not be completed.");
      return;
    }
    const next = data?.[0]?.next_department || "next department";
    showToast(`Glass work completed. Next: ${String(next).replaceAll("_", " ")}.`);
    await loadQueue();
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
