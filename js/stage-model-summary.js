(() => {
  "use strict";

  const launchers = [...document.querySelectorAll("[data-stage-model-summary]")];
  if (!launchers.length) return;

  const pageSize = 50;
  const technicianColumns = [0, 1, 5];
  const stageNames = {
    initial_qc: "Initial QC",
    qc_issuance: "Lab & Glass Issuance",
    lab_glass: "Lab & Glass",
    lab_technician_stock: "Lab & Glass Technician Stock",
    frame_department: "B-DEPT",
    final_qc: "Final QC"
  };
  const amount = value => value.toLocaleString("en-US");
  const isTechnicianStock = stage => stage === "lab_technician_stock";
  const canView = stage => window.GREENLOOP_CAN?.("view", isTechnicianStock(stage) ? "lab_glass" : stage) === true;

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
      <table data-no-table-filters data-preserve-table-layout data-no-serial>
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
  const table = scroll.querySelector("table");
  const body = table.tBodies[0];
  const totalCell = dialog.querySelector("tfoot td");
  const pager = dialog.querySelector(".stage-model-pages");
  const range = pager.querySelector("span");
  const previous = pager.querySelector("[data-model-previous]");
  const next = pager.querySelector("[data-model-next]");
  const refresh = dialog.querySelector("[data-model-refresh]");
  let stage = "", readVersion = 0, summary = null;
  let pageStarts = [], pageIndex = 0;

  function message(text) {
    status.textContent = text;
    status.hidden = !text;
  }

  function clear() {
    summary = null;
    pageStarts = [];
    pageIndex = 0;
    body.replaceChildren();
    totalCell.textContent = "";
    range.textContent = "";
    scroll.hidden = true;
    pager.hidden = true;
  }

  function showPage(index) {
    const { offset, group_count: groupCount, rows } = summary;
    pageIndex = index;
    const start = pageStarts[index];
    const end = pageStarts[index + 1] ?? rows.length;
    for (let i = 0; i < body.rows.length; i++) body.rows[i].hidden = i < start || i >= end;
    if (isTechnicianStock(stage)) {
      let first = start;
      while (first < end) {
        let after = first + 1;
        while (after < end && rows[after].technician_id === rows[first].technician_id) after++;
        for (const column of technicianColumns) {
          const cell = body.rows[first].cells[column];
          cell.hidden = false;
          cell.rowSpan = after - first;
          for (let i = first + 1; i < after; i++) {
            const duplicate = body.rows[i].cells[column];
            duplicate.hidden = true;
            duplicate.rowSpan = 1;
          }
        }
        first = after;
      }
    }
    scroll.scrollTop = 0;
    pager.hidden = offset === 0 && start === 0 && end === groupCount;
    range.textContent = (offset + start + 1) + "–" + (offset + end) + " of " + groupCount + " groups";
    previous.disabled = offset === 0 && start === 0;
    next.disabled = offset + end >= groupCount;
  }

  function fitRows(visibleRow = pageStarts[pageIndex] ?? 0) {
    if (!dialog.open || !summary?.rows.length) return;
    for (const row of body.rows) {
      row.hidden = false;
      if (isTechnicianStock(stage)) {
        for (const column of technicianColumns) {
          row.cells[column].hidden = false;
          row.cells[column].rowSpan = 1;
        }
      }
    }
    const longestRange = summary.group_count;
    range.textContent = longestRange + "–" + longestRange + " of " + longestRange + " groups";
    pager.hidden = summary.offset === 0 && summary.rows.length === summary.group_count;
    pageStarts = [0];
    if (table.offsetHeight > scroll.clientHeight) {
      pager.hidden = false;
      const available = scroll.clientHeight - table.tHead.getBoundingClientRect().height
        - table.tFoot.getBoundingClientRect().height - 4;
      const heights = [...body.rows].map(row => row.getBoundingClientRect().height);
      let used = 0;
      for (let i = 0; i < body.rows.length; i++) {
        let blockHeight = heights[i];
        if (isTechnicianStock(stage) && (i === 0 || summary.rows[i].technician_id !== summary.rows[i - 1].technician_id)) {
          let after = i + 1;
          while (after < heights.length && summary.rows[after].technician_id === summary.rows[i].technician_id) {
            blockHeight += heights[after++];
          }
          if (blockHeight > available) blockHeight = heights[i];
        }
        if (used > 0 && used + blockHeight > available) {
          pageStarts.push(i);
          used = 0;
        }
        used += heights[i];
      }
    }
    showPage(pageStarts.findLastIndex(start => start <= visibleRow));
  }

  function render(lastPage, adjacent) {
    body.replaceChildren();
    const { offset, rows } = summary;
    const technicianStock = isTechnicianStock(stage);
    const technicianStarts = technicianStock
      ? rows.map((row, i) => i === 0 || row.technician_id !== rows[i - 1].technician_id)
      : [];
    let serial = 0;
    if (technicianStock && offset && adjacent) {
      // Derive the first serial from the adjacent data page, including a group that crosses the boundary.
      serial = lastPage
        ? Math.max(0, adjacent.serial - technicianStarts.filter(Boolean).length - (adjacent.id === rows.at(-1).technician_id ? 0 : 1))
        : adjacent.serial - (adjacent.id === rows[0].technician_id ? 1 : 0);
    }
    rows.forEach(({model, storage_gb, quantity, technician, technician_total}, index) => {
      const line = body.insertRow();
      if (technicianStarts[index]) serial++;
      const cells = [technicianStock ? serial : offset + index + 1, model || "Not recorded",
        storage_gb == null ? "Not recorded" : amount(storage_gb) + " GB", amount(quantity)];
      if (technicianStock) {
        cells.splice(1, 0, technician);
        cells.push(amount(technician_total));
      }
      for (const value of cells) {
        line.insertCell().textContent = value;
      }
    });
    totalCell.textContent = amount(summary.total);
    scroll.hidden = false;
    fitRows(lastPage ? rows.length - 1 : 0);
  }

  function technicianAt(index) {
    if (!isTechnicianStock(stage)) return null;
    return {
      id: summary.rows[index].technician_id,
      serial: Number(body.rows[index].cells[0].textContent)
    };
  }

  function isValid(data, expectedStage, offset) {
    return data?.stage === expectedStage && data.offset === offset &&
      Number.isSafeInteger(data.group_count) && data.group_count >= 0 &&
      Number.isSafeInteger(data.total) && data.total >= data.group_count && Array.isArray(data.rows) &&
      data.rows.length === Math.min(pageSize, Math.max(0, data.group_count - offset)) &&
      data.rows.every(row => row && (row.model === null || typeof row.model === "string") &&
        (row.storage_gb === null || (Number.isSafeInteger(row.storage_gb) && row.storage_gb >= 0)) &&
        Number.isSafeInteger(row.quantity) && row.quantity > 0 &&
        (!isTechnicianStock(expectedStage) ||
          (typeof row.technician_id === "string" && row.technician_id &&
            typeof row.technician === "string" && row.technician.trim() &&
            Number.isSafeInteger(row.technician_total) && row.technician_total >= row.quantity &&
            row.technician_total <= data.total))) &&
      (data.group_count <= pageSize && offset === 0
        ? data.rows.reduce((sum, row) => sum + row.quantity, 0) === data.total
        : data.rows.reduce((sum, row) => sum + row.quantity, 0) <= data.total);
  }

  async function load(offset = 0, lastPage = false, adjacent = null) {
    const activeStage = stage;
    const version = ++readVersion;
    const current = () => dialog.open && version === readVersion && canView(activeStage);
    clear();
    if (!current()) return;
    refresh.disabled = true;
    message("Loading pending phones…");
    try {
      const client = window.GREENLOOP_GET_CLIENT();
      const result = isTechnicianStock(activeStage)
        ? await client.rpc("get_lab_technician_stock_summary_v1", { p_offset: offset })
        : await client.rpc("get_pending_model_summary_v1", { p_stage: activeStage, p_offset: offset });
      if (!current()) return;
      if (result.error || !isValid(result.data, activeStage, offset)) throw new Error("Pending model summary could not be verified.");
      summary = result.data;
      if (!summary.rows.length) {
        message(summary.group_count ? "This page changed. Select Refresh to see the current summary." : "No pending phones. Total 0.");
        return;
      }
      message("");
      render(lastPage, adjacent);
    } catch {
      if (current()) message(isTechnicianStock(activeStage)
        ? "Technician stock could not be loaded. Select Refresh to try again."
        : "Model summary could not be loaded. Select Refresh to try again.");
    } finally {
      if (current()) refresh.disabled = false;
    }
  }

  for (const button of launchers) {
    button.addEventListener("click", () => {
      const target = button.dataset.stageModelSummary;
      if (dialog.open || !Object.hasOwn(stageNames, target) || !canView(target)) return;
      stage = target;
      const technicianStock = isTechnicianStock(target);
      title.textContent = technicianStock ? stageNames[target] : stageNames[target] + " Model Summary";
      dialog.toggleAttribute("data-technician-stock", technicianStock);
      scroll.setAttribute("aria-label", technicianStock
        ? "Pending phones by technician, model and storage"
        : "Pending phones by model and storage");
      const headings = technicianStock
        ? ["S.No", "Technician", "Model", "GB", "Quantity", "Tech Total"]
        : ["S.No", "Model", "GB", "Quantity"];
      const header = table.tHead.rows[0];
      header.replaceChildren(...headings.map(label => {
        const column = document.createElement("th");
        column.scope = "col";
        column.textContent = label;
        return column;
      }));
      table.tFoot.hidden = technicianStock;
      dialog.showModal();
      void load();
    });
  }

  refresh.addEventListener("click", () => void load());
  previous.addEventListener("click", () => {
    if (pageIndex > 0) showPage(pageIndex - 1);
    else if (summary?.offset > 0) void load(summary.offset - pageSize, true, technicianAt(0));
  });
  next.addEventListener("click", () => {
    if (pageIndex + 1 < pageStarts.length) showPage(pageIndex + 1);
    else if (summary && summary.offset + pageSize < summary.group_count) {
      void load(summary.offset + pageSize, false, technicianAt(summary.rows.length - 1));
    }
  });
  window.addEventListener("resize", () => fitRows());
  window.visualViewport?.addEventListener("resize", () => fitRows());
  document.fonts?.ready.then(() => fitRows());
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
