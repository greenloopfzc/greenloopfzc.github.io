(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#stock-out-app");
  const permissionMessage = document.querySelector("#permission-message");
  const jobSelect = document.querySelector("#stock-out-job-select");
  const queueCount = document.querySelector("#queue-count");
  const emptyState = document.querySelector("#stock-out-empty");
  const workspace = document.querySelector("#stock-out-workspace");
  const deviceSummary = document.querySelector("#stock-out-device-summary");
  const form = document.querySelector("#stock-out-form");
  const typeField = document.querySelector("#stock-out-type");
  const destinationField = document.querySelector("#stock-out-destination");
  const recipientField = document.querySelector("#stock-out-recipient");
  const referenceField = document.querySelector("#stock-out-reference");
  const notesField = document.querySelector("#stock-out-notes");
  const destinationLabel = document.querySelector("#destination-label");
  const recipientLabel = document.querySelector("#recipient-label");
  const referenceLabel = document.querySelector("#reference-label");
  const outcomeTitle = document.querySelector("#outcome-title");
  const outcomeText = document.querySelector("#outcome-text");
  const message = document.querySelector("#stock-out-message");
  const completeButton = document.querySelector("#complete-stock-out");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  let client;
  let queueJobs = [];
  let selectedJob;
  let toastTimer;

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function escapeHtml(value) {
    return String(value || "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
  }

  function relation(value) {
    return Array.isArray(value) ? value[0] : value;
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function showToast(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 4200);
  }

  function setMessage(text = "") {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
  }

  function setSubmitting(isSubmitting) {
    completeButton.disabled = isSubmitting;
    if (isSubmitting) completeButton.dataset.originalLabel = completeButton.textContent.trim();
    completeButton.textContent = isSubmitting ? "Saving dispatch..." : completeButton.dataset.originalLabel || "Confirm Stock Out →";
  }

  function updateRouteCopy(fillDefaults = false) {
    const customer = relation(selectedJob?.customer);
    const customerName = customer?.company_name || "Customer";
    const type = typeField.value;
    const descriptions = {
      export: {
        destination: "Export destination",
        recipient: "Recipient / contact",
        reference: "Shipment reference",
        outcome: "Export shipment",
        text: "The device will be marked as Shipped and moved to Outbound / Dispatched.",
        destinationValue: "",
        recipientValue: ""
      },
      customer_return: {
        destination: "Customer return destination",
        recipient: "Customer contact",
        reference: "Return reference",
        outcome: "Customer return",
        text: "The device will be marked as Returned to Customer and moved to Outbound / Dispatched.",
        destinationValue: customerName,
        recipientValue: customer?.contact_name || ""
      },
      retail_shop: {
        destination: "Retail shop destination",
        recipient: "Receiving staff",
        reference: "Transfer reference",
        outcome: "Retail shop transfer",
        text: "The device will become Shop Stock and move to the Greenloop Retail Shop location.",
        destinationValue: "Greenloop Retail Shop",
        recipientValue: ""
      }
    };
    const route = descriptions[type];
    destinationLabel.innerHTML = `${route.destination} <span class="required-mark">Required</span>`;
    recipientLabel.textContent = route.recipient;
    referenceLabel.textContent = route.reference;
    outcomeTitle.textContent = route.outcome;
    outcomeText.textContent = route.text;
    if (fillDefaults) {
      destinationField.value = route.destinationValue;
      recipientField.value = route.recipientValue;
      referenceField.value = "";
      notesField.value = "";
    }
  }

  function renderSelectedJob() {
    selectedJob = queueJobs.find((job) => job.id === jobSelect.value);
    workspace.hidden = !selectedJob;
    setMessage();
    if (!selectedJob) return;

    const device = relation(selectedJob.device) || {};
    const customer = relation(selectedJob.customer);
    const details = [device.brand, device.model, device.original_grade ? `Grade ${device.original_grade}` : ""].filter(Boolean).join(" · ");
    deviceSummary.innerHTML = `
      <div><p class="panel-kicker">Selected device</p><h2>${escapeHtml(device.device_number || "Device")}</h2><p>${escapeHtml(details || "No model details recorded")}</p></div>
      <dl>
        <div><dt>Job</dt><dd>${escapeHtml(selectedJob.job_number)}</dd></div>
        <div><dt>IMEI</dt><dd>${escapeHtml(device.imei_1 || "—")}</dd></div>
        <div><dt>Customer</dt><dd>${escapeHtml(customer?.company_name || "Company owned")}</dd></div>
      </dl>`;
    typeField.querySelector('option[value="customer_return"]').disabled = !customer;
    typeField.value = "export";
    updateRouteCopy(true);
  }

  async function loadQueue() {
    const selectedId = jobSelect.value;
    const { data, error } = await getClient()
      .from("jobs")
      .select("id,job_number,customer:customers(company_name,contact_name,customer_code),device:devices(device_number,imei_1,brand,model,original_grade)")
      .eq("current_status", "ready_for_shipment")
      .is("deleted_at", null)
      .order("received_at", { ascending: true });
    if (error) throw error;

    queueJobs = data || [];
    queueCount.textContent = `${queueJobs.length} waiting`;
    jobSelect.replaceChildren(new Option(queueJobs.length ? "Select a device for Stock Out" : "No Stock Out jobs waiting", ""));
    queueJobs.forEach((job) => {
      const device = relation(job.device) || {};
      jobSelect.add(new Option(`${job.job_number} · ${device.device_number || "Device"} · ${device.brand || "Unknown"} ${device.model || ""}`.trim(), job.id));
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

  async function completeStockOut(event) {
    event.preventDefault();
    setMessage();
    if (!selectedJob || !form.reportValidity()) return;

    setSubmitting(true);
    const { data, error } = await getClient().rpc("complete_stock_out", {
      p_job_id: selectedJob.id,
      p_stock_out_type: typeField.value,
      p_destination: destinationField.value,
      p_recipient_name: recipientField.value,
      p_shipment_reference: referenceField.value,
      p_notes: notesField.value
    });
    setSubmitting(false);

    if (error) {
      setMessage(error.message || "Stock Out could not be completed.");
      return;
    }

    const record = data?.[0];
    showToast(`Stock Out completed: ${record?.stock_out_number || "dispatch saved"}.`);
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

    const { data: canWork, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner", "manager", "shipping"] });
    if (error) throw error;
    if (!canWork) {
      permissionMessage.textContent = "Your account does not have Stock Out permission.";
      permissionMessage.hidden = false;
      return;
    }

    app.hidden = false;
    await loadQueue();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-queue").addEventListener("click", () => loadQueue().catch((error) => showToast(error.message || "Could not refresh the queue.")));
  jobSelect.addEventListener("change", renderSelectedJob);
  typeField.addEventListener("change", () => updateRouteCopy(true));
  form.addEventListener("submit", completeStockOut);
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Stock Out could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
