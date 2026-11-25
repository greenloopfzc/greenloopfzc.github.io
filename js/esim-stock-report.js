(() => {
  "use strict";

  const pageSize = 50;
  const reportView = "report_esim_stock";
  const reportFilter = "report_esim_stock_search";
  const can = capability => window.GREENLOOP_CAN?.(capability, "reports") === true;
  const allowed = () => can("view") && can(reportView);
  const number = new Intl.NumberFormat("en-GB");
  const clock = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dubai", dateStyle: "medium", timeStyle: "short"
  });
  const evidence = {
    esim_only_by_a_number: "Apple A-number",
    esim_only_by_model: "Model",
    likely_esim_only_by_region: "Sales region · likely",
    needs_variant_check: "Check variant"
  };
  const notRecorded = "Not recorded";
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const batchLabel = row => row?.batch_number
    ? window.GREENLOOP_BATCH_LABEL?.(row.batch_number, row, notRecorded) || row.batch_number : notRecorded;
  const supplierLabel = row => row?.supplier_code
    ? window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(row.supplier_code, row.receipt_quantity, row.supplier_name, notRecorded)
      || [row.supplier_code, row.supplier_name].filter(Boolean).join(" · ") : notRecorded;
  let active;

  function unmount() {
    active?.root.remove();
    active = null;
  }

  function setOptions(select, label, options, value) {
    select.replaceChildren(new Option(label, ""), ...options.map(([key, text]) => new Option(text, key)));
    if (value && !options.some(([key]) => key === value)) {
      select.add(new Option("Selected value no longer in stock", value));
    }
    select.value = value || "";
    select.disabled = !can(reportFilter);
  }

  function renderFilters(state, receipts) {
    const { supplier, batch, invoice } = state.filters;
    const suppliers = new Map();
    for (const receipt of receipts) {
      if (receipt.supplier_id) {
        suppliers.set(receipt.supplier_id, [receipt.supplier_code, receipt.supplier_name].filter(Boolean).join(" · "));
      }
    }
    const batches = receipts.filter(row => !supplier || row.supplier_id === supplier);
    const invoices = [...new Set(batches.filter(row => !batch || row.batch_id === batch)
      .map(row => row.invoice_number).filter(Boolean))];
    setOptions(state.fields.supplier, "All suppliers", [...suppliers].sort((a, b) => a[1].localeCompare(b[1])), supplier);
    setOptions(state.fields.batch, "All batches", batches.map(row => [row.batch_id, batchLabel(row)]), batch);
    setOptions(state.fields.invoice, "All invoices", invoices.sort().map(value => [value, value]), invoice);
  }

  function valid(data, view, offset, filters) {
    if (data?.version !== "20261125-esim-stock-1" || data.view !== view || data.offset !== offset ||
        !Number.isFinite(Date.parse(data.checked_at)) || !count(data.row_count) ||
        !Array.isArray(data.receipts) || !Array.isArray(data.rows) ||
        !["by_model", "by_region", "needs_check"].every(key => count(data.counts?.[key])) ||
        !Object.keys(filters).every(key => data.filters?.[key] === filters[key]) ||
        data.rows.length !== Math.min(pageSize, Math.max(0, data.row_count - offset))) return false;
    const batchIds = new Set(data.receipts.map(row => row?.batch_id));
    const rowsValid = data.rows.every(row => row && typeof row.model === "string" &&
      (row.storage_gb === null || count(row.storage_gb)) && (row.color === null || typeof row.color === "string") &&
      count(row.quantity) && row.quantity > 0 && Object.hasOwn(evidence, row.sim_class) &&
      (row.sim_class === "needs_variant_check") === (view === "check") &&
      (row.batch_id === null || batchIds.has(row.batch_id)));
    const visibleCount = data.rows.reduce((sum, row) => sum + (row?.quantity ?? 0), 0);
    const total = view === "check" ? data.counts.needs_check : data.counts.by_model + data.counts.by_region;
    return rowsValid && (offset === 0 && data.rows.length === data.row_count ? visibleCount === total : visibleCount <= total);
  }

  function render(state, data) {
    renderFilters(state, data.receipts);
    const receipts = new Map(data.receipts.map(row => [row.batch_id,row]));
    const { by_model, by_region, needs_check } = data.counts;
    state.esimCount.textContent = number.format(by_model + by_region);
    state.checkCount.textContent = number.format(needs_check);
    state.summary.textContent = number.format(by_model) + " identified by model or A-number · " +
      number.format(by_region) + " likely by sales region";
    state.badge.textContent = "Updated " + clock.format(new Date(data.checked_at)) + " · UAE";
    state.tbody.replaceChildren();
    for (const [index, item] of data.rows.entries()) {
      const receipt = receipts.get(item.batch_id);
      const row = state.tbody.insertRow();
      const gb = item.storage_gb == null ? notRecorded
        : window.GREENLOOP_STORAGE?.label(item.storage_gb) || item.storage_gb + " GB";
      for (const value of [data.offset + index + 1,item.model,gb,item.color || notRecorded,
        supplierLabel(receipt),batchLabel(receipt),receipt?.invoice_number || notRecorded,
        number.format(item.quantity),evidence[item.sim_class]]) {
        row.insertCell().textContent = value;
      }
    }
    state.table.hidden = !data.rows.length;
    state.status.textContent = data.rows.length ? "" : "No matching company phones.";
    state.pager.hidden = data.row_count <= pageSize;
    state.previous.disabled = data.offset === 0;
    state.next.disabled = data.offset + data.rows.length >= data.row_count;
    state.range.textContent = (data.offset + 1) + "–" + (data.offset + data.rows.length) + " of " +
      number.format(data.row_count) + " groups";
  }

  async function load(state, offset = 0) {
    if (state !== active || !allowed()) return;
    const ticket = ++state.ticket;
    const view = state.view;
    const filters = { ...state.filters };
    const current = () => active === state && ticket === state.ticket && allowed();
    state.status.textContent = "Loading eSIM stock…";
    state.root.setAttribute("aria-busy", "true");
    state.badge.textContent = "";
    state.summary.textContent = "";
    state.esimCount.textContent = state.checkCount.textContent = "—";
    state.table.hidden = state.pager.hidden = true;
    state.tbody.replaceChildren();
    try {
      const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc("get_esim_stock_v1", {
        p_supplier_id: filters.supplier, p_batch_id: filters.batch, p_invoice: filters.invoice,
        p_view: view, p_offset: offset
      });
      if (!current()) return;
      if (error || !valid(data, view, offset, filters)) {
        throw new Error("eSIM Stock could not be loaded. Select Refresh to try again.");
      }
      if (offset && !data.rows.length) return load(state);
      state.offset = offset;
      render(state, data);
    } catch (error) {
      if (current()) state.status.textContent = error.message || "eSIM Stock is unavailable.";
    } finally {
      if (current()) state.root.removeAttribute("aria-busy");
    }
  }

  function mount(host, badge) {
    if (!allowed() || active?.root.parentNode === host) return;
    unmount();
    const noFilters = {supplier:null,batch:null,invoice:null};
    host.innerHTML = `
      <section class="esim-stock" aria-label="eSIM Stock" data-capability="report_esim_stock" data-capability-page="reports">
        <div class="supplier-scope">
          <div class="supplier-scope-fields">
            <label class="form-field">Supplier<select data-esim-filter="supplier" data-capability="report_esim_stock_search" data-capability-page="reports"><option value="">All suppliers</option></select></label>
            <label class="form-field">Stock / Batch<select data-esim-filter="batch" data-capability="report_esim_stock_search" data-capability-page="reports"><option value="">All batches</option></select></label>
            <label class="form-field">Invoice<select data-esim-filter="invoice" data-capability="report_esim_stock_search" data-capability-page="reports"><option value="">All invoices</option></select></label>
          </div>
          <div class="esim-stock-actions">
            <button type="button" class="secondary-button" data-esim-reset data-capability="report_esim_stock_search" data-capability-page="reports">Clear filters</button>
            <button type="button" class="secondary-button" data-esim-refresh>Refresh</button>
          </div>
        </div>
        <div class="esim-stock-cards">
          <button type="button" class="secondary-button" data-esim-view="esim" aria-pressed="true"><span>eSIM-only</span><strong>—</strong></button>
          <button type="button" class="secondary-button" data-esim-view="check" aria-pressed="false"><span>Needs Variant Check</span><strong>—</strong></button>
        </div>
        <p class="esim-stock-summary" data-esim-summary></p>
        <p data-esim-status role="status"></p>
        <div class="esim-stock-table" role="region" aria-label="eSIM stock groups" tabindex="0" hidden>
          <table class="report-table" data-no-table-filters data-preserve-table-layout data-no-serial>
            <thead><tr><th>S.No</th><th>Model</th><th>GB</th><th>Color</th><th>Supplier</th><th>Stock / Batch</th>
              <th>Invoice</th><th>Quantity</th><th>Variant Evidence</th></tr></thead><tbody></tbody>
          </table>
        </div>
        <div class="supplier-range-toolbar" data-esim-pager hidden>
          <button type="button" class="secondary-button" data-esim-prev>Previous</button>
          <span data-esim-range aria-live="polite"></span>
          <button type="button" class="secondary-button" data-esim-next>Next</button>
        </div>
      </section>`;
    const root = host.querySelector(".esim-stock");
    const find = selector => root.querySelector(selector);
    const viewButtons = [...root.querySelectorAll("[data-esim-view]")];
    const state = active = {
      root,badge,view:"esim",offset:0,ticket:0,filters:{ ...noFilters },
      fields:Object.fromEntries(Object.keys(noFilters).map(key => [key,find('[data-esim-filter="'+key+'"]')])),
      status:find("[data-esim-status]"),summary:find("[data-esim-summary]"),table:find(".esim-stock-table"),
      tbody:find("tbody"),pager:find("[data-esim-pager]"),range:find("[data-esim-range]"),
      previous:find("[data-esim-prev]"),next:find("[data-esim-next]"),
      esimCount:viewButtons[0].querySelector("strong"),checkCount:viewButtons[1].querySelector("strong")
    };
    for (const [key,select] of Object.entries(state.fields)) {
      select.disabled = !can(reportFilter);
      select.addEventListener("change", () => {
        if (!can(reportFilter)) return;
        state.filters[key] = select.value || null;
        if (key === "supplier") state.filters.batch = null;
        if (key !== "invoice") state.filters.invoice = null;
        void load(state);
      });
    }
    const reset = find("[data-esim-reset]");
    reset.disabled = !can(reportFilter);
    reset.addEventListener("click", () => {
      if (!can(reportFilter)) return;
      state.filters = { ...noFilters };
      void load(state);
    });
    for (const button of viewButtons) {
      button.addEventListener("click", () => {
        const view = button.dataset.esimView;
        if (state.view === view) return;
        state.view = view;
        viewButtons.forEach(item => item.setAttribute("aria-pressed", String(item === button)));
        void load(state);
      });
    }
    find("[data-esim-refresh]").addEventListener("click", () => void load(state));
    state.previous.addEventListener("click", () => void load(state, state.offset - pageSize));
    state.next.addEventListener("click", () => void load(state, state.offset + pageSize));
    void load(state);
  }

  for (const event of ["greenloop:permissions-changed","greenloop:office-locked","greenloop:signed-out","pagehide"]) {
    window.addEventListener(event, unmount);
  }
  window.GREENLOOP_ESIM_STOCK = { mount,unmount };
})();
