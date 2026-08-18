(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const form = document.querySelector("#receiving-form");
  const imieOneInput = document.querySelector("#imei-1");
  const ownershipInput = document.querySelector("#ownership-type");
  const jobTypeInput = document.querySelector("#job-type");
  const customerInput = document.querySelector("#customer-id");
  const supplierInput = document.querySelector("#supplier-id");
  const locationInput = document.querySelector("#receiving-location");
  const stockChannelInput = document.querySelector("#stock-channel");
  const stockChannelHelp = document.querySelector("#stock-channel-help");
  const optionalDetails = document.querySelector("#receiving-optional");
  const customerBlock = document.querySelector("#customer-block");
  const supplierBlock = document.querySelector("#supplier-block");
  const duplicateNotice = document.querySelector("#duplicate-notice");
  const formMessage = document.querySelector("#form-message");
  const receiveButton = document.querySelector("#receive-button");
  const clearButton = document.querySelector("#clear-form");
  const permissionMessage = document.querySelector("#permission-message");
  const todayStockCard = document.querySelector("#today-stock-card");
  const todayStockCount = document.querySelector("#today-stock-count");
  const todayStockList = document.querySelector("#today-stock-list");
  const dialog = document.querySelector("#contact-dialog");
  const contactForm = document.querySelector("#contact-form");
  const contactTitle = document.querySelector("#contact-dialog-title");
  const contactDescription = document.querySelector("#contact-dialog-description");
  const contactMessage = document.querySelector("#contact-message");
  const saveContactButton = document.querySelector("#save-contact");
  const toast = document.querySelector("#toast");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  let client;
  let contactKind = "supplier";
  let toastTimer;
  let imeiLookupTimer;
  let lastLoadedImei = "";

  const jobTypes = {
    company_owned: [
      ["company_refurbishment", "Company refurbishment"],
      ["direct_export", "Direct export / A+ stock"]
    ],
    customer_owned: [
      ["customer_service", "Customer service / refurbishment"],
      ["customer_export", "Customer-owned export"]
    ]
  };

  const stockChannelDetails = {
    stock_received: "Use Stock Received for normal incoming purchase stock.",
    rma_received: "RMA jobs are received from a customer and go to Initial QC. Select the RMA customer in Additional details.",
    retail_shop_received: "Use this when an existing device comes from your Retail Shop for inspection or repair.",
    retail_shop_out: "Scan an existing Final-QC-passed IMEI to move it to Retail Shop. No new job will be created."
  };

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function textOrNull(value) {
    const text = value.trim();
    return text || null;
  }

  function integerOrNull(value) {
    return value === "" ? null : Number.parseInt(value, 10);
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

  function setFormMessage(text = "", type = "error") {
    formMessage.textContent = text;
    formMessage.classList.toggle("is-visible", Boolean(text));
    formMessage.classList.toggle("is-success", type === "success");
  }

  function setContactMessage(text = "", type = "error") {
    contactMessage.textContent = text;
    contactMessage.classList.toggle("is-visible", Boolean(text));
    contactMessage.classList.toggle("is-success", type === "success");
  }

  function setSubmitting(button, isSubmitting, label) {
    button.disabled = isSubmitting;
    if (isSubmitting) button.dataset.originalLabel = button.textContent.trim();
    button.textContent = isSubmitting ? label : button.dataset.originalLabel || button.textContent.trim();
  }

  function fillSelect(select, items, placeholder, label) {
    select.replaceChildren(new Option(placeholder, ""));
    items.forEach((item) => select.add(new Option(label(item), item.id)));
  }

  const masterOptionConfig = [
    { group: "model", target: "model", placeholder: "Select model" },
    { group: "storage_gb", target: "storage-gb", placeholder: "Select storage" },
    { group: "color", target: "color", placeholder: "Select color" }
  ];

  async function loadMasterOptions(group, targetId, placeholder) {
    const select = document.querySelector(`#${targetId}`);
    const currentValue = select.value;
    const { data, error } = await getClient().rpc("get_entry_options", { p_option_group: group });
    if (error) throw error;
    select.replaceChildren(new Option(placeholder, ""));
    (data || []).forEach((item) => {
      const option = new Option(item.option_value, item.option_value);
      option.dataset.optionId = item.id;
      select.add(option);
    });
    if ([...select.options].some((option) => option.value === currentValue)) select.value = currentValue;
  }

  async function loadAllMasterOptions() {
    await Promise.all(masterOptionConfig.map((item) => loadMasterOptions(item.group, item.target, item.placeholder)));
  }

  async function addMasterOption(button) {
    const group = button.dataset.optionGroup;
    const targetId = button.dataset.optionTarget;
    const value = window.prompt(`Enter the new ${group.replaceAll("_", " ")}:`);
    if (!value?.trim()) return;
    const { data, error } = await getClient().rpc("add_entry_option", {
      p_option_group: group,
      p_option_value: value.trim()
    });
    if (error) {
      setFormMessage(error.message || "The option could not be added.");
      return;
    }
    const item = masterOptionConfig.find((option) => option.group === group && option.target === targetId);
    await loadMasterOptions(group, targetId, item.placeholder);
    document.querySelector(`#${targetId}`).value = data?.[0]?.saved_value || value.trim();
    showToast("New option saved.");
  }

  async function removeMasterOption(button) {
    const group = button.dataset.optionGroup;
    const targetId = button.dataset.optionTarget;
    const select = document.querySelector(`#${targetId}`);
    const optionId = select.selectedOptions[0]?.dataset.optionId;
    if (!optionId) {
      setFormMessage("Select an option before removing it.");
      return;
    }
    const code = window.prompt("Enter deletion code to remove this option:");
    if (code !== "1213") {
      showToast("Option was not removed. Deletion code is incorrect.");
      return;
    }
    const { error } = await getClient().rpc("delete_entry_option", {
      p_option_id: optionId,
      p_deletion_code: code
    });
    if (error) {
      setFormMessage(error.message || "The option could not be removed.");
      return;
    }
    const item = masterOptionConfig.find((option) => option.group === group && option.target === targetId);
    await loadMasterOptions(group, targetId, item.placeholder);
    showToast("Option removed.");
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function formatTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "—" : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  async function loadTodayStock() {
    const { data, error } = await getClient().rpc("get_today_stock_received");
    if (error) throw error;
    const records = data || [];
    todayStockCount.textContent = `${records.length} device${records.length === 1 ? "" : "s"}`;
    todayStockList.innerHTML = records.length
      ? records.map((record) => `<tr><td>${escapeHtml(formatTime(record.received_at))}</td><td>${escapeHtml(record.imei_1)}</td><td>${escapeHtml(record.device_number)}</td><td>${escapeHtml(record.model || "—")}</td></tr>`).join("")
      : '<tr><td colspan="4">No stock has been received today.</td></tr>';
    todayStockCard.hidden = false;
  }

  function updateJobTypes() {
    const selectedOwnership = ownershipInput.value || "company_owned";
    jobTypeInput.replaceChildren();
    jobTypes[selectedOwnership].forEach(([value, label]) => jobTypeInput.add(new Option(label, value)));

    const companyOwned = selectedOwnership === "company_owned";
    supplierBlock.hidden = !companyOwned;
    customerBlock.hidden = companyOwned;
    supplierInput.required = false;
    customerInput.required = !companyOwned;
  }

  function updateStockChannel() {
    const channel = stockChannelInput.value;
    const retailShopOut = channel === "retail_shop_out";
    const stockInputs = ["model", "storage-gb", "color", "battery-health"];

    stockChannelHelp.textContent = stockChannelDetails[channel] || stockChannelDetails.stock_received;
    stockInputs.forEach((id) => {
      const input = document.querySelector(`#${id}`);
      const field = input.closest(".form-field");
      input.disabled = retailShopOut;
      input.required = !retailShopOut;
      field.hidden = retailShopOut;
    });
    optionalDetails.hidden = retailShopOut;
    optionalDetails.querySelectorAll("input, select, textarea, button").forEach((element) => { element.disabled = retailShopOut; });

    if (retailShopOut) {
      receiveButton.textContent = "Send to Retail Shop";
      return;
    }

    optionalDetails.querySelectorAll("input, select, textarea, button").forEach((element) => { element.disabled = false; });
    if (channel === "rma_received") {
      ownershipInput.value = "customer_owned";
      optionalDetails.open = true;
    } else if (channel === "retail_shop_received") {
      ownershipInput.value = "company_owned";
    } else if (channel === "stock_received") {
      ownershipInput.value = "";
    }
    updateJobTypes();
    receiveButton.textContent = "Save stock received";
  }

  async function loadReferenceData() {
    const api = getClient();
    const [customersResponse, suppliersResponse, locationsResponse] = await Promise.all([
      api.from("customers").select("id, customer_code, company_name").order("company_name"),
      api.from("suppliers").select("id, supplier_code, company_name").order("company_name"),
      api.from("locations").select("id, location_code, location_name").order("location_name")
    ]);

    const error = customersResponse.error || suppliersResponse.error || locationsResponse.error;
    if (error) throw error;

    fillSelect(customerInput, customersResponse.data || [], "Select customer", (item) => `${item.company_name} · ${item.customer_code}`);
    fillSelect(supplierInput, suppliersResponse.data || [], "Select supplier", (item) => item.supplier_code || item.company_name);
    fillSelect(locationInput, locationsResponse.data || [], "Select location", (item) => item.location_name);

    const receivingLocation = (locationsResponse.data || []).find((location) => location.location_code === "RECEIVING");
    if (receivingLocation) locationInput.value = receivingLocation.id;
  }

  async function checkDuplicate() {
    const imei = imieOneInput.value.trim();
    duplicateNotice.hidden = true;
    duplicateNotice.textContent = "";

    if (!/^\d{15}$/.test(imei)) return;

    const { data, error } = await getClient()
      .from("devices")
      .select("device_number, model, storage_gb, color, battery_health, current_owner_type, current_owner_customer_id, current_status")
      .or(`imei_1.eq.${imei},imei_2.eq.${imei}`)
      .limit(1);

    if (error) return;
    const device = data?.[0];
    if (!device) return;

    const fields = form.elements;
    const fill = (name, value) => {
      const field = fields[name];
      if (value === null || value === undefined || !field || field.value) return;
      if (field.tagName === "SELECT" && ![...field.options].some((option) => option.value === String(value))) {
        field.add(new Option(String(value), String(value)));
      }
      field.value = value;
    };
    fill("model", device.model);
    fill("storage-gb", device.storage_gb);
    fill("color", device.color);
    fill("battery-health", device.battery_health);
    if (device.current_owner_type && ownershipInput.value !== device.current_owner_type) {
      ownershipInput.value = device.current_owner_type;
      updateJobTypes();
    }
    if (device.current_owner_type === "customer_owned" && device.current_owner_customer_id && customerInput.querySelector(`option[value="${device.current_owner_customer_id}"]`)) {
      customerInput.value = device.current_owner_customer_id;
    }
    const description = [device.model, device.storage_gb ? `${device.storage_gb} GB` : "", device.color].filter(Boolean).join(" · ");
    duplicateNotice.innerHTML = `<strong>Existing IMEI found: ${device.device_number}</strong><span>${description || "Device details not entered"} · Current status: ${device.current_status.replaceAll("_", " ")}. Device details were loaded automatically. Submitting this form will create a new job and preserve its full history.</span>`;
    duplicateNotice.hidden = false;
    if (lastLoadedImei !== imei) showToast("Existing device details loaded automatically.");
    lastLoadedImei = imei;
  }

  function clearForm() {
    form.reset();
    updateStockChannel();
    duplicateNotice.hidden = true;
    lastLoadedImei = "";
    setFormMessage();
    loadReferenceData().catch((error) => setFormMessage(error.message || "Could not reload reference data."));
    imieOneInput.focus();
  }

  function openContactDialog(kind) {
    contactKind = kind;
    contactForm.reset();
    setContactMessage();
    const label = kind === "supplier" ? "supplier" : "customer";
    contactTitle.textContent = `Add ${label}`;
    contactDescription.textContent = `Create a ${label} record without leaving Stock Received.`;
    dialog.showModal();
    document.querySelector("#contact-company").focus();
  }

  async function saveContact(event) {
    event.preventDefault();
    setContactMessage();
    if (!contactForm.checkValidity()) {
      contactForm.reportValidity();
      return;
    }

    setSubmitting(saveContactButton, true, "Saving...");
    const input = contactForm.elements;
    const fn = contactKind === "supplier" ? "create_supplier" : "create_customer";
    const { data, error } = await getClient().rpc(fn, {
      p_company_name: input["contact-company"].value,
      p_contact_name: input["contact-person"].value,
      p_phone: input["contact-phone"].value,
      p_email: input["contact-email"].value,
      p_country: input["contact-country"].value,
      p_notes: input["contact-notes"].value
    });

    if (error) {
      setContactMessage(error.message || "Could not save the contact.");
      setSubmitting(saveContactButton, false);
      return;
    }

    const contact = data?.[0];
    await loadReferenceData();
    if (contact) {
      if (contactKind === "supplier") supplierInput.value = contact.id;
      else customerInput.value = contact.id;
    }
    dialog.close();
    setSubmitting(saveContactButton, false);
    showToast(`${contactKind === "supplier" ? "Supplier" : "Customer"} saved.`);
  }

  async function submitReceiving(event) {
    event.preventDefault();
    setFormMessage();

    if (!form.checkValidity()) {
      form.reportValidity();
      return;
    }

    const imeiOne = imieOneInput.value.trim();
    if (!/^\d{15}$/.test(imeiOne)) {
      setFormMessage("IMEI must contain exactly 15 digits.");
      return;
    }

    const channel = stockChannelInput.value;
    if (channel === "retail_shop_out") {
      setSubmitting(receiveButton, true, "Sending...");
      const { data, error } = await getClient().rpc("transfer_device_to_retail_shop", {
        p_imei: imeiOne,
        p_notes: null
      });
      setSubmitting(receiveButton, false);
      if (error) {
        setFormMessage(error.message || "The device could not be sent to Retail Shop.");
        return;
      }
      const result = data?.[0];
      setFormMessage(`Device ${result?.device_number || ""} was sent to Retail Shop.`, "success");
      form.reset();
      updateStockChannel();
      imieOneInput.focus();
      return;
    }

    const input = form.elements;
    setSubmitting(receiveButton, true, "Saving...");
    const { data, error } = await getClient().rpc("create_stock_received_channel_job", {
      p_imei_1: imeiOne,
      p_model: textOrNull(input.model.value),
      p_storage_gb: integerOrNull(input["storage-gb"].value),
      p_color: textOrNull(input.color.value),
      p_battery_health: integerOrNull(input["battery-health"].value),
      p_ownership_type: input["ownership-type"].value || null,
      p_customer_id: input["customer-id"].value || null,
      p_supplier_id: input["supplier-id"].value || null,
      p_supplier_grade: input["supplier-grade"].value,
      p_gc_grade: input["gc-grade"].value,
      p_notes: textOrNull(input.notes.value),
      p_stock_channel: channel
    });

    setSubmitting(receiveButton, false);
    if (error) {
      setFormMessage(error.message || "The device could not be received.");
      return;
    }

    const result = data?.[0];
    const sourceLabel = channel === "rma_received" ? "RMA" : channel === "retail_shop_received" ? "Retail Shop" : "Stock";
    const message = result.existing_device
      ? `Existing device ${result.device_number} matched. New ${sourceLabel} job ${result.job_number} was created and sent to Initial QC.`
      : `${sourceLabel} device ${result.device_number} and job ${result.job_number} were created and sent to Initial QC.`;
    setFormMessage(message, "success");
    form.reset();
    updateStockChannel();
    duplicateNotice.hidden = true;
    await loadReferenceData();
    await loadTodayStock();
    imieOneInput.focus();
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      form.hidden = true;
      return;
    }

    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }

    const { data: hasReceivingAccess, error: accessError } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner", "manager", "receiving", "rma"]
    });

    if (accessError) throw accessError;
    if (!hasReceivingAccess) {
      permissionMessage.textContent = "Your account does not have Stock Received permission.";
      permissionMessage.hidden = false;
      form.hidden = true;
      return;
    }

    updateStockChannel();
    await Promise.all([loadReferenceData(), loadAllMasterOptions(), loadTodayStock()]);
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelectorAll(".module-link").forEach((button) => button.addEventListener("click", () => showToast(`${button.dataset.module} will be added in the next workflow steps.`)));
  ownershipInput.addEventListener("change", updateJobTypes);
  stockChannelInput.addEventListener("change", updateStockChannel);
  imieOneInput.addEventListener("input", () => {
    imieOneInput.value = imieOneInput.value.replace(/\D/g, "");
    window.clearTimeout(imeiLookupTimer);
    if (imieOneInput.value.length === 15) imeiLookupTimer = window.setTimeout(checkDuplicate, 280);
  });
  imieOneInput.addEventListener("blur", checkDuplicate);
  clearButton.addEventListener("click", clearForm);
  document.querySelectorAll(".master-add").forEach((button) => button.addEventListener("click", () => addMasterOption(button)));
  document.querySelectorAll(".master-remove").forEach((button) => button.addEventListener("click", () => removeMasterOption(button)));
  document.querySelector("#refresh-today-stock").addEventListener("click", () => loadTodayStock().catch((error) => showToast(error.message || "Today's stock could not be refreshed.")));
  document.querySelector("#add-supplier").addEventListener("click", () => openContactDialog("supplier"));
  document.querySelector("#add-customer").addEventListener("click", () => openContactDialog("customer"));
  document.querySelector("#close-contact-dialog").addEventListener("click", () => dialog.close());
  document.querySelector("#cancel-contact").addEventListener("click", () => dialog.close());
  contactForm.addEventListener("submit", saveContact);
  form.addEventListener("submit", submitReceiving);

  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Stock Received could not be loaded.";
    permissionMessage.hidden = false;
    form.hidden = true;
  });
})();
