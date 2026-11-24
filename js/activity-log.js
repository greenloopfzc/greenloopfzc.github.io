(() => {
  "use strict";

  const departments = [
    "Stock Received", "IMEI Entry", "Initial QC", "Issuance", "Lab & Glass", "Parts",
    "Final QC", "B-DEPT", "Ready Stock", "Box Entry", "Accounts", "Export",
    "Return / Replacement", "Chaman Shop", "Damage Reports", "Corrections", "Transfers", "Workflow"
  ];
  const size = 50;
  const formatTime = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: true
  });
  const formatDay = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Dubai", year: "numeric", month: "2-digit", day: "2-digit"
  });
  const number = new Intl.NumberFormat("en-GB");
  const allowed = () => window.GREENLOOP_CAN?.("view", "reports") &&
    window.GREENLOOP_CAN?.("report_activity_log", "reports");

  let mounted;

  function dayRange() {
    const today = formatDay.format(new Date());
    return { p_from: today + "T00:00", p_to: today + "T23:59" };
  }

  function unmount() {
    if (!mounted) return;
    mounted.section.remove();
    mounted = null;
  }

  function message(state, text, error = false) {
    state.status.textContent = text;
    state.status.classList.toggle("is-error", error);
  }

  function cell(tr, value) {
    const td = tr.insertCell();
    td.textContent = value ?? "—";
    return td;
  }

  function render(state, result) {
    const { offset, total, rows } = result;
    state.rows.replaceChildren();
    for (const [i, row] of rows.entries()) {
      const tr = state.rows.insertRow();
      cell(tr, offset + i + 1);
      cell(tr, formatTime.format(new Date(row.occurred_at)));
      const actor = cell(tr, row.actor);
      if (row.login_id && row.login_id !== row.actor) {
        const id = document.createElement("small");
        id.textContent = row.login_id;
        actor.append(id);
      }
      cell(tr, row.department);
      cell(tr, row.action);
      const phone = cell(tr, row.imei);
      const imei = row.current_imei || row.imei;
      if (row.imei && /^\d{15}$/.test(imei) && window.GREENLOOP_CAN?.("view", "imei_search")) {
        const link = document.createElement("a");
        link.href = "imei-search.html?q=" + encodeURIComponent(imei);
        link.textContent = row.imei;
        link.dataset.glCopyIdentifier = "";
        phone.replaceChildren(link);
      }
      if (row.model) {
        const model = document.createElement("small");
        model.textContent = row.model;
        phone.append(model);
      }
      const reference = /^BATCH-/i.test(row.reference ?? "")
        ? window.GREENLOOP_BATCH_LABEL?.(row.reference, {receipt_quantity: row.planned_quantity}) || row.reference
        : row.reference;
      cell(tr, [reference, row.job_number].filter(Boolean).join(" · ") || null);
      const details = cell(tr, "");
      for (const [label, value] of Object.entries(row.details)) {
        const line = document.createElement("small");
        line.textContent = label + " · " + (typeof value === "boolean" ? (value ? "Yes" : "No") : String(value));
        details.append(line);
      }
      if (!details.childElementCount) details.textContent = "—";
    }

    state.count.textContent = total ? number.format(offset + 1) + "–" +
      number.format(offset + rows.length) + " of " + number.format(total) : "0 records";
    state.previous.disabled = offset === 0;
    state.next.disabled = offset + rows.length >= total;
    message(state, rows.length ? "" : "No activity matches these filters.");
  }

  async function load(state, offset = 0) {
    if (state !== mounted || !allowed() || !state.filters) return;
    const ticket = ++state.ticket;
    state.previous.disabled = state.next.disabled = true;
    state.rows.replaceChildren();
    state.section.setAttribute("aria-busy", "true");
    state.count.textContent = "";
    message(state, "Loading activity…");
    try {
      const {data, error} = await window.GREENLOOP_GET_CLIENT().rpc("get_activity_log_v1", {
        ...state.filters, p_offset: offset, p_as_of: state.asOf
      });
      if (state !== mounted || ticket !== state.ticket || !allowed()) return;
      if (error) throw error;
      if (data?.version !== "20261124-activity-log-1" || data.timezone !== "Asia/Dubai" ||
          data.offset !== offset || data.limit !== size || !Number.isSafeInteger(data.total) ||
          data.total < 0 || !Number.isFinite(Date.parse(data.as_of)) ||
          (state.asOf && state.asOf !== data.as_of) || !Array.isArray(data.rows) ||
          data.rows.length !== Math.min(size, Math.max(0, data.total - offset)) ||
          data.rows.some(row => !row.record_key || !row.actor || !row.department || !row.action ||
            !Number.isFinite(Date.parse(row.occurred_at)) || !row.details || typeof row.details !== "object")) {
        throw new Error("Activity Log could not be verified. Refresh and try again.");
      }
      state.asOf = data.as_of;
      if (offset && !data.rows.length) return load(state, Math.max(0, Math.ceil(data.total / size) * size - size));
      state.offset = offset;
      render(state, data);
    } catch (error) {
      if (state === mounted && ticket === state.ticket && allowed()) {
        message(state, error.message || "Activity Log could not be loaded.", true);
      }
    } finally {
      if (state === mounted && ticket === state.ticket) state.section.removeAttribute("aria-busy");
    }
  }

  function submit(state) {
    if (state !== mounted || !allowed()) return;
    const filters = Object.fromEntries(new FormData(state.form));
    for (const name of ["p_user", "p_action", "p_imei"]) filters[name] = filters[name].trim();
    if (!filters.p_from || !filters.p_to || filters.p_from > filters.p_to) {
      return message(state, "From must be on or before To (UAE).", true);
    }
    if (filters.p_imei && !/^\d{15}$/.test(filters.p_imei)) {
      return message(state, "Enter a 15-digit IMEI.", true);
    }
    state.filters = filters;
    state.asOf = null;
    void load(state);
  }

  function mount(host, rowCount) {
    if (!allowed() || mounted?.section.parentNode === host) return;
    unmount();
    rowCount.textContent = "UAE time";
    host.innerHTML = `<section class="activity-log" aria-label="Activity Log">
      <form class="activity-log-filters" data-capability="report_activity_log" data-capability-page="reports">
        <label>From (UAE)<input name="p_from" type="datetime-local" required></label>
        <label>To (UAE)<input name="p_to" type="datetime-local" required></label>
        <label>User<input name="p_user" type="search" maxlength="100" placeholder="Name or login ID"></label>
        <label>Department<select name="p_department"><option value="">All departments</option></select></label>
        <label>Action<input name="p_action" type="search" maxlength="100" placeholder="Search actions"></label>
        <label>IMEI<input name="p_imei" type="search" inputmode="numeric" maxlength="15" placeholder="15-digit IMEI"></label>
        <div class="activity-log-actions">
          <button class="primary-button" type="submit">Apply filters</button>
          <button class="secondary-button" type="button" data-activity-today>Today</button>
        </div>
      </form>
      <p class="activity-log-status" role="status" aria-live="polite"></p>
      <div class="activity-log-scroll" tabindex="0" role="region" aria-label="Activity records">
        <table data-no-table-filters data-preserve-table-layout>
          <thead><tr><th>S.No</th><th>Date &amp; Time (UAE)</th><th>Recorded By</th><th>Department</th>
            <th>Action</th><th>IMEI / Model</th><th>Reference</th><th>Details</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
      <footer class="activity-log-pages">
        <button class="secondary-button" type="button" data-activity-prev disabled>Previous</button>
        <span data-activity-count aria-live="polite"></span>
        <button class="secondary-button" type="button" data-activity-next disabled>Next</button>
      </footer>
    </section>`;
    const section = host.querySelector(".activity-log");
    const form = section.querySelector("form");
    mounted = {
      section, form, rows: section.querySelector("tbody"), status: section.querySelector("[role=status]"),
      count: section.querySelector("[data-activity-count]"), previous: section.querySelector("[data-activity-prev]"),
      next: section.querySelector("[data-activity-next]"), offset: 0, ticket: 0, asOf: null
    };
    const state = mounted;
    for (const label of departments) form.elements.p_department.add(new Option(label, label));
    function today() {
      const range = dayRange();
      form.elements.p_from.value = range.p_from;
      form.elements.p_to.value = range.p_to;
      submit(state);
    }
    form.addEventListener("submit", event => {
      event.preventDefault();
      submit(state);
    });
    section.querySelector("[data-activity-today]").addEventListener("click", today);
    state.previous.addEventListener("click", () => void load(state, Math.max(0, state.offset - size)));
    state.next.addEventListener("click", () => void load(state, state.offset + size));
    today();
  }

  for (const name of ["pagehide", "greenloop:office-locked", "greenloop:signed-out"]) {
    window.addEventListener(name, unmount);
  }
  window.addEventListener("greenloop:permissions-changed", () => {
    if (!allowed()) return unmount();
    if (mounted) {
      mounted.asOf = null;
      void load(mounted);
    }
  });
  window.GREENLOOP_ACTIVITY_LOG = { mount, unmount };
})();
