(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#final-qc-app");
  const permissionMessage = document.querySelector("#permission-message");
  const stepSelect = document.querySelector("#final-qc-step-select");
  const imeiScan = document.querySelector("#final-qc-imei-scan");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#final-qc-empty");
  const workspace = document.querySelector("#final-qc-workspace");
  const deviceSummary = document.querySelector("#final-qc-device-summary");
  const form = document.querySelector("#final-qc-form");
  const finalGradeSelect = document.querySelector("#final-qc-grade");
  const message = document.querySelector("#final-qc-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let queueSteps = [];
  let selectedStep;
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
    }, 3600);
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

  async function loadFinalGrades(selectedValue = "") {
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: "grade" });
    if (error) throw error;
    finalGradeSelect.replaceChildren(new Option("Select final grade", ""));
    (data || []).forEach((item) => {
      const option = new Option(item.option_value, item.option_value);
      option.dataset.optionId = item.id;
      finalGradeSelect.add(option);
    });
    if (selectedValue && [...finalGradeSelect.options].some((option) => option.value === selectedValue)) {
      finalGradeSelect.value = selectedValue;
    }
  }

  async function addFinalGrade() {
    const value = window.prompt("Enter a new Final QC grade.");
    if (value === null || !value.trim()) return;
    const { data, error } = await getClient().rpc("add_entry_option", {
      p_option_group: "grade",
      p_option_value: value.trim()
    });
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    await loadFinalGrades(row?.saved_value || value.trim());
    showToast("Final QC grade is ready to use.");
  }

  async function removeFinalGrade() {
    const option = finalGradeSelect.options[finalGradeSelect.selectedIndex];
    const optionId = option?.dataset.optionId;
    if (!optionId) { setMessage("Select a Final QC grade first."); return; }
    const code = window.prompt(`Enter deletion code to remove ${option.text}.`);
    if (code === null) return;
    const { error } = await getClient().rpc("delete_entry_option", {
      p_option_id: optionId,
      p_deletion_code: code
    });
    if (error) throw error;
    await loadFinalGrades();
    showToast("Final QC grade was removed.");
  }

  function getWorkOrder(step) { return Array.isArray(step.work_order) ? step.work_order[0] : step.work_order; }
  function getJob(step) { const workOrder = getWorkOrder(step) || {}; return Array.isArray(workOrder.job) ? workOrder.job[0] : workOrder.job; }
  function getDevice(step) { const job = getJob(step) || {}; return Array.isArray(job.device) ? job.device[0] : job.device; }
  function getSupplier(job) { return Array.isArray(job?.supplier) ? job.supplier[0] : job?.supplier; }
  function supplierLabel(supplier) { return [supplier?.supplier_code, supplier?.company_name].filter((value) => String(value || "").trim()).join(" - ") || "Not recorded"; }
  function selectedResult() { return document.querySelector('#final-qc-form input[name="final-result"]:checked').value; }

  function renderWorkflow(events, jobNumber) {
    const currentJobEvents = (events || [])
      .filter((event) => String(event.job_number || "") === String(jobNumber || ""))
      .reverse();
    const titles = currentJobEvents.map((event) => String(event.title || "").trim()).filter(Boolean);

    if (!titles.length) {
      workflow.innerHTML = '<span class="workflow-empty">Stock Received → Initial QC → Laboratory → Final QC</span>';
      return;
    }

    workflow.innerHTML = titles.map((title, index) => `${index ? '<span class="workflow-arrow" aria-hidden="true">→</span>' : ""}<span class="workflow-step">${escapeHtml(title)}</span>`).join("");
  }

  async function renderSelectedStep() {
    selectedStep = queueSteps.find((step) => step.id === stepSelect.value);
    workspace.hidden = !selectedStep;
    setMessage();
    form.reset();
    if (!selectedStep) return;

    const job = getJob(selectedStep) || {};
    const device = getDevice(selectedStep) || {};
    const supplier = getSupplier(job) || {};
    const cells = [
      ["IMEI", device.imei_1 || "—"],
      ["Model", [device.brand, device.model].filter(Boolean).join(" ") || "—"],
      ["GB", device.storage_gb ? `${device.storage_gb} GB` : "—"],
      ["Color", device.color || "—"]
    ];
    cells.push(
      ["Supplier Code", supplierLabel(supplier)],
      ["Supplier Grade", job.supplier_grade || "Not recorded"],
      ["Initial Grade", device.gc_grade || "Not recorded"]
    );
    deviceSummary.innerHTML = cells.map(([label, value]) => `<div class="final-qc-summary-cell"><span class="final-qc-cell-label">${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
    return;
    workflow.innerHTML = '<span class="workflow-empty">Loading workflow history…</span>';

    const { data, error } = await getClient().rpc("search_imei_history", { p_imei: device.imei_1 });
    if (error) {
      renderWorkflow([], job.job_number);
      return;
    }
    const history = Array.isArray(data) ? data[0] : data;
    renderWorkflow(history?.events, job.job_number);
  }

  async function loadQueue() {
    const selectedId = stepSelect.value;
    const { data, error } = await getClient()
      .from("job_work_order_steps")
      .select("id, work_order:job_work_orders!inner(work_order_number, job:jobs!inner(id, job_number, supplier_grade, supplier:suppliers(supplier_code, company_name), device:devices(device_number, imei_1, brand, model, storage_gb, color, gc_grade)))")
      .eq("department", "final_qc")
      .eq("step_status", "in_progress")
      .order("created_at", { ascending: true });

    if (error) throw error;
    queueSteps = data || [];
    queueCount.textContent = `${queueSteps.length} waiting`;
    stepSelect.replaceChildren(new Option(queueSteps.length ? "Select a Final QC job" : "No Final QC jobs waiting", ""));
    queueSteps.forEach((step) => {
      const job = getJob(step) || {};
      const device = getDevice(step) || {};
      const supplier = getSupplier(job) || {};
      stepSelect.add(new Option(`${supplierLabel(supplier)} · ${job.job_number} · ${device.imei_1 || device.device_number || "Device"}`, step.id));
    });
    emptyState.hidden = queueSteps.length !== 0;
    if (queueSteps.some((step) => step.id === selectedId)) stepSelect.value = selectedId;
    else if (queueSteps.length) stepSelect.value = queueSteps[0].id;
    await renderSelectedStep();
  }

  function selectScannedImei() {
    const identifier = imeiScan.value.trim();
    if (!identifier) return;
    const match = queueSteps.find((step) => {
      const device = getDevice(step) || {};
      return device.imei_1 === identifier || String(device.device_number || "").toUpperCase() === identifier.toUpperCase();
    });
    if (!match) {
      setMessage("This IMEI is not currently waiting in the Final QC queue.");
      return;
    }
    stepSelect.value = match.id;
    renderSelectedStep().catch((error) => setMessage(error.message || "Could not load this Final QC job."));
  }

  async function submitFinalQc(event) {
    event.preventDefault();
    setMessage();
    if (!selectedStep) return;

    const result = selectedResult();
    const finalGrade = document.querySelector("#final-qc-grade").value;
    if (result === "pass" && !finalGrade) {
      setMessage("Select the Final Grade before passing this device to Production.");
      return;
    }
    const button = document.querySelector("#complete-final-qc");
    setSubmitting(button, true, "Saving...");
    const { data, error } = await getClient().rpc("complete_final_qc_with_final_grade", {
      p_job_id: getJob(selectedStep).id,
      p_result: result,
      p_final_grade: result === "pass" ? finalGrade : null,
      p_notes: result === "pass" ? "Final QC passed" : "Final QC failed",
      p_failure_department: result === "fail" ? "laboratory" : null,
      p_failure_reason: result === "fail" ? "Final QC failed - return to Laboratory" : null,
      p_checks: []
    });
    setSubmitting(button, false);

    if (error) {
      setMessage(error.message || "Final QC could not be completed.");
      return;
    }

    const response = data?.[0];
    const text = result === "pass"
      ? `Final QC attempt ${response?.attempt_number} passed. Loading the next IMEI.`
      : `Final QC attempt ${response?.attempt_number} failed. Device returned to Laboratory for rework.`;
    showToast(text);
    if (result === "pass") {
      imeiScan.value = "";
      await loadQueue();
      return;
    }
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
    const { data: canInspect, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "final_qc"] });
    if (error) throw error;
    if (!canInspect) {
      permissionMessage.textContent = "Your account does not have Final QC permission.";
      permissionMessage.hidden = false;
      return;
    }
    app.hidden = false;
    await loadFinalGrades();
    await loadQueue();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelectorAll(".module-link").forEach((button) => button.addEventListener("click", () => showToast(`${button.dataset.module} will be added in the next workflow steps.`)));
  document.querySelector("#refresh-queue").addEventListener("click", () => loadQueue().catch((error) => showToast(error.message || "Could not refresh the queue.")));
  stepSelect.addEventListener("change", () => renderSelectedStep().catch((error) => setMessage(error.message || "Final QC job could not be loaded.")));
  imeiScan.addEventListener("input", () => { if (/^\d{15}$/.test(imeiScan.value.trim())) selectScannedImei(); });
  imeiScan.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); selectScannedImei(); } });
  document.querySelector("#add-final-grade").addEventListener("click", () => addFinalGrade().catch((error) => setMessage(error.message || "Final QC grade could not be added.")));
  document.querySelector("#remove-final-grade").addEventListener("click", () => removeFinalGrade().catch((error) => setMessage(error.message || "Final QC grade could not be removed.")));
  form.addEventListener("submit", submitFinalQc);
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Final QC could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
