(() => {
  "use strict";

  const get = selector => document.querySelector(selector);
  const api = async (name, args = {}) => {
    const {data, error} = await window.GREENLOOP_GET_CLIENT().rpc(name, args);
    if (error) throw error;
    return data;
  };
  const uaeDateTime = Intl.DateTimeFormat("en-GB", {
    dateStyle:"medium", timeStyle:"short", timeZone:"Asia/Dubai"
  });
  function dateTime(value) {
    return value ? uaeDateTime.format(new Date(value)) : "Not recorded";
  }
  function dateOnly(value) {
    return value ? new Date(value + "T12:00:00Z").toLocaleDateString("en-GB", {
      day:"numeric",month:"short",year:"numeric",timeZone:"Asia/Dubai"
    }) : "Not recorded";
  }
  function customer(row) {
    return window.GREENLOOP_PARTNER_LABEL?.(row.customer_code,row.customer_name,"Not recorded")
      || row.customer_code || "Not recorded";
  }
  function originalBox(row) {
    return row.original_box_number || row.previous_reference || "Not recorded";
  }
  function storage(row) {
    return row.storage_gb == null ? "—" : row.storage_gb + " GB";
  }
  function stageLabel(value) {
    const labels = {
      initial_qc_pending:"Initial QC",laboratory_pending:"Lab & Glass",laboratory_in_progress:"Lab & Glass",
      glass_pending:"Lab & Glass",glass_in_progress:"Lab & Glass",final_qc_pending:"Final QC",
      frame_pending:"B-DEPT",production_pending:"Ready Stock",qc_passed:"Ready Stock",shipped:"Stock Exported"
    };
    return labels[value] || String(value || "").replaceAll("_"," ");
  }
  function showStatus(node, value, error = false) {
    node.textContent = value;
    node.classList.toggle("is-error", error);
  }

  function report(container, rpc, fields, summary) {
    const form = container.querySelector("[data-rma-filter]");
    const tbody = container.querySelector("[data-rma-rows]");
    const status = container.querySelector("[data-rma-status]");
    const previous = container.querySelector("[data-rma-prev]");
    const next = container.querySelector("[data-rma-next]");
    const pageLabel = container.querySelector("[data-rma-page]");
    const from = form.elements.namedItem("from");
    const to = form.elements.namedItem("to");
    let offset = 0, total = 0, generation = 0, pending = false;
    let filters = {p_from:null,p_to:null};

    async function load() {
      const ticket = ++generation;
      previous.disabled = next.disabled = pending = true;
      showStatus(status, "Loading report…");
      try {
        const data = await api(rpc, {...filters,p_offset:offset});
        if (ticket !== generation) return;
        if (!Number.isSafeInteger(data?.total) || data.total < 0 ||
          !Array.isArray(data.rows) || data.rows.length !== Math.min(50,Math.max(0,data.total-offset))) {
          throw new Error("The RMA report could not be verified.");
        }
        total = data.total;
        if (offset && offset >= total) {
          offset = Math.max(0,Math.floor((total-1)/50)*50);
          await load();
          return;
        }
        const rows = data.rows.map((row,index) => {
          const tr = document.createElement("tr");
          for (const value of [offset+index+1,...fields(row)]) {
            const td = tr.insertCell();
            if (value instanceof HTMLElement) td.append(value);
            else td.textContent = value == null ? "—" : String(value);
          }
          return tr;
        });
        if (!rows.length) {
          const tr = document.createElement("tr");
          const td = tr.insertCell();
          td.colSpan = container.querySelectorAll("thead th").length;
          td.textContent = "No phones match the selected dates.";
          rows.push(tr);
        }
        tbody.replaceChildren(...rows);
        pageLabel.textContent = total ? (offset+1) + "–" + Math.min(offset+50,total) + " of " + total : "";
        showStatus(status, summary(data));
        previous.disabled = offset===0;
        next.disabled = offset+50>=total;
      } catch (error) {
        if (ticket !== generation) return;
        tbody.replaceChildren();
        pageLabel.textContent = "";
        showStatus(status,error.message || "RMA report could not load. Apply dates to retry.",true);
      } finally {
        if (ticket === generation) pending = false;
      }
    }

    form.addEventListener("submit", event => {
      event.preventDefault();
      if (from.value && to.value && from.value > to.value) {
        showStatus(status,"The To date must be on or after the From date.",true);
        return;
      }
      filters = {p_from:from.value||null,p_to:to.value||null};
      offset = 0;
      void load();
    });
    container.querySelector("[data-rma-clear]").addEventListener("click", () => {
      form.reset();
      filters = {p_from:null,p_to:null};
      offset = 0;
      void load();
    });
    previous.addEventListener("click", () => {
      if (!pending && offset>=50) { offset-=50; void load(); }
    });
    next.addEventListener("click", () => {
      if (!pending && offset+50<total) { offset+=50; void load(); }
    });
    return {
      reload:load,
      clear:() => {
        ++generation;
        tbody.replaceChildren();
        pageLabel.textContent = "";
        showStatus(status,"");
      }
    };
  }

  const ready = get("#rma-ready-report");
  if (ready) {
    const readyReport = report(ready,"get_rma_ready_report_v1",
      row => [customer(row),row.model,storage(row),row.final_grade,originalBox(row),dateOnly(row.ready_date),row.quantity],
      data => data.phones + " phones ready for re-export");
    let trigger;
    document.addEventListener("click", event => {
      const button = event.target.closest("button[data-rma-ready]");
      if (!button || button.disabled || !window.GREENLOOP_CAN?.("view","ready_stock")) return;
      trigger = button;
      trigger.setAttribute("aria-expanded","true");
      if (!ready.open) ready.showModal();
      void readyReport.reload();
    });
    ready.querySelector("[data-rma-close]").addEventListener("click", () => ready.close());
    ready.addEventListener("close", () => {
      readyReport.clear();
      if (trigger?.isConnected) {
        trigger.setAttribute("aria-expanded","false");
        trigger.focus();
      }
    });
    document.addEventListener("greenloop:ready-stock-refreshed", () => {
      if (ready.open) void readyReport.reload();
    });
    for (const event of ["greenloop:office-locked","greenloop:signed-out"]) {
      window.addEventListener(event, () => { if (ready.open) ready.close(); readyReport.clear(); });
    }
  }

  if (!get("#customer-rma")) return;
  const imei = get("#rma-imei");
  const mode = get("#rma-mode");
  const lookup = get("#rma-lookup");
  const preview = get("#rma-preview");
  const intake = get("#rma-receive");
  const reason = get("#rma-reason");
  const reference = get("#rma-reference");
  const intakeStatus = get("#rma-intake-status");
  const sidebar = get("#sidebar");
  const backdrop = get("#menu-backdrop");
  let reviewed = null, unsaved = null, revision = 0, saving = false;
  const history = report(get("#rma-case-report"),"get_rma_cases_v1", row => {
    const imeiLink = document.createElement("a");
    imeiLink.href = "imei-search.html?q=" + encodeURIComponent(row.imei);
    imeiLink.textContent = row.imei;
    return [window.GREENLOOP_CAN?.("view","imei_search") ? imeiLink : row.imei,
      row.model,storage(row),customer(row),originalBox(row),dateTime(row.recorded_at),row.received_by,
      row.status,row.reexport_box,row.reason];
  }, data => data.total + " received · " + data.in_repair + " in repair · " + data.ready +
    " RMA ready · " + data.reexported + " re-exported · " + data.pending + " pending");

  function resetReview(message = "") {
    ++revision;
    reviewed = unsaved = null;
    preview.replaceChildren();
    preview.hidden = intake.hidden = true;
    intake.reset();
    showStatus(intakeStatus,message);
  }
  function renderReview(data, opening) {
    const items = [
      ["IMEI",data.imei],["Model",data.model],["GB",storage(data)],
      ["Stage",stageLabel(data.current_stage)],["Original Export Box",originalBox(data)],
      ["Original Export · UAE",dateTime(data.original_export_at)],["Customer",customer(data)]
    ];
    preview.replaceChildren(...items.map(([label,value]) => {
      const wrapper = document.createElement("div");
      const key = document.createElement("dt");
      const content = document.createElement("dd");
      key.textContent = label;
      content.textContent = value || "Not recorded";
      wrapper.append(key,content);
      return wrapper;
    }));
    preview.hidden = false;
    intake.hidden = !window.GREENLOOP_CAN?.("entry","stock_received");
    get("#rma-reference-field").hidden = !opening;
    if (!intake.hidden) reason.focus();
  }

  imei.addEventListener("input", () => {
    imei.value = imei.value.replace(/\D/g,"").slice(0,15);
    resetReview();
  });
  mode.addEventListener("change", () => {
    resetReview();
    get("#rma-intake-title").textContent = mode.value==="opening" ? "Mark Opening Stock RMA" : "Receive RMA";
  });
  intake.addEventListener("input", () => { unsaved = null; });
  lookup.addEventListener("submit", async event => {
    event.preventDefault();
    if (saving || !/^\d{15}$/.test(imei.value)) return;
    resetReview("Checking IMEI…");
    const ticket = revision;
    const args = {p_imei:imei.value,p_opening_stock:mode.value==="opening"};
    try {
      const data = await api("get_rma_intake_v1",args);
      if (ticket !== revision) return;
      if (data?.imei !== args.p_imei || !/^[a-f0-9]{32}$/.test(data.context_token)) {
        throw new Error("The phone could not be verified.");
      }
      reviewed = {...args,p_context_token:data.context_token};
      renderReview(data,args.p_opening_stock);
      showStatus(intakeStatus,"");
    } catch (error) {
      if (ticket === revision) showStatus(intakeStatus,error.message||"IMEI could not be reviewed.",true);
    }
  });

  intake.addEventListener("submit", async event => {
    event.preventDefault();
    if (!reviewed || saving || !window.GREENLOOP_CAN?.("entry","stock_received")) return;
    const reasonText = reason.value.trim();
    if (reasonText.length<2) { showStatus(intakeStatus,"Enter a return reason.",true); reason.focus(); return; }
    unsaved ||= {...reviewed,p_reason:reasonText,
      p_previous_reference:reviewed.p_opening_stock ? reference.value.trim()||null : null,
      p_request_id:crypto.randomUUID()};
    const command = unsaved;
    const ticket = revision;
    const controls = [...lookup.elements,...intake.elements,mode].map(control=>[control,control.disabled]);
    for (const [control] of controls) control.disabled = true;
    saving = true;
    showStatus(intakeStatus,"Saving RMA…");
    try {
      const result = await api("receive_customer_rma_v1",command);
      if (ticket !== revision) return;
      if (!result?.id) throw new Error("Save could not be confirmed. Retry the same RMA.");
      imei.value = "";
      resetReview(command.p_opening_stock ? "Opening Stock phone marked as RMA." : "RMA received and sent to Initial QC.");
      void history.reload();
    } catch (error) {
      if (ticket === revision) showStatus(intakeStatus,error.message||"Save could not be confirmed. Retry the same RMA.",true);
    } finally {
      saving = false;
      for (const [control,disabled] of controls) control.disabled = disabled;
      if (!reviewed && !imei.value) imei.focus();
    }
  });

  function menu(open) {
    sidebar.classList.toggle("is-open",open);
    backdrop.hidden = !open;
    document.body.classList.toggle("menu-open",open);
  }
  get("#open-menu").addEventListener("click", () => menu(true));
  get("#close-menu").addEventListener("click", () => menu(false));
  backdrop.addEventListener("click", () => menu(false));

  for (const event of ["greenloop:office-locked","greenloop:signed-out"]) {
    window.addEventListener(event, () => { resetReview(); history.clear(); });
  }
  (async () => {
    await window.GREENLOOP_ACCESS_READY;
    if (!window.GREENLOOP_CAN?.("view","stock_received")) return;
    void history.reload();
    if (window.GREENLOOP_CAN?.("entry","stock_received")) {
      const admin = await api("has_role",{required_roles:["owner","super_admin"]}).catch(() => false);
      get("#rma-mode-field").hidden = admin !== true;
    }
  })();
})();
