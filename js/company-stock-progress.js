(() => {
  "use strict";

  const stages = [
    ["initial_qc", "Initial QC"], ["issuance", "Issuance"], ["lab_glass", "Lab & Glass"],
    ["parts", "Parts"], ["final_qc", "Final QC"], ["b_dept", "B-DEPT"],
    ["ready_stock", "Ready · Unboxed"], ["box_entry", "Box Entry"], ["accounts", "Accounts"],
    ["return_pending", "Return Pending"], ["other", "Other"]
  ];
  const columns = [...stages, ["quantity", "In Company"], ["ready_total", "Ready Stock Total"]];
  const pageSize = 50;
  const downloadCap = "stock_progress_download";
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const escape = value => String(value ?? "").replace(/[&<>"']/g, character =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const format = new Intl.NumberFormat("en-GB");
  const date = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dubai", dateStyle: "medium", timeStyle: "short"
  });
  const can = permission => window.GREENLOOP_CAN?.(permission, "reports") === true;
  const canView = () => can("view") && can("report_supplier_progress");
  let dispose, reload, remount;

  function validCounts(row) {
    return !!row && columns.every(([key]) => count(row[key])) &&
      stages.reduce((sum, [key]) => sum + row[key], 0) === row.quantity &&
      row.ready_total >= row.ready_stock &&
      row.ready_total <= row.ready_stock + row.box_entry + row.accounts;
  }

  function mount(host, badge) {
    unmount();
    if (!canView()) return;
    let revision = 0;
    let current = true;
    let offset = 0;
    let receipts = [];
    let shown = null;
    let exporting = false;
    const selection = { supplier: "", batch: "", invoice: "" };
    const root = document.createElement("section");
    root.className = "company-stock-progress";
    root.innerHTML = `
      <div class="supplier-scope">
        <div class="supplier-scope-heading">
          <p>Ready Stock Total includes eligible phones in boxes awaiting export.</p>
          <div class="stock-progress-actions">
            <button type="button" class="secondary-button" data-stock-output="pdf" data-capability="${downloadCap}" data-capability-page="reports" hidden>Download PDF</button>
            <button type="button" class="secondary-button" data-stock-output="excel" data-capability="${downloadCap}" data-capability-page="reports" hidden>Download Excel</button>
            <button type="button" class="secondary-button" data-refresh data-capability="view" data-capability-page="reports">Refresh</button>
          </div>
        </div>
        <div class="supplier-scope-fields">
          <div class="form-field"><label for="stock-progress-supplier">Supplier</label>
            <select id="stock-progress-supplier" data-filter="supplier" data-capability="report_supplier_progress_search" data-capability-page="reports"></select></div>
          <div class="form-field"><label for="stock-progress-batch">Stock / Batch</label>
            <select id="stock-progress-batch" data-filter="batch" data-capability="report_supplier_progress_search" data-capability-page="reports"></select></div>
          <div class="form-field"><label for="stock-progress-invoice">Invoice</label>
            <select id="stock-progress-invoice" data-filter="invoice" data-capability="report_supplier_progress_search" data-capability-page="reports"></select></div>
        </div>
      </div>
      <p data-status role="status"></p>
      <div class="report-table-wrap stock-progress-scroll" data-table role="region" aria-label="Stock Progress table" tabindex="0" hidden></div>
      <div class="stock-progress-pager supplier-range-toolbar" data-pager hidden>
        <button type="button" class="secondary-button" data-previous data-capability="view" data-capability-page="reports">Previous</button>
        <span data-range></span>
        <button type="button" class="secondary-button" data-next data-capability="view" data-capability-page="reports">Next</button>
      </div>`;
    host.replaceChildren(root);
    const find = selector => root.querySelector(selector);
    const filters = Object.fromEntries(Object.keys(selection).map(key => [key, find(`[data-filter="${key}"]`)]));
    const status = find("[data-status]");
    const table = find("[data-table]");
    const pager = find("[data-pager]");
    const previous = find("[data-previous]");
    const next = find("[data-next]");
    const refresh = find("[data-refresh]");
    const downloads = root.querySelectorAll("[data-stock-output]");
    const checked = data => `Updated ${date.format(new Date(data.checked_at))} · UAE`;
    const gb = row => row.storage_gb === null ? "Not recorded" : window.GREENLOOP_STORAGE.label(row.storage_gb);

    function controls() {
      const allowed = can(downloadCap);
      for (const button of downloads) {
        button.hidden = !allowed;
        button.disabled = !allowed || !shown?.row_count || exporting;
      }
    }

    function options(select, label, pairs, value) {
      select.replaceChildren(new Option(label, ""), ...pairs.map(([key, text]) => new Option(text, key)));
      if (value && !pairs.some(([key]) => key === value)) select.add(new Option("Selected value no longer in stock", value));
      select.value = value;
      select.disabled = !can("report_supplier_progress_search");
    }

    function renderFilters() {
      const suppliers = new Map();
      for (const receipt of receipts) {
        if (receipt.supplier_id) {
          suppliers.set(receipt.supplier_id, [receipt.supplier_code, receipt.supplier_name].filter(Boolean).join(" · "));
        }
      }
      const supplierReceipts = receipts.filter(r => !selection.supplier || r.supplier_id === selection.supplier);
      const invoiceReceipts = supplierReceipts.filter(r => !selection.batch || r.batch_id === selection.batch);
      options(filters.supplier, "All suppliers", [...suppliers].sort((a, b) => a[1].localeCompare(b[1])), selection.supplier);
      options(filters.batch, "All batches", supplierReceipts.map(r => [
        r.batch_id, window.GREENLOOP_BATCH_LABEL(r.batch_number, r)
      ]), selection.batch);
      options(filters.invoice, "All invoices", [...new Set(invoiceReceipts.map(r => r.invoice_number).filter(Boolean))]
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).map(invoice => [invoice, invoice]), selection.invoice);
    }

    function render(data) {
      const cells = row => columns.map(([key]) => `<td>${format.format(row[key])}</td>`).join("");
      const rows = data.rows.map((row, index) => `<tr><td>${data.offset + index + 1}</td>
        <th scope="row">${escape(row.model)}</th><td>${escape(gb(row))}</td>
        ${cells(row)}</tr>`).join("");
      table.innerHTML = `<table class="report-table company-stock-progress-table" data-preserve-table-layout>
        <colgroup><col class="stock-progress-number"><col class="stock-progress-model"><col class="stock-progress-gb"><col span="${columns.length}"></colgroup>
        <thead><tr><th scope="col">S.No</th><th scope="col">Model</th><th scope="col">GB</th>
        ${columns.map(([, label]) => `<th scope="col">${escape(label)}</th>`).join("")}</tr></thead>
        <tbody>${rows || `<tr><td colspan="${3 + columns.length}" class="report-empty">No company phones match these filters.</td></tr>`}</tbody>
        <tfoot><tr><th colspan="3" scope="row">Filtered total</th>${cells(data.totals)}</tr></tfoot></table>`;
      badge.textContent = `${format.format(data.totals.quantity)} in company`;
      status.textContent = checked(data);
      pager.hidden = data.row_count <= pageSize;
      previous.disabled = data.offset === 0;
      next.disabled = data.offset + data.rows.length >= data.row_count;
      find("[data-range]").textContent = `${data.offset + 1}–${data.offset + data.rows.length} of ${data.row_count} model / GB rows`;
    }

    async function read(page, full = false, snapshot = null) {
      const scope = Object.fromEntries(Object.entries(selection).map(([key, value]) => [key, value || null]));
      const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc("get_company_stock_progress_v2", {
        p_supplier_id: scope.supplier,
        p_batch_id: scope.batch,
        p_invoice: scope.invoice,
        p_offset: page,
        p_export: full,
        p_expected: snapshot
      });
      if (error) throw error;
      if (!data || data.offset !== page || data.export !== full || !count(data.row_count) ||
          !/^[a-f0-9]{32}$/.test(data.snapshot) || (snapshot && snapshot !== data.snapshot) ||
          !data.filters || !Object.keys(scope).every(key => data.filters[key] === scope[key]) ||
          !Array.isArray(data.receipts) || !Array.isArray(data.rows) ||
          data.rows.length !== (full ? data.row_count : Math.min(pageSize, Math.max(0, data.row_count - page))) ||
          !validCounts(data.totals) || !data.rows.every(row => validCounts(row) && typeof row.model === "string" &&
            (row.storage_gb === null || count(row.storage_gb))) ||
          !columns.every(([key]) => {
            const subtotal = data.rows.reduce((sum, row) => sum + row[key], 0);
            return page === 0 && data.rows.length === data.row_count ? subtotal === data.totals[key] : subtotal <= data.totals[key];
          }) || !Number.isFinite(Date.parse(data.checked_at))) {
        throw new Error("Stock Progress totals could not be verified.");
      }
      return data;
    }

    async function load() {
      if (!current || !canView()) return;
      const request = ++revision;
      const page = offset;
      const left = table.scrollLeft;
      shown = null;
      exporting = false;
      refresh.disabled = true;
      controls();
      table.replaceChildren();
      table.hidden = true;
      pager.hidden = true;
      status.textContent = "Loading stock progress…";
      badge.textContent = "Loading…";
      try {
        const data = await read(page);
        if (!current || request !== revision || !canView()) return;
        if (page > 0 && page >= data.row_count) {
          offset = Math.max(0, Math.floor((data.row_count - 1) / pageSize) * pageSize);
          return await load();
        }
        receipts = data.receipts;
        renderFilters();
        render(data);
        shown = data;
        table.hidden = false;
        table.scrollLeft = left;
      } catch (error) {
        if (!current || request !== revision || !canView()) return;
        status.textContent = `${error.message || "Stock Progress could not be loaded."} Use Refresh to retry.`;
        badge.textContent = "Unavailable";
      } finally {
        if (current && request === revision) {
          refresh.disabled = false;
          controls();
        }
      }
    }

    async function output(kind) {
      if (!shown?.row_count || exporting || !canView() || !can(downloadCap)) return;
      const request = revision, snapshot = shown.snapshot;
      const permitted = () => current && request === revision && canView() && can(downloadCap);
      const selectedLabels = Object.values(filters).map(el => el.selectedOptions[0]?.textContent).filter(Boolean);
      exporting = true;
      controls();
      status.textContent = kind === "excel" ? "Preparing Excel…" : "Preparing PDF…";
      try {
        const data = await read(0, true, snapshot);
        if (!permitted()) return;
        const counters = row => columns.map(([key]) => row[key]);
        await window.GREENLOOP_REPORT_DOWNLOADS.output(kind, {
          title: "Stock Progress Report",
          subtitle: selectedLabels.join(" | "),
          summaryRows: [checked(data)],
          headers: ["S.No", "Model", "GB", ...columns.map(([, label]) => label)],
          rows: data.rows.map((row, index) => [index + 1, row.model, gb(row), ...counters(row)]),
          footerRow: ["", "Filtered total", "", ...counters(data.totals)],
          numericColumns: [0, ...columns.map((_, index) => index + 3)],
          wrapWords: true,
          pdfSinglePage: true,
          columnWeights: [.65, 2, 1.15, ...columns.map(([, label]) =>
            label.length > 12 ? 1.35 : label.split(" ").some(word => word.length >= 7) ? 1.2 : 1)]
        }, permitted, "reports", downloadCap);
        if (permitted()) status.textContent = checked(data);
      } catch (error) {
        if (permitted()) status.textContent = error.message || "Stock Progress could not be downloaded.";
      } finally {
        if (current && request === revision) {
          exporting = false;
          controls();
        }
      }
    }

    for (const [key, select] of Object.entries(filters)) {
      select.addEventListener("change", () => {
        if (!can("report_supplier_progress_search")) return;
        selection[key] = select.value;
        if (key === "supplier") selection.batch = "";
        if (key !== "invoice") selection.invoice = "";
        offset = 0;
        renderFilters();
        void load();
      });
    }
    for (const button of downloads) button.addEventListener("click", () => void output(button.dataset.stockOutput));
    refresh.addEventListener("click", () => void load());
    previous.addEventListener("click", () => { offset -= pageSize; void load(); });
    next.addEventListener("click", () => { offset += pageSize; void load(); });
    dispose = () => { current = false; root.remove(); badge.textContent = ""; };
    reload = load;
    remount = () => mount(host, badge);
    renderFilters();
    void load();
  }

  function unmount() {
    dispose?.();
    dispose = undefined;
    reload = undefined;
    remount = undefined;
  }
  for (const event of ["greenloop:signed-out", "greenloop:office-locked"]) window.addEventListener(event, unmount);
  window.addEventListener("greenloop:permissions-changed", () => {
    if (canView()) remount?.();
    else unmount();
  });
  window.GREENLOOP_COMPANY_STOCK_PROGRESS = { mount, unmount, refresh: () => reload?.() };
})();
