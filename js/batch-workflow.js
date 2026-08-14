(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  let client;

  function api() {
    if (!client) client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey);
    return client;
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function optionsHtml(select, selectedValue = "") {
    const values = [...select.options].filter((option) => option.value);
    const chosen = String(selectedValue ?? "");
    return `<option value="">Select</option>${values.map((option) => `<option value="${escapeHtml(option.value)}"${String(option.value) === chosen ? " selected" : ""}>${escapeHtml(option.text)}</option>`).join("")}`;
  }

  function makeSlots(batch) {
    const slots = [];
    const lines = Array.isArray(batch.planned_lines) ? batch.planned_lines : [];
    lines.forEach((line) => {
      const remaining = Math.max(0, Number(line.remaining_quantity || 0));
      for (let index = 0; index < remaining; index += 1) {
        slots.push({ model: line.model || "", storage: line.storage_gb || "", color: line.color || "" });
      }
    });
    const totalRemaining = Math.max(0, Number(batch.remaining_quantity || 0));
    while (slots.length < totalRemaining) slots.push({ model: "", storage: "", color: "" });
    return slots.slice(0, totalRemaining);
  }

  async function initialiseBatchEntry() {
    const batchSelect = document.querySelector("#stock-batch");
    const originalPanel = document.querySelector("#imei-detail-panel");
    const originalActions = document.querySelector("#imei-actions");
    const modelMaster = document.querySelector("#model");
    const storageMaster = document.querySelector("#storage-gb");
    const colorMaster = document.querySelector("#color");
    if (!batchSelect || !originalPanel || !modelMaster || !storageMaster || !colorMaster) return;

    const panel = document.createElement("section");
    panel.id = "batch-entry-panel";
    panel.className = "form-panel batch-entry-panel";
    panel.hidden = true;
    originalPanel.insertAdjacentElement("afterend", panel);

    const label = document.createElement("div");
    label.className = "single-entry-heading";
    label.textContent = "Single IMEI entry and dropdown management";
    panel.insertAdjacentElement("beforebegin", label);
    label.hidden = true;

    let currentBatch;
    let slots = [];

    function setSelectValue(select, value) {
      const cleaned = String(value ?? "").trim();
      if (!cleaned) return false;
      let option = [...select.options].find((item) => String(item.value).trim().toLocaleLowerCase() === cleaned.toLocaleLowerCase());
      if (!option) {
        option = new Option(cleaned, cleaned);
        select.add(option);
      }
      select.value = option.value;
      return true;
    }

    function loadCableDeviceIntoRow(device) {
      if (panel.hidden || !currentBatch) return;
      const focusedRow = document.activeElement?.closest?.("#batch-entry-panel tbody tr");
      const row = (focusedRow?.dataset.saved !== "yes" ? focusedRow : null)
        || [...panel.querySelectorAll("tbody tr")].find((item) => item.dataset.saved !== "yes" && !item.querySelector(".batch-row-imei").value.trim());
      if (!row) return;

      const scannedImei = String(device?.imei || "").replace(/\D/g, "");
      const batteryHealth = Number.parseInt(String(device?.batteryHealth || "").replace(/\D/g, ""), 10);
      if (/^\d{15}$/.test(scannedImei)) row.querySelector(".batch-row-imei").value = scannedImei;
      setSelectValue(row.querySelector(".batch-row-model"), device?.model);
      if (Number(device?.storageGb) > 0) setSelectValue(row.querySelector(".batch-row-storage"), String(Number(device.storageGb)));
      setSelectValue(row.querySelector(".batch-row-color"), device?.color);
      if (Number.isInteger(batteryHealth) && batteryHealth >= 1 && batteryHealth <= 100) row.querySelector(".batch-row-battery").value = String(batteryHealth);

      const missing = [];
      if (!/^\d{15}$/.test(scannedImei)) missing.push("IMEI");
      if (!row.querySelector(".batch-row-model").value) missing.push("Model");
      if (!row.querySelector(".batch-row-storage").value) missing.push("GB");
      if (!row.querySelector(".batch-row-color").value) missing.push("Color");
      if (!row.querySelector(".batch-row-battery").value) missing.push("Battery Health");
      if (missing.length) {
        setRowStatus(row, `Cable read incomplete: ${missing.join(", ")}`, "is-error");
        row.querySelector(".batch-row-battery").focus();
        return;
      }
      setRowStatus(row, "Cable data loaded", "is-saving");
      saveRow(row);
    }

    window.addEventListener("greenloop:cable-device", (event) => loadCableDeviceIntoRow(event.detail || {}));

    function setRowStatus(row, text, state = "") {
      const status = row.querySelector(".batch-row-status");
      status.textContent = text;
      status.className = `batch-row-status${state ? ` ${state}` : ""}`;
    }

    async function reloadOptionGroup(group, preferredValue = "") {
      const masterByGroup = { model: modelMaster, storage_gb: storageMaster, color: colorMaster };
      const classByGroup = { model: ".batch-row-model", storage_gb: ".batch-row-storage", color: ".batch-row-color" };
      const master = masterByGroup[group];
      const rowSelects = [...panel.querySelectorAll(classByGroup[group])];
      const preserved = rowSelects.map((select) => select.value);
      const { data, error } = await api().rpc("get_entry_options", { p_option_group: group });
      if (error) throw error;
      const items = data || [];
      const fill = (select, chosen) => {
        select.replaceChildren(new Option("Select", ""));
        items.forEach((item) => {
          const option = new Option(item.option_value, item.option_value);
          option.dataset.optionId = item.id;
          select.add(option);
        });
        if ([...select.options].some((option) => option.value === String(chosen || ""))) select.value = String(chosen);
      };
      fill(master, preferredValue || master.value);
      rowSelects.forEach((select, index) => fill(select, preferredValue || preserved[index]));
    }

    async function addRowOption(button) {
      const group = button.dataset.optionGroup;
      const value = window.prompt(`Enter the new ${group.replaceAll("_", " ")}:`);
      if (!value?.trim()) return;
      const { data, error } = await api().rpc("add_entry_option", { p_option_group: group, p_option_value: value.trim() });
      if (error) { window.alert(error.message || "The option could not be added."); return; }
      await reloadOptionGroup(group, data?.[0]?.saved_value || value.trim());
    }

    async function removeRowOption(button) {
      const group = button.dataset.optionGroup;
      const select = button.closest(".batch-option-control").querySelector("select");
      if (!select.value) { window.alert("Select an option first."); return; }
      const { data, error: loadError } = await api().rpc("get_entry_options", { p_option_group: group });
      if (loadError) { window.alert(loadError.message); return; }
      const item = (data || []).find((entry) => String(entry.option_value).trim().toLocaleLowerCase() === String(select.value).trim().toLocaleLowerCase());
      if (!item) { window.alert("This option could not be found."); return; }
      const code = window.prompt("Enter deletion code to remove this option:");
      if (code !== "1213") return;
      const { error } = await api().rpc("delete_entry_option", { p_option_id: item.id, p_deletion_code: code });
      if (error) { window.alert(error.message || "The option could not be removed."); return; }
      await reloadOptionGroup(group);
    }

    function fillBlankSelectionsFromPreviousRow() {
      [".batch-row-model", ".batch-row-storage", ".batch-row-color"].forEach((selector) => {
        const templateValue = panel.querySelector(`tbody tr:first-child ${selector}`)?.value || "";
        panel.querySelectorAll(selector).forEach((select) => {
          if (!select.value && templateValue) select.value = templateValue;
        });
      });
    }

    function continueSelectionToFollowingRows(sourceSelect) {
      const sourceRow = sourceSelect.closest("tr");
      const templateRow = panel.querySelector("tbody tr:first-child");
      // Only line 1 is the template. A correction on line 2 or later belongs
      // to that phone only and must never overwrite the phones below it.
      if (!sourceRow || sourceRow !== templateRow) return;
      const selector = sourceSelect.classList.contains("batch-row-model")
        ? ".batch-row-model"
        : sourceSelect.classList.contains("batch-row-storage")
          ? ".batch-row-storage"
          : ".batch-row-color";
      let nextRow = sourceRow.nextElementSibling;

      while (nextRow) {
        const nextSelect = nextRow.querySelector(selector);
        if (!nextSelect) break;
        if (nextSelect.dataset.manuallyChanged !== "yes" && nextRow.dataset.saved !== "yes") nextSelect.value = sourceSelect.value;
        nextRow = nextRow.nextElementSibling;
      }
    }

    function renderRows() {
      if (!currentBatch) {
        panel.hidden = true;
        label.hidden = true;
        return;
      }
      panel.hidden = false;
      label.hidden = false;
      panel.innerHTML = `
        <div class="form-panel-heading batch-entry-heading">
          <span class="section-number">02</span>
          <div><h2>Bulk IMEI entry</h2><p>One editable line is shown for every phone remaining in this supplier batch.</p></div>
          <span class="batch-entry-count">${slots.length} lines</span>
        </div>
        <div class="batch-table-scroll">
          <table class="batch-entry-table">
            <thead><tr><th>#</th><th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>Battery Health</th><th>Save</th><th>Status</th></tr></thead>
            <tbody>${slots.map((slot, index) => `
              <tr data-index="${index}">
                <td>${index + 1}</td>
                <td><input class="batch-row-imei" inputmode="numeric" autocomplete="off" maxlength="15" placeholder="Scan IMEI"></td>
                <td><div class="batch-option-control"><select class="batch-row-model">${optionsHtml(modelMaster, slot.model)}</select><button type="button" class="batch-option-add" data-option-group="model">+</button><button type="button" class="batch-option-remove" data-option-group="model">−</button></div></td>
                <td><div class="batch-option-control"><select class="batch-row-storage">${optionsHtml(storageMaster, String(slot.storage || ""))}</select><button type="button" class="batch-option-add" data-option-group="storage_gb">+</button><button type="button" class="batch-option-remove" data-option-group="storage_gb">−</button></div></td>
                <td><div class="batch-option-control"><select class="batch-row-color">${optionsHtml(colorMaster, slot.color)}</select><button type="button" class="batch-option-add" data-option-group="color">+</button><button type="button" class="batch-option-remove" data-option-group="color">−</button></div></td>
                <td><input class="batch-row-battery" type="number" min="0" max="100" inputmode="numeric" placeholder="BH %"></td>
                <td><button class="batch-save-button" type="button">Save</button></td>
                <td class="batch-row-status">Waiting</td>
              </tr>`).join("")}</tbody>
          </table>
        </div>
        <p class="batch-entry-help">Line 1 sets the default Model, GB and Color for the remaining lines. Any change on line 2 or later applies only to that phone. IMEI and Battery Health always remain blank for each phone.</p>`;

      fillBlankSelectionsFromPreviousRow();

      panel.querySelectorAll(".batch-row-model, .batch-row-storage, .batch-row-color").forEach((select) => {
        select.addEventListener("change", () => {
          select.dataset.manuallyChanged = "yes";
          continueSelectionToFollowingRows(select);
        });
      });

      panel.querySelectorAll(".batch-row-imei").forEach((input) => input.addEventListener("input", () => {
        input.value = input.value.replace(/\D/g, "");
        if (input.value.length === 15) {
          const nextImei = input.closest("tr").nextElementSibling?.querySelector(".batch-row-imei:not(:disabled)");
          window.setTimeout(() => (nextImei || panel.querySelector(".batch-row-battery:not(:disabled)"))?.focus(), 0);
        }
      }));
      panel.querySelectorAll(".batch-option-add").forEach((button) => button.addEventListener("click", () => addRowOption(button)));
      panel.querySelectorAll(".batch-option-remove").forEach((button) => button.addEventListener("click", () => removeRowOption(button)));
      panel.querySelectorAll(".batch-save-button").forEach((button) => button.addEventListener("click", () => saveRow(button.closest("tr"))));
      panel.querySelectorAll(".batch-row-battery").forEach((input) => {
        input.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); saveRow(input.closest("tr")); } });
        input.addEventListener("change", () => {
          const row = input.closest("tr");
          if (/^\d{15}$/.test(row.querySelector(".batch-row-imei").value.trim())) saveRow(row);
        });
      });
      panel.querySelector(".batch-row-imei")?.focus();
    }

    async function saveRow(row) {
      if (!row || row.dataset.busy === "yes" || row.dataset.saved === "yes") return;
      const imei = row.querySelector(".batch-row-imei").value.trim();
      const model = row.querySelector(".batch-row-model").value;
      const storage = row.querySelector(".batch-row-storage").value;
      const color = row.querySelector(".batch-row-color").value;
      const battery = row.querySelector(".batch-row-battery").value;
      const button = row.querySelector(".batch-save-button");
      if (!/^\d{15}$/.test(imei)) { setRowStatus(row, "IMEI must be 15 digits", "is-error"); row.querySelector(".batch-row-imei").focus(); return; }
      if (!model || !storage || !color) { setRowStatus(row, "Select Model, GB and Color", "is-error"); return; }
      if (battery === "" || Number(battery) < 0 || Number(battery) > 100) { setRowStatus(row, "Enter BH 0–100", "is-error"); return; }
      row.dataset.busy = "yes";
      button.disabled = true;
      setRowStatus(row, "Saving...", "is-saving");
      const { error } = await api().rpc("receive_stock_batch_imei_with_plan", {
        p_batch_id: currentBatch.batch_id,
        p_imei_1: imei,
        p_model: model,
        p_storage_gb: Number(storage),
        p_color: color,
        p_battery_health: Number(battery)
      });
      row.dataset.busy = "";
      if (error) { button.disabled = false; setRowStatus(row, error.message || "Could not save", "is-error"); return; }
      row.dataset.saved = "yes";
      row.classList.add("batch-saved-row");
      row.querySelectorAll("input, select").forEach((control) => { control.disabled = true; });
      button.textContent = "Saved";
      setRowStatus(row, "Sent to Initial QC", "is-saved");
      const nextRow = row.nextElementSibling;
      const nextControl = nextRow?.querySelector(".batch-row-imei:not(:disabled)") || panel.querySelector("tr:not(.batch-saved-row) .batch-row-battery:not(:disabled)");
      nextControl?.focus();
    }

    async function loadSelectedBatch() {
      if (!batchSelect.value) { currentBatch = undefined; slots = []; renderRows(); return; }
      const { data, error } = await api().rpc("get_open_stock_entry_batches_with_lines");
      if (error) return;
      currentBatch = (data || []).find((batch) => String(batch.batch_id) === String(batchSelect.value));
      slots = currentBatch ? makeSlots(currentBatch) : [];
      renderRows();
      originalActions.hidden = !currentBatch;
    }

    batchSelect.addEventListener("change", () => window.setTimeout(loadSelectedBatch, 80));
    new MutationObserver(() => {
      if (batchSelect.value && !currentBatch) window.setTimeout(loadSelectedBatch, 80);
    }).observe(batchSelect, { childList: true });
    if (batchSelect.value) window.setTimeout(loadSelectedBatch, 250);
  }

  function initialisePendingTable({ selectSelector, title, columns, workspaceSelector }) {
    const select = document.querySelector(selectSelector);
    if (!select) return;
    const anchor = select.closest(".qc-picker-row, .qc-scan-card");
    if (!anchor) return;
    const panel = document.createElement("section");
    panel.className = "pending-stage-panel";
    anchor.insertAdjacentElement("afterend", panel);
    const workspace = document.querySelector(workspaceSelector);
    const workspaceMarker = document.createComment(`${workspaceSelector} original position`);
    if (workspace?.parentNode) workspace.parentNode.insertBefore(workspaceMarker, workspace);

    function restoreWorkspace() {
      if (workspace && workspaceMarker.parentNode && workspace.parentNode !== workspaceMarker.parentNode) {
        workspaceMarker.parentNode.insertBefore(workspace, workspaceMarker.nextSibling);
      }
    }

    function parseText(text) {
      return String(text || "").split(/\s*(?:Â·|·|•)\s*/).map((value) => value.trim()).filter(Boolean);
    }

    function render() {
      restoreWorkspace();
      const options = [...select.options].filter((option) => option.value);
      panel.innerHTML = `
        <div class="pending-stage-title"><strong>${escapeHtml(title)}</strong><span>${options.length} pending</span></div>
        ${options.length ? `<div class="pending-table-scroll"><table class="pending-stage-table"><thead><tr><th>#</th>${columns.map((column) => `<th>${escapeHtml(column)}</th>`).join("")}<th>Action</th></tr></thead><tbody>${options.map((option, index) => {
          const pieces = parseText(option.text);
          const cells = columns.map((column, columnIndex) => `<td>${escapeHtml(pieces[columnIndex] || (columnIndex === 0 ? option.text : "—"))}</td>`).join("");
          const selected = select.value === option.value;
          return `<tr data-value="${escapeHtml(option.value)}"${selected ? ' class="is-selected"' : ""}><td>${index + 1}</td>${cells}<td><button type="button" class="pending-open-button" data-value="${escapeHtml(option.value)}">Open</button></td></tr>${selected ? `<tr class="pending-details-row"><td colspan="${columns.length + 2}"><div class="pending-inline-workspace"></div></td></tr>` : ""}`;
        }).join("")}</tbody></table></div>` : '<p class="pending-stage-empty">No pending IMEIs at this stage.</p>'}`;
      const detailsHost = panel.querySelector(".pending-inline-workspace");
      if (detailsHost && workspace) detailsHost.append(workspace);
      panel.querySelectorAll(".pending-open-button").forEach((button) => button.addEventListener("click", () => {
        select.value = button.dataset.value;
        select.dispatchEvent(new Event("change", { bubbles: true }));
      }));
    }

    new MutationObserver(render).observe(select, { childList: true });
    select.addEventListener("change", render);
    window.setTimeout(render, 400);
  }

  function boot() {
    if (!window.supabase || !config.supabaseUrl || !config.supabaseAnonKey) return;
    initialiseBatchEntry().catch(() => {});
    initialisePendingTable({ selectSelector: "#qc-pending-imei", title: "Initial QC pending IMEIs", columns: ["IMEI", "Supplier", "Model", "GB", "Color"], workspaceSelector: "#qc-workspace" });
    initialisePendingTable({ selectSelector: "#lab-step-select", title: "Laboratory pending IMEIs", columns: ["Supplier", "Job", "Device", "Model"], workspaceSelector: "#lab-workspace" });
    initialisePendingTable({ selectSelector: "#final-qc-step-select", title: "Final QC pending IMEIs", columns: ["Supplier", "Job", "IMEI"], workspaceSelector: "#final-qc-workspace" });
  }

  window.addEventListener("DOMContentLoaded", () => window.setTimeout(boot, 120));
})();
