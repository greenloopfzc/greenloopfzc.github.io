(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#export-box-app");
  const permissionMessage = document.querySelector("#permission-message");
  const imeiInput = document.querySelector("#export-imei");
  const message = document.querySelector("#export-message");
  const boxNumber = document.querySelector("#export-box-number");
  const boxStatus = document.querySelector("#export-box-status");
  const boxCount = document.querySelector("#export-box-count");
  const boxRemaining = document.querySelector("#export-box-remaining");
  const progressBar = document.querySelector("#export-progress-bar");
  const startNextButton = document.querySelector("#start-next-box");
  const printButton = document.querySelector("#print-box-sheet");
  const deleteBoxButton = document.querySelector("#delete-export-box");
  const tableBody = document.querySelector("#export-box-lines");
  const sheetTitle = document.querySelector("#export-sheet-title");
  const sheetDate = document.querySelector("#export-sheet-date");
  const sheetTotal = document.querySelector("#export-sheet-total");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");

  let client;
  let currentBox;
  let lines = [];
  let scanTimer;
  let toastTimer;
  let scanning = false;

  function getClient() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function asRow(data) { return Array.isArray(data) ? data[0] : data; }

  function formatDateTime(value) {
    return new Date(value || Date.now()).toLocaleString("en-GB", {
      timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit"
    });
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function setMessage(text = "", type = "error") {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
    message.classList.toggle("is-success", type === "success");
  }

  function showToast(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3400);
  }

  function render() {
    if (!currentBox) return;
    const count = lines.length;
    const isFinished = ["full", "closed"].includes(String(currentBox.box_status));

    boxNumber.textContent = currentBox.box_number || "Export Box";
    boxStatus.textContent = isFinished ? "Box finished" : "Open for scanning";
    boxCount.textContent = `${count} phone${count === 1 ? "" : "s"}`;
    boxRemaining.textContent = isFinished ? "Start a new box" : "Ready to scan";
    progressBar.style.width = count ? "100%" : "0";
    startNextButton.disabled = scanning || (!isFinished && count === 0);
    startNextButton.textContent = isFinished ? "Start next box" : "Finish box and start next";
    printButton.disabled = count === 0;
    deleteBoxButton.disabled = scanning || !currentBox.box_id;
    imeiInput.disabled = isFinished || scanning;
    sheetTitle.textContent = `${currentBox.box_number || "Export Box"} - Export packing list`;
    sheetDate.textContent = `Opened: ${formatDateTime(currentBox.opened_at)}`;
    sheetTotal.textContent = `${count} phone${count === 1 ? "" : "s"}`;

    tableBody.innerHTML = lines.length
      ? lines.map((line) => `<tr><td>${escapeHtml(line.serial_no)}</td><td>${escapeHtml(line.imei)}</td><td>${escapeHtml(line.model || "-")}</td><td>${escapeHtml(line.storage_gb ? `${line.storage_gb} GB` : "-")}</td><td>${escapeHtml(line.final_grade || "-")}</td><td>${escapeHtml(line.color || "-")}</td><td>${escapeHtml(line.box_number || currentBox.box_number)}</td></tr>`).join("")
      : '<tr><td class="export-sheet-empty" colspan="7">Scan the first Ready Stock IMEI to add it to this box.</td></tr>';
  }

  async function loadLines() {
    if (!currentBox?.box_id) return;
    const { data, error } = await getClient().rpc("get_export_box_lines", { p_box_id: currentBox.box_id });
    if (error) throw error;
    lines = Array.isArray(data) ? data : [];
    render();
  }

  async function loadCurrentBox() {
    const { data, error } = await getClient().rpc("get_or_create_open_export_box", { p_capacity: 1000000 });
    if (error) throw error;
    currentBox = asRow(data);
    if (!currentBox) throw new Error("An export box could not be opened.");
    await loadLines();
    if (!imeiInput.disabled) imeiInput.focus();
  }

  async function scanImei() {
    const imei = imeiInput.value.replace(/\D/g, "").slice(0, 15);
    imeiInput.value = imei;
    if (scanning || imei.length !== 15) return;

    scanning = true;
    setMessage();
    render();
    try {
      const { data, error } = await getClient().rpc("scan_imei_to_export_box", { p_imei: imei });
      if (error) throw error;
      const result = asRow(data);
      if (!result) throw new Error("The IMEI was not added to the export box.");

      currentBox = {
        box_id: result.box_id,
        box_number: result.box_number,
        box_status: result.box_status,
        opened_at: currentBox?.opened_at || new Date().toISOString()
      };
      imeiInput.value = "";
      await loadLines();
      setMessage(`${imei} added to ${result.box_number}. Ready Stock was updated.`, "success");
      showToast(`Phone ${result.serial_no} added to the export box.`);
    } catch (error) {
      setMessage(error.message || "This IMEI could not be added to the export box.");
      imeiInput.select();
    } finally {
      scanning = false;
      render();
      if (!imeiInput.disabled) imeiInput.focus();
    }
  }

  async function finishAndStartNext() {
    if (!currentBox) return;
    if (!lines.length && String(currentBox.box_status) === "open") return;

    if (String(currentBox.box_status) === "open") {
      const confirmed = window.confirm(`Finish ${currentBox.box_number}? Print its box sheet before starting the next box.`);
      if (!confirmed) return;
      const { error } = await getClient().rpc("close_export_box", { p_box_id: currentBox.box_id });
      if (error) throw error;
    }

    lines = [];
    await loadCurrentBox();
    setMessage(`${currentBox.box_number} is ready for scanning.`, "success");
  }

  async function deleteCurrentBox() {
    const deleteCode = window.prompt("Enter the deletion code to delete this box and return its phones to Ready Stock:");
    if (deleteCode === null) return;

    setMessage();
    deleteBoxButton.disabled = true;
    try {
      const { data, error } = await getClient().rpc("delete_export_box_with_restore", {
        p_box_id: currentBox.box_id,
        p_delete_code: deleteCode
      });
      if (error) throw error;
      const result = asRow(data);
      const restored = Number(result?.restored_items || 0);
      setMessage(`${result?.deleted_box_number || "Export box"} was deleted. ${restored} phone(s) returned to Ready Stock.`, "success");
      showToast(`${restored} phone(s) restored to Ready Stock.`);
      lines = [];
      await loadCurrentBox();
    } catch (error) {
      setMessage(error.message || "The export box could not be deleted.");
      render();
    }
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canUse, error } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner", "manager", "production", "shipping"]
    });
    if (error) throw error;
    if (!canUse) {
      permissionMessage.textContent = "Your account does not have Export Box permission.";
      permissionMessage.hidden = false;
      return;
    }
    app.hidden = false;
    await loadCurrentBox();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  imeiInput.addEventListener("input", () => {
    imeiInput.value = imeiInput.value.replace(/\D/g, "").slice(0, 15);
    clearTimeout(scanTimer);
    if (imeiInput.value.length === 15) scanTimer = setTimeout(scanImei, 180);
  });
  imeiInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); scanImei(); }
  });
  startNextButton.addEventListener("click", () => finishAndStartNext().catch((error) => setMessage(error.message || "The next export box could not be opened.")));
  printButton.addEventListener("click", () => window.print());
  deleteBoxButton.addEventListener("click", () => deleteCurrentBox());
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Export Boxes could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
