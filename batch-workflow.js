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
    originalPanel.insertAdjacentElement("beforebegin", panel);

    const label = document.createElement("div");
    label.className = "single-entry-heading";
    label.textContent = "Single IMEI entry and dropdown management";
    originalPanel.insertAdjacentElement("beforebegin", label);
    label.hidden = true;

    let currentBatch;
    let slots = [];

    function setRowStatus(row, text, state = "") {
      const status = row.querySelector(".batch-row-status");
      status.textContent = text;
      status.className = `batch-row-status${state ? ` ${state}` : ""}`;
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
                <td><select class="batch-row-model">${optionsHtml(modelMaster, slot.model)}</select></td>
                <td><select class="batch-row-storage">${optionsHtml(storageMaster, String(slot.storage || ""))}</select></td>
                <td><select class="batch-row-color">${optionsHtml(colorMaster, slot.color)}</select></td>
                <td><input class="batch-row-battery" type="number" min="0" max="100" inputmode="numeric" placeholder="BH %"></td>
                <td><button class="batch-save-button" type="button">Save</button></td>
                <td class="batch-row-status">Waiting</td>
              </tr>`).join("")}</tbody>
          </table>
        </div>
        <p class="batch-entry-help">Scan the IMEI, confirm Model / GB / Color, then enter Battery Health. Press Enter in Battery Health or click Save. Blank lines are never stored.</p>`;

      panel.querySelectorAll(".batch-row-imei").forEach((input) => input.addEventListener("input", () => { input.value = input.value.replace(/\D/g, ""); }));
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
      row.nextElementSibling?.querySelector(".batch-row-imei")?.focus();
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

  function initialisePendingTable({ selectSelector, title, columns }) {
    const select = document.querySelector(selectSelector);
    if (!select) return;
    const anchor = select.closest(".qc-picker-row, .qc-scan-card");
    if (!anchor) return;
    const panel = document.createElement("section");
    panel.className = "pending-stage-panel";
    anchor.insertAdjacentElement("afterend", panel);

    function parseText(text) {
      return String(text || "").split(/\s*(?:Â·|·|•)\s*/).map((value) => value.trim()).filter(Boolean);
    }

    function render() {
      const options = [...select.options].filter((option) => option.value);
      panel.innerHTML = `
        <div class="pending-stage-title"><strong>${escapeHtml(title)}</strong><span>${options.length} pending</span></div>
        ${options.length ? `<div class="pending-table-scroll"><table class="pending-stage-table"><thead><tr><th>#</th>${columns.map((column) => `<th>${escapeHtml(column)}</th>`).join("")}<th>Action</th></tr></thead><tbody>${options.map((option, index) => {
          const pieces = parseText(option.text);
          const cells = columns.map((column, columnIndex) => `<td>${escapeHtml(pieces[columnIndex] || (columnIndex === 0 ? option.text : "—"))}</td>`).join("");
          return `<tr data-value="${escapeHtml(option.value)}"${select.value === option.value ? ' class="is-selected"' : ""}><td>${index + 1}</td>${cells}<td><button type="button" class="pending-open-button" data-value="${escapeHtml(option.value)}">Open</button></td></tr>`;
        }).join("")}</tbody></table></div>` : '<p class="pending-stage-empty">No pending IMEIs at this stage.</p>'}`;
      panel.querySelectorAll(".pending-open-button").forEach((button) => button.addEventListener("click", () => {
        select.value = button.dataset.value;
        select.dispatchEvent(new Event("change", { bubbles: true }));
        render();
      }));
    }

    new MutationObserver(render).observe(select, { childList: true });
    select.addEventListener("change", render);
    window.setTimeout(render, 400);
  }

  function boot() {
    if (!window.supabase || !config.supabaseUrl || !config.supabaseAnonKey) return;
    initialiseBatchEntry().catch(() => {});
    initialisePendingTable({ selectSelector: "#qc-pending-imei", title: "Initial QC pending IMEIs", columns: ["IMEI", "Supplier", "Model", "GB", "Color"] });
    initialisePendingTable({ selectSelector: "#lab-step-select", title: "Laboratory pending IMEIs", columns: ["Supplier", "Job", "Device", "Model"] });
    initialisePendingTable({ selectSelector: "#final-qc-step-select", title: "Final QC pending IMEIs", columns: ["Supplier", "Job", "IMEI"] });
  }

  window.addEventListener("DOMContentLoaded", () => window.setTimeout(boot, 120));
})();
