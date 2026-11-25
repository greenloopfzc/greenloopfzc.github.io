(() => {
  "use strict";

  const size = 50;
  const metrics = [
    ["completed", "Lab Completed", "phones"],
    ["received", "Final QC Received", "received"],
    ["missing", "No QC Receipt Recorded", "missing"],
    ["receipts", "All QC Receipts in Range", "receipts"]
  ];
  const dubaiDay = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Dubai", year: "numeric", month: "2-digit", day: "2-digit"
  });
  const dubaiTime = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: true
  });
  const number = new Intl.NumberFormat("en-GB");
  const allowed = () => window.GREENLOOP_CAN?.("view", "reports") &&
    window.GREENLOOP_CAN?.("report_lab_qc_handover", "reports");
  const canFilter = () => window.GREENLOOP_CAN?.("report_lab_qc_handover_search", "reports");
  let mounted;

  function unmount() {
    mounted?.section.remove();
    mounted = null;
  }

  function message(state, text, error = false) {
    state.status.textContent = text;
    state.status.classList.toggle("is-error", error);
  }

  function describeTime(at, actor) {
    return at ? dubaiTime.format(new Date(at)) + " · " + (actor || "User not recorded") : "—";
  }

  function elapsed(seconds) {
    if (seconds < 60) return "<1 min";
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds / 60) % 60;
    return (hours ? number.format(hours) + "h " : "") + minutes + "m";
  }

  function put(row, value) {
    const cell = row.insertCell();
    cell.textContent = value;
    return cell;
  }

  function buttonFor(state, metric, mode, count, technician) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary-button handover-count";
    button.textContent = number.format(count);
    button.disabled = count === 0;
    button.setAttribute("aria-label", metric + " · " + number.format(count));
    button.addEventListener("click", () => void load(state, mode, 0, technician));
    return button;
  }

  function render(state, data, technician) {
    for (const [name] of metrics) {
      const card = state.section.querySelector('[data-handover-card="' + name + '"]');
      card.querySelector("strong").textContent = number.format(data.totals[name]);
      card.disabled = data.totals[name] === 0;
    }
    const summary = data.mode === "technicians";
    const headings = summary ? ["S.No", "Technician", ...metrics.map(([, label]) => label)]
      : ["S.No", "IMEI / Model", "Technician", "Lab Completed · By", "Final QC Received · By", "Time to QC / Waiting"];
    state.header.replaceChildren(...headings.map(label => {
      const th = document.createElement("th");
      th.scope = "col";
      th.textContent = label;
      return th;
    }));
    const body = state.body;
    body.replaceChildren();
    for (const [index, item] of data.rows.entries()) {
      const row = body.insertRow();
      put(row, number.format(data.offset + index + 1));
      if (summary) {
        put(row, item.technician);
        for (const [key, label, mode] of metrics) {
          put(row, "").append(buttonFor(state, item.technician + " · " + label, mode, item[key], item));
        }
      } else {
        const phone = put(row, "");
        const imei = document.createElement("span");
        imei.textContent = item.imei || "IMEI not recorded";
        if (/^\d{15}$/.test(item.imei || "")) imei.dataset.glCopyIdentifier = "";
        const model = document.createElement("small");
        model.textContent = [item.model, item.storage_gb != null ? item.storage_gb + " GB" : null].filter(Boolean).join(" · ");
        phone.append(imei, model);
        put(row, item.technician);
        put(row, describeTime(item.completed_at, item.completed_by));
        const receipt = put(row, item.received_at ? describeTime(item.received_at, item.received_by) : "No receipt recorded");
        if (!item.received_at) receipt.classList.add("handover-missing");
        put(row, elapsed(item.elapsed_seconds));
      }
    }
    state.mode = data.mode;
    state.offset = data.offset;
    state.technician = technician;
    state.back.hidden = summary;
    const label = summary ? "Technician breakdown" : metrics.find(([, , mode]) => mode === data.mode)[1];
    state.heading.textContent = technician ? technician.technician + " · " + label : label;
    state.results.hidden = false;
    state.previous.disabled = data.offset === 0;
    state.next.disabled = data.offset + data.rows.length >= data.total;
    state.count.textContent = data.rows.length
      ? number.format(data.offset + 1) + "–" + number.format(data.offset + data.rows.length) + " of " + number.format(data.total)
      : "0 records";
    message(state, data.rows.length ? "" : "No handovers match this selection.");
  }

  function valid(data, mode, offset, asOf) {
    const count = value => Number.isSafeInteger(value) && value >= 0;
    const counts = row => row && metrics.every(([key]) => count(row[key])) &&
      row.completed === row.received + row.missing && row.receipts >= row.received;
    return data?.version === "20261125-lab-qc-handover-1" && data.mode === mode && data.offset === offset &&
      Number.isFinite(Date.parse(data.as_of)) && (!asOf || asOf === data.as_of) &&
      counts(data.totals) && count(data.total) && Array.isArray(data.rows) &&
      data.rows.length === Math.min(size, Math.max(0, data.total - offset)) &&
      data.rows.every(row => row && typeof row.technician === "string" && (mode === "technicians"
        ? typeof row.technician_key === "string" && counts(row)
        : Number.isFinite(Date.parse(row.completed_at)) && count(row.elapsed_seconds) &&
          (row.received_at === null || Number.isFinite(Date.parse(row.received_at)))));
  }

  async function load(state, mode = "technicians", offset = 0, technician = null) {
    if (state !== mounted || !allowed()) return;
    const ticket = ++state.ticket;
    const asOf = state.asOf;
    const current = () => state === mounted && ticket === state.ticket && allowed();
    state.results.hidden = true;
    state.body.replaceChildren();
    for (const card of state.cards.querySelectorAll("button")) {
      card.disabled = true;
      card.querySelector("strong").textContent = "—";
    }
    state.section.setAttribute("aria-busy", "true");
    message(state, "Loading handovers…");
    try {
      const { data, error } = await window.GREENLOOP_GET_CLIENT().rpc("get_lab_qc_handover_v1", {
        ...state.filters, p_mode: mode, p_technician: technician?.technician_key || null,
        p_offset: offset, p_as_of: asOf
      });
      if (!current()) return;
      if (error || !valid(data, mode, offset, asOf)) throw new Error("Handover report could not be loaded. Try Refresh.");
      state.asOf = data.as_of;
      if (offset && !data.rows.length) return load(state, mode, 0, technician);
      render(state, data, technician);
    } catch (error) {
      if (current()) message(state, error.message, true);
    } finally {
      if (current()) state.section.removeAttribute("aria-busy");
    }
  }

  function reset(state) {
    state.asOf = null;
    void load(state);
  }

  function mount(host, rowCount) {
    if (!allowed() || mounted?.section.parentNode === host) return;
    unmount();
    rowCount.textContent = "UAE time";
    host.innerHTML = `
      <section class="handover-report" aria-label="Lab to Final QC Handover" data-capability="report_lab_qc_handover" data-capability-page="reports">
        <form class="activity-log-filters">
          <label>From (UAE)<input name="p_from" type="datetime-local" data-capability="report_lab_qc_handover_search" data-capability-page="reports" required></label>
          <label>To (UAE)<input name="p_to" type="datetime-local" data-capability="report_lab_qc_handover_search" data-capability-page="reports" required></label>
          <div class="activity-log-actions">
            <button type="submit" class="primary-button" data-capability="report_lab_qc_handover_search" data-capability-page="reports">View report</button>
            <button type="button" class="secondary-button" data-handover-today>Today</button>
            <button type="button" class="secondary-button" data-handover-refresh>Refresh</button>
          </div>
        </form>
        <div class="handover-cards">${metrics.map(([name, label]) => `
          <button type="button" class="handover-card" data-handover-card="${name}" disabled>
            <span>${label}</span><strong>—</strong>
          </button>`).join("")}</div>
        <p class="handover-note">Final QC Received counts phones from the selected Lab completions. All QC Receipts in Range also includes Lab handovers completed before From. A rework handover counts as a separate visit.</p>
        <p class="activity-log-status" role="status"></p>
        <div data-handover-results hidden>
          <div class="handover-result-heading"><h3></h3><button type="button" class="secondary-button" data-handover-back>Back to technicians</button></div>
          <div class="handover-table" role="region" aria-label="Handover results" tabindex="0">
            <table data-no-table-filters data-no-serial data-preserve-table-layout><thead><tr></tr></thead><tbody></tbody></table>
          </div>
          <div class="activity-log-pages">
            <button type="button" class="secondary-button" data-handover-prev disabled>Previous</button>
            <span data-handover-range aria-live="polite"></span>
            <button type="button" class="secondary-button" data-handover-next disabled>Next</button>
          </div>
        </div>
      </section>`;
    const section = host.querySelector(".handover-report");
    const find = selector => section.querySelector(selector);
    const form = find("form");
    const state = mounted = {
      section, status: find("[role=status]"), cards: find(".handover-cards"),
      results: find("[data-handover-results]"), header: find("thead tr"), body: find("tbody"),
      back: find("[data-handover-back]"), heading: find("h3"), count: find("[data-handover-range]"),
      previous: find("[data-handover-prev]"), next: find("[data-handover-next]"), filters: {},
      offset: 0, ticket: 0, asOf: null
    };
    const submit = find('button[type="submit"]');
    form.elements.p_from.disabled = form.elements.p_to.disabled = submit.disabled = !canFilter();
    function today() {
      const day = dubaiDay.format(new Date());
      form.elements.p_from.value = day + "T00:00";
      form.elements.p_to.value = day + "T23:59";
      state.filters = {};
      reset(state);
    }
    form.addEventListener("submit", event => {
      event.preventDefault();
      if (!canFilter()) return;
      const { value: from } = form.elements.p_from;
      const { value: to } = form.elements.p_to;
      if (!from || !to || from > to) return message(state, "From must be on or before To (UAE).", true);
      state.filters = { p_from: from, p_to: to };
      reset(state);
    });
    find("[data-handover-today]").addEventListener("click", today);
    find("[data-handover-refresh]").addEventListener("click", () => reset(state));
    state.back.addEventListener("click", () => void load(state));
    for (const [name, , mode] of metrics) {
      find('[data-handover-card="' + name + '"]').addEventListener("click", () => void load(state, mode));
    }
    state.previous.addEventListener("click", () => void load(state, state.mode, state.offset - size, state.technician));
    state.next.addEventListener("click", () => void load(state, state.mode, state.offset + size, state.technician));
    today();
  }

  for (const event of ["pagehide", "greenloop:office-locked", "greenloop:signed-out", "greenloop:permissions-changed"]) {
    window.addEventListener(event, unmount);
  }
  window.GREENLOOP_LAB_QC_HANDOVER = { mount, unmount };
})();
