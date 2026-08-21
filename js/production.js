(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#production-app");
  const permissionMessage = document.querySelector("#permission-message");
  const jobSelect = document.querySelector("#production-job-select");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#production-empty");
  const workspace = document.querySelector("#production-workspace");
  const tableBody = document.querySelector("#production-table-body");
  const form = document.querySelector("#production-simple-form");
  const message = document.querySelector("#production-simple-message");
  const startButton = document.querySelector("#production-simple-start");
  const completeButton = document.querySelector("#production-simple-complete");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let queueJobs = [];
  let selectedJob;
  let currentRecord;
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

  function getDevice(job) { return Array.isArray(job.device) ? job.device[0] : job.device; }
  function getSupplier(job) { return Array.isArray(job.supplier) ? job.supplier[0] : job.supplier; }
  function getBatch(job) { return Array.isArray(job.receiving_batch) ? job.receiving_batch[0] : job.receiving_batch; }
  function supplierLabel(supplier, batch) { return typeof window.GREENLOOP_SUPPLIER_RECEIPT_LABEL === "function" ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(supplier?.supplier_code, batch?.planned_quantity, supplier?.company_name, "Not recorded") : (String(supplier?.supplier_code || "").trim() || "Not recorded"); }
  function setMenu(isOpen) { sidebar.classList.toggle("is-open", isOpen); backdrop.hidden = !isOpen; document.body.classList.toggle("menu-open", isOpen); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function setMessage(text = "", type = "error") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); message.classList.toggle("is-success", type === "success"); }
  function setSubmitting(button, isSubmitting, label) { button.disabled = isSubmitting; if (isSubmitting) button.dataset.originalLabel = button.textContent.trim(); button.textContent = isSubmitting ? label : button.dataset.originalLabel || button.textContent.trim(); }

  function setState(record) {
    currentRecord = record || null;
    const started = Boolean(record?.started_at && !record?.completed_at);
    startButton.hidden = started;
    completeButton.disabled = !started;
  }

  function renderSelectedJob() {
    selectedJob = queueJobs.find((job) => job.id === jobSelect.value);
    workspace.hidden = !selectedJob;
    form.reset();
    setMessage();
    if (!selectedJob) {
      tableBody.innerHTML = "";
      setState(null);
      return;
    }

    const device = getDevice(selectedJob) || {};
    const supplier = getSupplier(selectedJob) || {};
    const row = [
      device.imei_1 || "—",
      device.serial_number || "—",
      device.specification_region || "—",
      supplierLabel(supplier, getBatch(selectedJob)),
      [device.brand, device.model].filter(Boolean).join(" ") || "—",
      device.storage_gb ? `${device.storage_gb} GB` : "—",
      device.original_grade || "—"
    ];
    tableBody.innerHTML = `<tr>${row.map((value) => `<td>${escapeHtml(value)}</td>`).join("")}</tr>`;
    getClient().from("production_records").select("id, started_at, completed_at").eq("job_id", selectedJob.id).maybeSingle().then(({ data, error }) => {
      if (error) setMessage(error.message || "Production status could not be loaded.");
      else setState(data);
    });
  }

  async function loadQueue() {
    const selectedId = jobSelect.value;
    const { data, error } = await getClient()
      .from("jobs")
      .select("id, job_number, supplier:suppliers(supplier_code, company_name), receiving_batch:receiving_batches(planned_quantity), device:devices(imei_1, serial_number, specification_region, brand, model, storage_gb, original_grade)")
      .eq("current_status", "production_pending")
      .is("deleted_at", null)
      .order("received_at", { ascending: true });
    if (error) throw error;

    queueJobs = data || [];
    queueCount.textContent = `${queueJobs.length} waiting`;
    jobSelect.replaceChildren(new Option(queueJobs.length ? "Select a Production device" : "No Production jobs waiting", ""));
    queueJobs.forEach((job) => {
      const device = getDevice(job) || {};
      const supplier = getSupplier(job) || {};
      jobSelect.add(new Option(`${supplierLabel(supplier, getBatch(job))} · ${device.imei_1 || "No IMEI"} · ${device.model || "Unknown model"}`, job.id));
    });
    emptyState.hidden = queueJobs.length !== 0;
    if (selectedId && queueJobs.some((job) => job.id === selectedId)) {
      jobSelect.value = selectedId;
      renderSelectedJob();
    } else {
      jobSelect.value = "";
      selectedJob = undefined;
      workspace.hidden = true;
      setMessage();
    }
  }

  async function startProduction() {
    if (!selectedJob) return;
    setMessage();
    setSubmitting(startButton, true, "Starting...");
    const { data, error } = await getClient().rpc("start_production", { p_job_id: selectedJob.id });
    setSubmitting(startButton, false);
    if (error) {
      setMessage(error.message || "Production could not be started.");
      return;
    }
    setState({ started_at: data?.[0]?.started_at || new Date().toISOString() });
    showToast("Production started.");
  }

  async function completeProduction(event) {
    event.preventDefault();
    setMessage();
    if (!selectedJob || !currentRecord?.started_at) return;
    setSubmitting(completeButton, true, "Completing...");
    const { error } = await getClient().rpc("complete_production", {
      p_job_id: selectedJob.id,
      p_work_items: ["Production completed"],
      p_notes: null
    });
    setSubmitting(completeButton, false);
    if (error) {
      setMessage(error.message || "Production could not be completed.");
      return;
    }
    showToast("Production completed. Device moved to Packing.");
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
    const { data: canWork, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "production"] });
    if (error) throw error;
    if (!canWork) {
      permissionMessage.textContent = "Your account does not have Production permission.";
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
  jobSelect.addEventListener("change", renderSelectedJob);
  startButton.addEventListener("click", startProduction);
  form.addEventListener("submit", completeProduction);
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Production could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
