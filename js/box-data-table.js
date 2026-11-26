(() => {
  "use strict";

  const host = document.querySelector("[data-box-data-table]");
  if (!host) return;
  const page = host.dataset.boxDataTable;
  if (!["accounts", "stock_exported"].includes(page)) return;

  const pending = page === "accounts";
  const title = pending ? "Box Data Table" : "Exported Data Table";
  const dateLabel = pending ? "Saved date" : "Export date";
  const pageSize = 50;
  const displayDate = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric"
  });
  const number = new Intl.NumberFormat("en-GB");
  const esc = value => String(value ?? "").replace(/[&<>"']/g, char => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);
  const allowed = capability => window.GREENLOOP_PAGE_ACCESS?.pageKey === page &&
    window.GREENLOOP_CAN?.(capability, page) === true;
  const capability = name => `data-capability="${name}" data-capability-page="${page}"`;
  const blank = () => ({ p_from: null, p_to: null, p_search: "" });

  host.innerHTML = `
    <button type="button" class="accounts-section-card" aria-expanded="false"
      aria-controls="box-data-table-panel" data-box-data-toggle ${capability("view")}>
      <strong>${title}</strong>
      <small>${pending ? "Phones in boxes awaiting verification" : "Phones in exported boxes"}</small>
    </button>
    <section id="box-data-table-panel" class="box-queue-card" aria-labelledby="box-data-table-title" hidden>
      <div class="box-detail-heading">
        <h2 id="box-data-table-title" tabindex="-1">${title}</h2>
        <button type="button" class="secondary-button" data-box-data-refresh ${capability("view")}>Refresh</button>
      </div>
      <form class="box-queue-filter" aria-label="${dateLabel} range in UAE time" ${capability("search")}>
        <label>${dateLabel} from · UAE <input name="from" type="date" min="1900-01-01" max="9999-12-30"></label>
        <label>${dateLabel} to · UAE <input name="to" type="date" min="1900-01-01" max="9999-12-30"></label>
        <label>Search phones <input name="search" type="search" maxlength="120" placeholder="Box, IMEI, model, GB or color"></label>
        <button type="submit" class="primary-button">Apply filters</button>
        <button type="button" class="secondary-button" data-box-data-clear>Clear filters</button>
      </form>
      <p role="status" data-box-data-status></p>
      <div class="box-table-wrap">
        <table class="box-table" aria-labelledby="box-data-table-title" data-no-serial data-no-table-filters data-no-auto-sort>
          <thead><tr>${["S.No", "Box Number", "IMEI", "Model", "GB", "Color", "Grade", dateLabel + " · UAE"]
            .map(label => `<th scope="col">${label}</th>`).join("")}</tr></thead>
          <tbody></tbody>
        </table>
      </div>
      <nav class="box-queue-pagination" aria-label="Box phone pages">
        <button type="button" class="secondary-button" data-box-data-prev ${capability("view")}>Previous</button>
        <span data-box-data-range></span>
        <button type="button" class="secondary-button" data-box-data-next ${capability("view")}>Next</button>
      </nav>
    </section>`;

  const toggle = host.querySelector("[data-box-data-toggle]");
  const panel = host.querySelector("#box-data-table-panel");
  const refresh = host.querySelector("[data-box-data-refresh]");
  const form = host.querySelector("form");
  const status = host.querySelector("[data-box-data-status]");
  const body = host.querySelector("tbody");
  const pager = host.querySelector("nav");
  const range = host.querySelector("[data-box-data-range]");
  const prev = host.querySelector("[data-box-data-prev]");
  const next = host.querySelector("[data-box-data-next]");
  let request, refreshTimer, applied = blank(), offset = 0, total = 0;

  function sync() {
    refresh.disabled = Boolean(request) || !allowed("view");
    prev.disabled = refresh.disabled || offset === 0;
    next.disabled = refresh.disabled || offset + pageSize >= total;
    pager.hidden = total <= pageSize;
  }

  function close() {
    clearTimeout(refreshTimer);
    request?.abort();
    request = null;
    panel.hidden = true;
    toggle.setAttribute("aria-expanded", "false");
    form.reset();
    applied = blank();
    offset = total = 0;
    body.replaceChildren();
    range.textContent = status.textContent = "";
    panel.removeAttribute("aria-busy");
    sync();
  }

  function valid(data, start) {
    const states = pending ? ["accounts"] : ["exported", "legacy"];
    return data?.scope === page && data.offset === start &&
      Number.isSafeInteger(data.total) && data.total >= 0 &&
      Number.isSafeInteger(data.box_count) && data.box_count >= 0 && data.box_count <= data.total &&
      Array.isArray(data.rows) && data.rows.length === Math.min(pageSize, Math.max(data.total - start, 0)) &&
      data.rows.every(row => row && row.item_id && row.box_number && states.includes(row.state));
  }

  async function load(start = 0) {
    if (panel.hidden || !allowed("view")) return;
    request?.abort();
    const activeRequest = new AbortController();
    request = activeRequest;
    const current = () => request === activeRequest && !panel.hidden && allowed("view");
    offset = start;
    panel.setAttribute("aria-busy", "true");
    status.textContent = "Loading box phones…";
    body.replaceChildren();
    range.textContent = "";
    sync();
    try {
      const {data, error} = await window.GREENLOOP_GET_CLIENT().rpc("get_box_data_table_v1", {
        p_page: page, ...applied, p_offset: start, p_limit: pageSize
      }, {signal: activeRequest.signal});
      if (!current()) return;
      if (error) throw error;
      if (!valid(data, start)) throw Error("The phone list could not be verified. Select Refresh to retry.");
      total = data.total;
      if (start > 0 && start >= total) {
        await load(total ? Math.floor((total - 1) / pageSize) * pageSize : 0);
        return;
      }
      status.textContent = total
        ? `${number.format(total)} phones · ${number.format(data.box_count)} ${data.box_count === 1 ? "box" : "boxes"}`
        : "No box phones match these filters.";
      body.innerHTML = data.rows.map((row, index) => {
        const date = new Date(row.box_date);
        const dateText = row.box_date && Number.isFinite(date.getTime()) ? displayDate.format(date) : "—";
        const cells = [start + index + 1, row.box_number, row.imei, row.model,
          row.storage_gb == null ? null : `${row.storage_gb} GB`, row.color, row.final_grade, dateText];
        return `<tr>${cells.map(value => `<td>${esc(value == null || value === "" ? "—" : value)}</td>`).join("")}</tr>`;
      }).join("");
      if (total) range.textContent = `${number.format(start + 1)}–${number.format(start + data.rows.length)} of ${number.format(total)} phones`;
    } catch (error) {
      if (!current()) return;
      total = 0;
      status.textContent = error.message || "Box phones could not load. Select Refresh to retry.";
    } finally {
      if (request === activeRequest) {
        request = null;
        panel.removeAttribute("aria-busy");
        sync();
      }
    }
  }

  toggle.addEventListener("click", () => {
    if (!allowed("view")) return;
    if (!panel.hidden) { close(); return; }
    panel.hidden = false;
    form.hidden = !allowed("search");
    toggle.setAttribute("aria-expanded", "true");
    host.querySelector("h2").focus();
    void load();
  });
  form.addEventListener("submit", event => {
    event.preventDefault();
    if (panel.hidden || !allowed("search")) return;
    const from = form.elements.from.value, to = form.elements.to.value;
    if (from && to && from > to) {
      status.textContent = "From date must be on or before To date.";
      return;
    }
    applied = {p_from: from || null, p_to: to || null, p_search: form.elements.search.value.trim()};
    void load();
  });
  host.querySelector("[data-box-data-clear]").addEventListener("click", () => {
    if (!allowed("search")) return;
    form.reset();
    applied = blank();
    void load();
  });
  refresh.addEventListener("click", () => void load(offset));
  prev.addEventListener("click", () => { if (!request && offset > 0) void load(offset - pageSize); });
  next.addEventListener("click", () => { if (!request && offset + pageSize < total) void load(offset + pageSize); });
  document.addEventListener("greenloop:accounts-section", event => { if (pending && event.detail?.view !== "verify") close(); });
  document.addEventListener("greenloop:workflow-committed", () => {
    if (panel.hidden) return;
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => void load(offset), 200);
  });
  for (const event of ["greenloop:office-locked", "greenloop:signed-out", "greenloop:permissions-changed", "pagehide"]) {
    window.addEventListener(event, close);
  }
  close();
})();
