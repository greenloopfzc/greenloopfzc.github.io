(() => {
  "use strict";

  const launchers = [...document.querySelectorAll("[data-stage-model-summary]")];
  if (!launchers.length) return;

  const pageSize = 50;
  const stageNames = {
    initial_qc: "Initial QC",
    qc_issuance: "Lab & Glass Issuance",
    lab_glass: "Lab & Glass",
    frame_department: "B-DEPT",
    final_qc: "Final QC"
  };
  const amount = value => value.toLocaleString("en-US");
  const canView = stage => window.GREENLOOP_CAN?.("view", stage) === true;

  const dialog = document.createElement("dialog");
  dialog.className = "stage-model-dialog";
  dialog.setAttribute("aria-labelledby", "stage-model-title");
  dialog.innerHTML = `
    <header class="stage-model-heading">
      <h2 id="stage-model-title"></h2>
      <div class="stage-model-actions">
        <button type="button" class="secondary-button" data-model-refresh data-search-read-only>Refresh</button>
        <button type="button" class="secondary-button" data-model-close data-search-read-only autofocus>Close</button>
      </div>
    </header>
    <p class="stage-model-status" role="status" hidden></p>
    <div class="stage-model-scroll" role="region" aria-label="Pending phones by model and storage" tabindex="0" hidden>
      <table data-no-table-filters data-preserve-table-layout>
        <thead><tr><th scope="col">S.No</th><th scope="col">Model</th><th scope="col">GB</th><th scope="col">Quantity</th></tr></thead>
        <tbody></tbody>
        <tfoot><tr><th scope="row" colspan="3">Total</th><td></td></tr></tfoot>
      </table>
    </div>
    <nav class="stage-model-pages" aria-label="Model summary pages" hidden>
      <button type="button" class="secondary-button" data-model-previous data-search-read-only>Previous</button>
      <span aria-live="polite"></span>
      <button type="button" class="secondary-button" data-model-next data-search-read-only>Next</button>
    </nav>`;
  document.body.append(dialog);

  const title = dialog.querySelector("h2");
  const status = dialog.querySelector(".stage-model-status");
  const scroll = dialog.querySelector(".stage-model-scroll");
  const body = dialog.querySelector("tbody");
  const totalCell = dialog.querySelector("tfoot td");
  const pager = dialog.querySelector(".stage-model-pages");
  const range = pager.querySelector("span");
  const previous = pager.querySelector("[data-model-previous]");
  const next = pager.querySelector("[data-model-next]");
  const refresh = dialog.querySelector("[data-model-refresh]");
  let stage = "", readVersion = 0, summary = null;

  function message(text) {
    status.textContent = text;
    status.hidden = !text;
  }

  function clear() {
    summary = null;
    body.replaceChildren();
    totalCell.textContent = "";
    range.textContent = "";
    scroll.hidden = true;
    pager.hidden = true;
  }

  function render() {
    body.replaceChildren();
    const { offset, group_count: groupCount, rows } = summary;
    const end = offset + rows.length;
    rows.forEach(({model, storage_gb, quantity}, index) => {
      const line = body.insertRow();
      for (const value of [offset + index + 1, model || "Not recorded",
        storage_gb == null ? "Not recorded" : amount(storage_gb) + " GB", amount(quantity)]) {
        line.insertCell().textContent = value;
      }
    });
    totalCell.textContent = amount(summary.total);
    scroll.scrollTop = 0;
    scroll.hidden = false;
    pager.hidden = groupCount <= pageSize;
    range.textContent = (offset + 1) + "–" + end + " of " + groupCount + " groups";
    previous.disabled = offset === 0;
    next.disabled = end >= groupCount;
  }

  function isValid(data, expectedStage, offset) {
    return data?.stage === expectedStage && data.offset === offset &&
      Number.isSafeInteger(data.group_count) && data.group_count >= 0 &&
      Number.isSafeInteger(data.total) && data.total >= data.group_count && Array.isArray(data.rows) &&
      data.rows.length === Math.min(pageSize, Math.max(0, data.group_count - offset)) &&
      data.rows.every(row => row && (row.model === null || typeof row.model === "string") &&
        (row.storage_gb === null || (Number.isSafeInteger(row.storage_gb) && row.storage_gb >= 0)) &&
        Number.isSafeInteger(row.quantity) && row.quantity > 0) &&
      (data.group_count <= pageSize && offset === 0
        ? data.rows.reduce((sum, row) => sum + row.quantity, 0) === data.total
        : data.rows.reduce((sum, row) => sum + row.quantity, 0) <= data.total);
  }

  async function load(offset = 0) {
    const activeStage = stage;
    const version = ++readVersion;
    const current = () => dialog.open && version === readVersion && canView(activeStage);
    clear();
    if (!current()) return;
    refresh.disabled = true;
    message("Loading pending phones…");
    try {
      const result = await window.GREENLOOP_GET_CLIENT().rpc("get_pending_model_summary_v1", { p_stage: activeStage, p_offset: offset });
      if (!current()) return;
      if (result.error || !isValid(result.data, activeStage, offset)) throw new Error("Pending model summary could not be verified.");
      summary = result.data;
      if (!summary.rows.length) {
        message(summary.group_count ? "This page changed. Select Refresh to see the current summary." : "No pending phones. Total 0.");
        return;
      }
      message("");
      render();
    } catch {
      if (current()) message("Model summary could not be loaded. Select Refresh to try again.");
    } finally {
      if (current()) refresh.disabled = false;
    }
  }

  for (const button of launchers) {
    button.addEventListener("click", () => {
      const target = button.dataset.stageModelSummary;
      if (dialog.open || !Object.hasOwn(stageNames, target) || !canView(target)) return;
      stage = target;
      title.textContent = stageNames[target] + " Model Summary";
      dialog.showModal();
      void load();
    });
  }

  refresh.addEventListener("click", () => void load());
  previous.addEventListener("click", () => {
    if (summary?.offset > 0) void load(summary.offset - pageSize);
  });
  next.addEventListener("click", () => {
    if (summary && summary.offset + pageSize < summary.group_count) void load(summary.offset + pageSize);
  });
  dialog.querySelector("[data-model-close]").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++readVersion;
    stage = "";
    clear();
    message("");
  });
  for (const name of ["greenloop:office-locked", "greenloop:signed-out", "greenloop:permissions-changed", "pagehide"]) {
    window.addEventListener(name, () => {
      ++readVersion;
      clear();
      message("");
      if (dialog.open) dialog.close();
    });
  }
})();
