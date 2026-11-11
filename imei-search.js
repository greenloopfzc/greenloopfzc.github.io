(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#history-app");
  const permissionMessage = document.querySelector("#permission-message");
  const form = document.querySelector("#imei-search-form");
  const query = document.querySelector("#imei-query");
  const searchButton = document.querySelector("#search-button");
  const message = document.querySelector("#search-message");
  const result = document.querySelector("#history-result");
  const header = document.querySelector("#history-device");
  const body = document.querySelector("#history-rows");
  const summary = document.querySelector("#history-summary");
  const count = document.querySelector("#history-record-count");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");
  const requestedQuery = new URLSearchParams(window.location.search).get("q") || "";
  const missing = "Not recorded";
  const stages = {
    stock_received: "Stock Received", receiving: "Stock Received", receipt: "Stock Received",
    imei_entry: "IMEI Entry", intake: "IMEI Entry", job_created: "Job opened",
    initial_qc: "Initial QC", parts: "Parts", part_request: "Parts", part_issue: "Parts",
    part_installation: "Parts", manual_part: "Parts", part_return: "Parts return",
    laboratory: "Laboratory", laboratory_work: "Laboratory", lab_glass: "Lab & Glass", glass: "Glass",
    frame: "B-DEPT", frame_department: "B-DEPT", final_qc: "Final QC",
    ready_stock: "Ready Stock", rework: "Rework", export: "Export Boxes", export_box: "Export Boxes",
    stock_return: "Stock Return", supplier_return: "Stock Return", movement: "Location change",
    correction: "Data correction", job: "Job history", event: "Recorded activity",
    assignment: "Technician assignment", technician: "Technician time", workflow: "Process update"
  };
  let client;
  let allowed = false;
  let toastTimer;
  let searchWidget;
  let receiptItems=[];
  let receiptId="";
  let receiptOffset=0;
  const receiptResult=document.createElement("section");
  receiptResult.id="history-receipt"; receiptResult.className="history-receipt"; receiptResult.hidden=true;
  result.before(receiptResult);
  let searchVersion = 0;

  function getClient() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
  function scalar(value) { return ["string", "number", "boolean"].includes(typeof value) ? String(value).trim() : ""; }
  function escapeHtml(value) { return scalar(value).replace(/[&<>'"]/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function label(value) {
    return window.GREENLOOP_DEPT_NAME(scalar(value).replaceAll("_", " ").replace(/\b\w/g, character => character.toUpperCase()).replace(/\bQc\b/g, "QC").replace(/\bImei\b/g, "IMEI")) || missing;
  }
  function number(value) {
    if (value === null || value === undefined || typeof value === "boolean" || String(value).trim() === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  function money(value) {
    const amount = number(value);
    return amount === null ? missing : `AED ${amount.toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }
  function timestamp(value) {
    if (!scalar(value)) return null;
    const parsed = new Date(value).getTime();
    return Number.isFinite(parsed) ? parsed : null;
  }
  function date(value, time = false) {
    const stamp = timestamp(value);
    if (stamp === null) return missing;
    return new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", ...(time ? { hour: "numeric", minute: "2-digit", hour12: true } : { day: "2-digit", month: "short", year: "numeric" }) }).format(new Date(stamp));
  }
  function duration(value) {
    const seconds = number(value);
    if (seconds === null || seconds < 0) return missing;
    if (seconds < 60) return "Less than 1 min";
    const minutes = Math.floor(seconds / 60);
    const days = Math.floor(minutes / 1440);
    const hours = Math.floor(minutes % 1440 / 60);
    const rest = minutes % 60;
    return [days ? `${days} ${days === 1 ? "day" : "days"}` : "", hours ? `${hours} hr` : "", rest ? `${rest} min` : ""].filter(Boolean).join(" ");
  }
  function tone(value, stage = "") {
    const state = scalar(value).toLowerCase().replace(/[ -]/g, "_");
    if (/^(?:fail|failed|damaged|faulty|scrapped|rejected)$/.test(state)) return "danger";
    if (/^(?:pass|passed|qc_passed|completed|ready|ready_stock|shipped|closed)$/.test(state)) return "success";
    if (/pending|waiting|returned_to_supplier|return_requested|rework|hold|paused/.test(state)) return "warning";
    if (/in_progress|working|issued|assigned/.test(state)) return "info";
    if (/laboratory|lab_glass|glass|frame/.test(stage)) return "repair";
    if (/parts|part_|export/.test(stage)) return "info";
    if (/stock_return|supplier_return|rework/.test(stage)) return "warning";
    return "neutral";
  }
  function absent() { return `<span class="journey-missing">${missing}</span>`; }
  function badge(value) { return scalar(value) ? `<span class="journey-badge" data-tone="${tone(value)}">${escapeHtml(label(value))}</span>` : ""; }
// Pure presentation grouping. Requires scalar(value) and timestamp(value).
// Rows remain untouched: assignment.actor is the assigned technician; movement
// actor is the mover; a service review is a requirement, not completed work.
function buildStageSections(sortedRows) {
  const text = value => scalar(value).toLowerCase().replace(/[_–—]+/g, " ").replace(/\s+/g, " ").trim();
  const value = (row, label) => (Array.isArray(row.details) ? row.details : []).find(item => text(item?.label) === text(label))?.value;
  const titles = {
    stock_received: "Stock Received", imei_entry: "IMEI Entry", initial_qc: "Initial QC",
    lab_glass: "Lab & Glass", final_qc: "Final QC", frame: "B-DEPT",
    ready_stock: "Ready Stock", export: "Export", stock_return: "Stock Return",
    rework: "Rework", parts: "Parts", other: "Other recorded details"
  };
  const department = raw => {
    const name = text(raw);
    if (/^(?:lab|laboratory|glass|lab & glass|lab and glass)$/.test(name)) return "lab_glass";
    if (/^(?:initial qc|initial[ -]?qc department)$/.test(name)) return "initial_qc";
    if (/^(?:final[ -]?qc|final qc department)$/.test(name)) return "final_qc";
    if (/^(?:frame|frame department)$/.test(name)) return "frame";
    if (/^(?:ready stock|ready-stock|production)$/.test(name)) return "ready_stock";
    if (/^(?:parts|parts department)$/.test(name)) return "parts";
    if (/^(?:receiving|stock received)$/.test(name)) return "stock_received";
    if (/^(?:outbound|outbound \/ dispatched|export|export boxes)$/.test(name)) return "export";
    return "";
  };
  function phase(row) {
    const prefix = scalar(row.id).split(":")[0], stage = text(row.stage), title = text(row.title);
    if (/^b-dept/.test(title)) return "frame";
    if (/^(?:receipt|individual-receipt)$/.test(prefix)) return "stock_received";
    if (prefix === "entry") return "imei_entry";
    if (prefix === "initial-qc") return "initial_qc";
    if (/^(?:laboratory|glass)-(?:start|complete)$/.test(prefix) || prefix === "service") return "lab_glass";
    if (prefix === "final-qc") return "final_qc";
    if (prefix === "frame") return "frame";
    if (/^(?:export-box|dispatch)$/.test(prefix)) return "export";
    if (prefix === "supplier-return") return "stock_return";
    if (/^(?:part-request|part-issue|part-installation|manual-part|part-return)$/.test(prefix)) return "parts";
    if (prefix === "assignment" || stage === "assignment" || /^(?:laboratory technician planned|technician planned)$/.test(title)) return "assignment";
    if (/^timer-(?:start|stop)$/.test(prefix) || stage === "technician") return "timer";
    if (prefix === "movement" || stage === "movement") return "movement";
    if (stage === "rework") return "rework";
    if (/^(?:stock return|supplier return)$/.test(stage)) return "stock_return";
    if (stage === "ready stock") return "ready_stock";
    if (/^(?:(?:laboratory|glass) received|phone received at (?:laboratory|glass))$/.test(title)) return "lab_glass";
    if (title === "phone received at final qc") return "final_qc";
    // Transfer records belong to the sending QC section. They never prove receipt.
    if (/^initial qc (?:sent|direct to frame|lab parts skipped|parallel routing)/.test(title)) return "initial_qc";
    if (/^final qc (?:sent|routed|received|passed|failed)/.test(title)) return "final_qc";
    if (/^(?:laboratory|glass) (?:work |service )?(?:started|completed|paused|resumed|reviewed)/.test(title)) return "lab_glass";
    if (/^laboratory (?:manually recorded installed parts|line saved)/.test(title)) return "lab_glass";
    if (/^(?:stock received|receiving|receipt)$/.test(stage)) return "stock_received";
    if (/^(?:imei entry|intake|job created)$/.test(stage)) return "imei_entry";
    if (stage === "initial qc") return "initial_qc";
    if (stage === "final qc" && /(?:pass|fail|inspection|received|sent|routed)/.test(title)) return "final_qc";
    if (/^(?:frame|frame department)$/.test(stage) && /(?:pass|fail|inspection|work|received)/.test(title)) return "frame";
    if (/^(?:laboratory|glass|lab glass|laboratory work)$/.test(stage) && /(?:work|repair|part|service|technician|complet|start|pause|resume)/.test(title)) return "lab_glass";
    if (/^(?:parts|part request|part issue|part installation|manual part|part return)$/.test(stage) && (Array.isArray(row.parts) && row.parts.length || /(?:part|request|issue|install|return)/.test(title))) return "parts";
    if (/^(?:export|export box)$/.test(stage) && /(?:export|dispatch|shipped|box)/.test(title)) return "export";
    return "other";
  }
  const entries = (Array.isArray(sortedRows) ? sortedRows : []).map((row, index) => ({
    row, index, at: timestamp(row?.occurred_at), job: scalar(row?.job_number), phase: phase(row || {})
  }));
  const dated = entry => entry.at !== null && Number.isFinite(entry.at);
  const sameJob = (a, b) => Boolean(a.job) && a.job === b.job;
  const ordered = entries.filter(dated).sort((a, b) => a.at - b.at || a.index - b.index);
  // Same job and timestamp only: QC/B-DEPT, then Ready, then Export. Unrelated
  // equal-time rows keep their original slots; no timestamps are altered.
  const rank = { final_qc: 0, frame: 0, ready_stock: 1, export: 2 }, ties = new Map();
  ordered.forEach((entry, index) => {
    if (!entry.job || rank[entry.phase] === undefined) return;
    const key = `${entry.job}\u0000${entry.at}`;
    if (!ties.has(key)) ties.set(key, []);
    ties.get(key).push(index);
  });
  for (const indexes of ties.values()) {
    const sorted = indexes.map(index => ordered[index]).sort((a, b) => rank[a.phase] - rank[b.phase] || a.index - b.index);
    indexes.forEach((index, position) => { ordered[index] = sorted[position]; });
  }
  const sections = [], other = [];
  let current = null;
  function sameTimeQc(entry) {
    const keys = new Set(ordered.filter(candidate => sameJob(candidate, entry) && candidate.at === entry.at && ["initial_qc", "final_qc"].includes(candidate.phase)).map(candidate => candidate.phase));
    return keys.size === 1 ? [...keys][0] : "";
  }
  function resolve(entry) {
    const key = entry.phase, row = entry.row;
    const currentJob = current && sameJob(current, entry);
    const ownerQc = sameTimeQc(entry);
    if (key === "parts") {
      if (currentJob && current.key === "lab_glass") return "lab_glass";
      return ownerQc || "parts";
    }
    if (key === "assignment") {
      if (ownerQc) return ownerQc;
      if (currentJob && ["initial_qc", "lab_glass", "final_qc", "frame", "rework"].includes(current.key)) return current.key;
      return department(value(row, "Department")) || "other";
    }
    if (key === "timer") {
      return currentJob && ["initial_qc", "lab_glass", "final_qc", "frame", "rework"].includes(current.key) ? current.key : "other";
    }
    if (key === "movement") {
      if (ownerQc) return ownerQc;
      // A later transfer remains with its sending phase until explicit work or
      // receipt starts the next phase. The original mover/date stay on this row.
      if (currentJob) return current.key;
      return department(value(row, "From")) || department(value(row, "To")) || "other";
    }
    return key;
  }
  for (const entry of ordered) {
    const key = resolve(entry);
    if (key === "other") { other.push(entry); continue; }
    const fresh = ["stock_received", "imei_entry", "rework"].includes(entry.phase);
    if (!current || current.key !== key || !sameJob(current, entry) || fresh) {
      current = { key, title: titles[key], job: entry.job, rows: [] };
      sections.push(current);
    }
    current.rows.push(entry.row);
  }
  other.push(...entries.filter(entry => !dated(entry)));
  if (other.length) sections.push({ key: "other", title: titles.other, rows: other.sort((a, b) => (dated(a) ? a.at : Infinity) - (dated(b) ? b.at : Infinity) || a.index - b.index).map(entry => entry.row) });
  return sections.map(section => ({ key: section.key, title: section.title, rows: section.rows }));
}

  function visibleDetails(row) {
    return (Array.isArray(row.details) ? row.details : []).filter(item => item && scalar(item.label) && scalar(item.value) &&
      (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES || !/^(?:supplier|customer)(?: company)? name$/i.test(scalar(item.label))));
  }
  function field(row, ...names) {
    for (const name of names) {
      const value = scalar(visibleDetails(row).find(item => scalar(item.label).toLowerCase() === name.toLowerCase())?.value);
      if (value) return value;
    }
    return "";
  }
  function place(value) {
    const names = { LAB:"Lab & Glass", LABORATORY:"Lab & Glass", LAB_GLASS:"Lab & Glass", GLASS:"Lab & Glass", "FINAL-QC":"Final QC", FINAL_QC:"Final QC", "INITIAL-QC":"Initial QC", INITIAL_QC:"Initial QC", FRAME:"B-DEPT", PRODUCTION:"Ready Stock", "PRODUCTION DEPARTMENT":"Ready Stock", READY:"Ready Stock", "READY-STOCK":"Ready Stock", READY_STOCK:"Ready Stock", PARTS:"Parts", OUTBOUND:"Export" };
    return window.GREENLOOP_DEPT_NAME(names[scalar(value).toUpperCase()] || scalar(value));
  }
  const safe = value => escapeHtml(scalar(value) || missing);
  function moment(value) { return timestamp(value) === null ? missing : `${date(value)}, ${date(value,true)}`; }
  function fact(name, value) { return `<strong>${escapeHtml(name)}:</strong> ${safe(value)}`; }
  function datedAction(name, row, actorLabel="By") { return `${fact(name,moment(row.occurred_at))} · ${fact(actorLabel,row.actor)}`; }
  function route(row) {
    const explicit = field(row,"To","Next step","Next department");
    if (explicit) return place(explicit);
    const title = scalar(row.title).toLowerCase().replaceAll("_"," ");
    if (/parallel routing|parts and laboratory/.test(title)) return "Parts and Laboratory";
    if (/to frame|routed to frame/.test(title)) return "B-DEPT";
    if (/to final qc|lab parts skipped/.test(title)) return "Final QC";
    if (/to ready stock/.test(title)) return "Ready Stock";
    if (/to laboratory/.test(title)) return "Laboratory";
    return "";
  }
  function isReceive(row) {
    const title = scalar(row.title).toLowerCase().replaceAll("_"," ");
    return /^(?:final qc received|phone received at final qc|laboratory received|glass received|phone received at laboratory|phone received at glass)/.test(title);
  }
  function partLines(row) {
    const parts = (Array.isArray(row.parts) ? row.parts : []).filter(part => part && typeof part === "object");
    const id = scalar(row.id), title = scalar(row.title).toLowerCase();
    const action = id.startsWith("part-request:") || /requested/.test(title) ? "Part requested" : id.startsWith("part-issue:") || /issued/.test(title) ? "Part issued" : id.startsWith("part-return:") || /returned/.test(title) ? "Part returned" : "Part installed";
    return parts.map(part => {
      const qty = number(part.quantity), unit = number(part.unit_cost), total = number(part.total_cost);
      const price = unit === null ? "Price not recorded" : `${money(unit)} each${total === null ? "" : `; total ${money(total)}`}`;
      return `${fact(action,`${scalar(part.name) || "Part name not recorded"}${qty === null ? "" : ` × ${qty}`}`)} — ${escapeHtml(price)} · ${escapeHtml(moment(row.occurred_at))} · ${fact(row.stage==="assignment"?"Assigned technician":row.automatic_direct_bdept?"Transfer action by":"By",row.actor)}`;
    });
  }
  function rowBullets(row, sectionKey) {
    const id=scalar(row.id), stage=scalar(row.stage), title=scalar(row.title), lower=title.toLowerCase().replaceAll("_"," ");
    const details=visibleDetails(row), lines=[];
    const add=(name,value)=>{if(scalar(value))lines.push(fact(name,value));};
    const transfer=()=>{
      const to=route(row), tech=field(row,"Technician","Assigned technician");
      if(to)lines.push(`${fact("Transferred to",to)} · ${escapeHtml(moment(row.occurred_at))} · ${fact("Sent by",row.actor)}${tech ? ` · ${fact("Technician",tech)}` : ""}`);
      return Boolean(to);
    };
    if (/^(receipt:|individual-receipt:)/.test(id) || stage==="stock_received") {
      lines.push(datedAction("Received",row,"Received by"));
    } else if(id.startsWith("entry:") || stage==="imei_entry") {
      lines.push(datedAction("IMEI entered",row,"Entered by"));
    } else if(id.startsWith("assignment:")) {
      lines.push(`${fact("Assigned technician",row.actor)}${field(row,"Department") ? ` · ${escapeHtml(place(field(row,"Department")))}` : ""} · ${escapeHtml(moment(row.occurred_at))}`);
    } else if(isReceive(row)) {
      lines.push(datedAction("Received",row,"Received by"));
    } else if(stage==="movement" || /initial qc.*(?:sent|direct to|lab parts skipped|parallel routing)|final qc.*(?:sent|routed)/.test(lower)) {
      if(!transfer())lines.push(datedAction(title || "Transferred",row,"Sent by"));
    } else if(id.startsWith("initial-qc:") || stage==="initial_qc") {
      lines.push(datedAction("Checked",row,"Checked by"));
      add("Problems found",field(row,"Findings","Issue found","Problems") || missing);
      add("Work required",field(row,"Required work","Work required"));
      add("Technician",field(row,"Assigned technician","Technician"));
      add("Next department",route(row));
    } else if(id.startsWith("service:") || /service.*review|service.*required|service.*request/.test(lower)) {
      const service=field(row,"Service") || title;
      lines.push(`${fact("Service review",service)}${field(row,"Required") ? ` · ${fact("Required",field(row,"Required"))}` : ""} · ${escapeHtml(moment(row.occurred_at))} · ${fact("Reviewed by",row.actor)}`);
    } else if((row.parts || []).length) {
      lines.push(...partLines(row));
      add("Condition",field(row,"Condition"));
      if(field(row,"Condition").toLowerCase()==="restocked")add("Return effect","Returned to inventory; excluded from consumed parts cost");
      add("Reason",field(row,"Reason"));
      add("Recorded by",field(row,"Recorded by"));
    } else if(/^(laboratory|glass)-start:/.test(id) || /work started/.test(lower)) {
      const structured=/^(laboratory|glass)-start:/.test(id);
      lines.push(datedAction(stage==="glass" ? "Glass work started" : "Work started",row,structured ? "Technician" : "Started by"));
      if(!structured)add("Assigned technician",field(row,"Technician"));
    } else if(/^(laboratory|glass)-complete:/.test(id) || /(?:laboratory|glass).*completed/.test(lower)) {
      const structured=/^(laboratory|glass)-complete:/.test(id);
      lines.push(datedAction(stage==="glass" ? "Glass work completed" : "Work completed",row,structured ? "Technician" : "Completed by"));
      if(!structured)add("Assigned technician",field(row,"Technician"));
      add("Work done",field(row,"Work done"));
      add("Service completed",field(row,"Service"));
      const seconds=number(row.duration_seconds);
      lines.push(fact(scalar(row.duration_label) || "Completion time",seconds===null ? missing : duration(seconds)));
      if(number(row.cost)!==null && number(row.cost)!==0)add("Materials cost",money(row.cost));
      if(/sent|routed|moved/i.test(title))transfer();else add("Next department",route(row));
    } else if(id.startsWith("final-qc:") || id.startsWith("frame:") || ((stage==="final_qc" || stage==="frame") && /pass|fail|inspect/.test(lower))) {
      const result=scalar(row.status) || field(row,"Result");
      lines.push(`${datedAction("Checked",row,"Checked by")} · ${fact("Result",result ? label(result) : missing)}`);
      if(/fail/i.test(result))add("Failed because",field(row,"Failure reason","Reason","Notes") || missing);
      add("Final grade",field(row,"Final grade"));
      add("Battery health",field(row,"Final battery health","Battery health"));
      add("Checks",field(row,"Checks"));
      add("Next department",route(row) || place(field(row,"Failure department")));
    } else if(stage==="ready_stock") {
      lines.push(datedAction("Moved to Ready Stock",row));
    } else if(id.startsWith("export-box:") || /export.*box|box.*scan/.test(lower)) {
      lines.push(`${datedAction("Scanned into export box",row)}${field(row,"Box number") ? ` · ${fact("Box",field(row,"Box number"))}` : ""}`);
    } else if(id.startsWith("dispatch:")) {
      lines.push(datedAction("Dispatched",row)); add("Destination",field(row,"Destination"));
    } else if(stage==="rework") {
      lines.push(datedAction("Sent for rework",row)); add("Reason",field(row,"Reason"));
      add("Department",place(field(row,"Department","Next department"))); add("Technician",field(row,"Technician"));
    } else {
      lines.push(datedAction(title || "Saved activity",row));
      for(const item of details.filter(item=>!/^(rework cycle|cost basis|timing basis|record type|current request status|stage meaning)$/i.test(item.label)))add(item.label,item.value);
    }
    return lines;
  }
  function renderRecord(row,key) {
    return rowBullets(row,key).map((line,index)=>`<li${index===0 ? ` data-record-id="${escapeHtml(row.id)}"` : ""}>${line}</li>`).join("");
  }
  function renderSection(section,index) {
    const receiveNeeded=["lab_glass","final_qc"].includes(section.key);
    const noReceive=receiveNeeded && !section.rows.some(isReceive);
    const supplemental=section.rows.filter(row=>/^(timer-start:|timer-stop:)/.test(scalar(row.id)));
    const primary=section.rows.filter(row=>!supplemental.includes(row));
    const bullets=`${noReceive ? '<li class="history-missing"><strong>Received date/time &amp; received by:</strong> Not recorded</li>' : ""}${primary.map(row=>renderRecord(row,section.key)).join("")}`;
    if(section.key==="other")return `<details class="history-other"><summary>Other saved entries</summary><ul class="history-bullets">${section.rows.map(row=>renderRecord(row,section.key)).join("")}</ul></details>`;
    return `<section class="history-stage" data-stage="${escapeHtml(section.key)}" aria-labelledby="history-stage-${index}"><h3 id="history-stage-${index}">${escapeHtml(section.title)}</h3><ul class="history-bullets">${bullets}</ul>${supplemental.length ? `<details class="history-other"><summary>Timer records</summary><ul class="history-bullets">${supplemental.map(row=>renderRecord(row,section.key)).join("")}</ul></details>` : ""}</section>`;
  }
  function journeyMoment(value) {
    const stamp=timestamp(value);
    return stamp===null ? missing : new Intl.DateTimeFormat("en-GB",{timeZone:"Asia/Dubai",day:"2-digit",month:"short",year:"numeric",hour:"numeric",minute:"2-digit",second:"2-digit",hour12:true}).format(new Date(stamp));
  }
  function currentStage(device) {
    // Match the workflow status names used by Stock Journey. Do not infer the
    // current stage from an older job's last history event.
    if (scalar(device.current_status).toLowerCase() === "returned_to_supplier") return "Returned to Supplier";
    if (scalar(device.current_stage)) return scalar(device.current_stage);
    const status=scalar(device.current_status).toLowerCase();
    const names={received:"IMEI Entry — saved",initial_qc_pending:"Initial QC",initial_qc_completed:"Initial QC — completed",no_work_required:"Initial QC — no work required",parts_pending:"Parts",laboratory_pending:"Lab & Glass",laboratory_in_progress:"Lab & Glass",glass_pending:"Lab & Glass",glass_in_progress:"Lab & Glass",frame_pending:"B-DEPT",frame_in_progress:"B-DEPT",final_qc_pending:"Final QC",qc_failed:"Final QC — failed",qc_passed:"Ready Stock",production_pending:"Ready Stock",production_completed:"Ready Stock",ready_for_packing:"Ready Stock",ready_for_shipment:"Ready Stock",shipped:"Export / Shipped",supplier_return_requested:"Stock Return — requested",return_pending:"Stock Return — pending",returned_to_supplier:"Returned to supplier"};
    return names[status] || scalar(device.current_status);
  }
  function renderActivity(row,children="") {
    const details=visibleDetails(row).map(item=>`<li>${fact(item.label,/^(From|To|Department|Next step|Next department|Destination|Reason|Movement reason|Notes|Original recorded title)$/i.test(item.label)?window.GREENLOOP_DEPT_NAME(item.value):item.value)}</li>`);
    for(const part of (Array.isArray(row.parts)?row.parts:[])) {
      details.push(`<li>${fact("Part",[scalar(part.name),number(part.quantity)===null ? "" : "× "+part.quantity,number(part.unit_cost)===null ? "Price not recorded" : money(part.unit_cost)+" / part"].filter(Boolean).join(" · "))}</li>`);
    }
    if(number(row.duration_seconds)!==null)details.push(`<li>${fact(row.duration_label || "Recorded time",duration(row.duration_seconds))}</li>`);
    return `<li class="history-activity-record" data-record-id="${escapeHtml(row.id)}"><h4>${safe(window.GREENLOOP_DEPT_NAME(row.display_title || row.title || stages[row.stage] || row.stage))}</h4><p>${safe(journeyMoment(row.occurred_at))} · ${fact(row.stage==="assignment"?"Assigned technician":row.automatic_direct_bdept?"Transfer action by":"By",row.actor)}${scalar(row.status) ? " · "+fact(row.automatic_direct_bdept?"Original system status":"Status",label(row.status)) : ""}${scalar(row.job_number) ? " · "+fact("Job",row.job_number) : ""}</p>${details.length ? `<ul class="history-bullets">${details.join("")}</ul>` : ""}${children}</li>`;
  }
  function renderActivityList(rows) {
    const attached=new Map(),children=new Set();
    for(const row of rows.filter(r=>r.automatic_direct_bdept)){
      const anchor=rows.find(r=>r.direct_bdept_transfer&&r.job_number&&r.job_number===row.job_number&&timestamp(r.occurred_at)===timestamp(row.occurred_at));
      if(anchor){if(!attached.has(anchor))attached.set(anchor,[]);attached.get(anchor).push(row);children.add(row);}
    }
    return rows.filter(r=>!children.has(r)).map(row=>{
      const items=attached.get(row)||[];
      const nested=items.length?`<details class="history-system-records"><summary>Automatic routing records (${items.length})</summary><ol class="history-activity-list">${items.map(r=>renderActivity(r)).join("")}</ol></details>`:"";
      return renderActivity(row,nested);
    }).join("");
  }
  function renderBasicTable(device,rows) {
    const names=Boolean(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES);
    const receipt=[...rows].reverse().find(row=>row.stage==="stock_received") || {};
    const supplierCode=GREENLOOP_RECEIPTS.label("imei_search",device.imei_1,scalar(device.supplier_code)||field(receipt,"Supplier code","Supplier"),null,null);
    const supplierName=names ? scalar(device.supplier_name) || field(receipt,"Supplier name") : "";
    const values=[
      ["Model",[device.brand,device.model].map(scalar).filter(Boolean).join(" · ")],["Color",device.color],
      ["GB",number(device.storage_gb)===null ? "" : `${device.storage_gb} GB`],["Supplier",supplierName || supplierCode],
      ["IMEI 1",device.imei_1],["IMEI 2",device.imei_2],
      ["Serial number",device.serial_number],["Supplier code",supplierCode],
      ["Stock/Batch No",field(receipt,"Receipt","Batch")],["Invoice No",field(receipt,"Invoice")],["Stock received",receipt.occurred_at ? moment(receipt.occurred_at) : ""],
      ["Device number",device.device_number]
    ];
    const stage = currentStage(device);
    const currentLocation = scalar(device.current_status).toLowerCase() === "returned_to_supplier"
      ? "Returned to Supplier"
      : stage.toLowerCase() === "lab & glass issuance" ? stage : place(device.current_location);
    values.push(["Current location", stage ? place(stage) : currentLocation]);
    if(device.initial_battery_health!==undefined)values.push(["Initial BH",device.initial_battery_health===null?"Not recorded":device.initial_battery_health+"%"]);
    if(device.grade_source){values.push(["Supplier grade (current saved)",device.supplier_grade],["GL grade (current saved)",device.gl_grade]);}
    if(scalar(device.region))values.push(["Phone region",device.region]);
    const cells=values.map(([name,value],index)=>`<th scope="row">${escapeHtml(name)}</th><td${index===values.length-1 && values.length%2 ? ' colspan="3"' : ""}>${safe(value)}</td>`);
    header.innerHTML=`<div class="history-basic-heading"><h2 id="history-device-name">Device details</h2>${badge(currentStage(device))}</div><table class="history-basic-table"><caption class="history-sr-only">Basic phone and supplier details</caption><tbody>${cells.reduce((html,cell,index)=>html+(index%2===0 ? "<tr>" : "")+cell+(index%2===1 || index===cells.length-1 ? "</tr>" : ""),"")}</tbody></table>`;
  }
  function renderReplacementHistory(data) {
    if(data.replacement_history_unavailable)return '<p class="history-replacement-warning" role="status">Replacement history could not be loaded. Refresh to check the old/new IMEI link.</p>';
    const links=data.replacement_history?.rows;
    if(!Array.isArray(links)||!links.length)return '';
    return `<section class="history-replacements" aria-label="Replacement history"><h3>Return / Replacement History</h3>${links.map(link=>{
      const old=scalar(link.old_imei),incoming=scalar(link.new_imei);
      const batch=window.GREENLOOP_BATCH_LABEL?.(link.batch_number,{batch_number:link.batch_number,receipt_quantity:link.receipt_quantity})||scalar(link.batch_number);
      const message=scalar(data.device?.imei_1)===incoming?'This phone was received as a replacement for the returned IMEI below.':'This returned phone was replaced by the new IMEI below.';
      return `<article class="history-replacement-pair"><p class="history-replacement-explanation">${escapeHtml(message)}</p><div class="history-replacement-identities"><div class="history-replacement-old"><span>Returned IMEI</span><strong${old?' data-gl-copy-identifier':''}>${escapeHtml(old||missing)}</strong></div><span class="history-replacement-arrow" aria-label="replaced by">→</span><div class="history-replacement-new"><span>Replacement IMEI</span><strong data-gl-copy-identifier>${escapeHtml(incoming)}</strong></div></div><p class="history-replacement-meta">${[batch,scalar(link.invoice_number),scalar(link.supplier_code)].filter(Boolean).map(escapeHtml).join(' · ')}</p><p class="history-replacement-meta">${escapeHtml([scalar(link.model),link.storage_gb?link.storage_gb+' GB':'',scalar(link.color)].filter(Boolean).join(' · '))} · Received: ${escapeHtml(journeyMoment(link.received_at))} · ${link.entered?'Entered in IMEI Entry':'Awaiting IMEI Entry'}</p></article>`;
    }).join('')}</section>`;
  }
  function renderHistory(data) {
    const rows=window.GREENLOOP_STOCK_JOURNEY.activity(data.rows);
    renderBasicTable(data.device || {},rows);
    const visibleRows=rows.map(row=>({...row,details:visibleDetails(row)}));
    const compact=window.GREENLOOP_STOCK_JOURNEY.render(visibleRows,{
      escape:escapeHtml,date:journeyMoment,currentStage:currentStage(data.device || {}),
      money:value=>number(value)===null ? missing : number(value).toLocaleString("en-GB",{minimumFractionDigits:2,maximumFractionDigits:2})
    });
    body.innerHTML=renderReplacementHistory(data)+(rows.length ? compact+`<details class="history-full-activity"><summary>Full activity (${rows.length} records)</summary><ol class="history-activity-list">${renderActivityList(visibleRows)}</ol></details>` : '<p class="history-missing">No history has been recorded for this phone.</p>');
    count.textContent="Journey by recorded time · Same-time actions follow workflow order · UAE time";
    const totals=data.summary || {};
    const unpriced=number(totals.unpriced_manual_part_quantity) || 0;
    summary.innerHTML=unpriced>0
      ? `<span>${fact("Total cost","Incomplete — part prices missing")}</span><span>${fact("Recorded amount",money(totals.recorded_total_cost))}</span><span class="history-missing">${escapeHtml(unpriced)} manual part${unpriced===1 ? " has" : "s have"} no recorded price and ${unpriced===1 ? "is" : "are"} excluded from the recorded amount.</span>`
      : `<span>${fact("Total recorded cost",money(totals.recorded_total_cost))}</span>`;
    result.hidden=false;
    window.GREENLOOP_LAB_DELAY?.mountHistory(body,data.device?.imei_1||data.device?.device_number,"imei_search");
  }

  function setMessage(text = "") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); }
  function setSubmitting(busy) { searchButton.disabled = busy; searchButton.textContent = busy ? "Searching..." : "Search"; form.setAttribute("aria-busy", String(busy)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function withTimeout(promise) {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("History is taking too long to load. Please search again.")), 25000); })]).finally(() => clearTimeout(timer));
  }
  const historyAnchor=document.createComment("Phone history home");result.before(historyAnchor);
  let historyDialog,popupVersion=0,bulkVersion=0;
  function restoreHistoryHome(){if(!result.closest('.history-dialog-body'))return;popupVersion++;result.hidden=true;historyAnchor.after(result);document.body.classList.remove('history-dialog-open');}
  function closeHistoryPopup(){if(historyDialog?.open){historyDialog.close();restoreHistoryHome();}}
  function historyPopup(){
    if(historyDialog)return historyDialog;
    historyDialog=document.createElement('dialog');historyDialog.id='imei-history-dialog';historyDialog.className='imei-history-dialog history-content';historyDialog.setAttribute('aria-labelledby','imei-history-dialog-title');
    historyDialog.innerHTML='<header class="history-dialog-heading"><h2 id="imei-history-dialog-title">Phone history</h2><button type="button" class="secondary-button" data-history-close data-search-read-only data-capability="view" data-capability-page="imei_search">Close</button></header><p class="history-dialog-status" role="status" aria-live="polite"></p><div class="history-dialog-body"></div>';
    historyDialog.querySelector('[data-history-close]').addEventListener('click',closeHistoryPopup);
    historyDialog.addEventListener('close',()=>{if(!historyDialog.open)restoreHistoryHome();});
    document.body.append(historyDialog);return historyDialog;
  }
  async function openDevice(item,{popup=false}={}) {
    if(!allowed)return;
    const identifier=scalar(item.imei_1 || item.identifier || item.device_number);
    if(!identifier)return;
    searchWidget?.close();
    let modal,status,popupToken;
    if(popup){
      modal=historyPopup();popupToken=++popupVersion;modal.querySelector('h2').textContent='Phone history · '+identifier;
      status=modal.querySelector('[role="status"]');status.textContent='Loading phone history…';modal.querySelector('.history-dialog-body').append(result);
      result.hidden=true;if(!modal.open)modal.showModal();document.body.classList.add('history-dialog-open');
    }else{closeHistoryPopup();query.value=identifier;bulkVersion++;bulkSearchResult?.remove();result.hidden=true;receiptResult.hidden=true;setMessage();setSubmitting(true);}
    const version=++searchVersion;
    const current=()=>version===searchVersion&&(!popup||popupToken===popupVersion&&modal.open);
    const report=text=>{if(popup)status.textContent=text;else setMessage(text);};
    try {
      const response=await withTimeout(getClient().rpc("get_imei_activity_journey_v1",{p_imei:identifier}));
      if(!current())return;
      if(response.error)throw response.error;
      const raw=response.data;
      const history=Array.isArray(raw)?raw[0]?.get_imei_activity_journey_v1 || raw[0]:raw;
      if(!history?.found){report("This device is no longer available. Search again.");return;}
      const [receipt,replacement]=await Promise.allSettled([
        GREENLOOP_RECEIPTS.load("imei_search",[history.device?.imei_1]),
        withTimeout(getClient().rpc('get_imei_replacement_history_v1',{p_imei:history.device?.imei_1}))
      ]);
      if(!current())return;
      if(receipt.status==='rejected')throw receipt.reason;
      const pairing=replacement.status==='fulfilled'&&!replacement.value.error?replacement.value.data:null;
      if(pairing?.found===true&&pairing.imei===history.device?.imei_1&&Array.isArray(pairing.rows)&&pairing.rows.every(link=>/^\d{15}$/.test(link.new_imei)&&(!link.old_imei||/^\d{15}$/.test(link.old_imei))))history.replacement_history=pairing;
      else history.replacement_history_unavailable=true;
      renderHistory(history);
      if(popup){status.textContent='';const full=body.querySelector('.history-full-activity');if(full)full.open=true;}
      else window.history.replaceState(null,"",`?q=${encodeURIComponent(identifier)}`);
    } catch(error) {if(current()){result.hidden=true;report(error.message || "Device history could not be loaded.");}}
    finally {if(!popup&&version===searchVersion)setSubmitting(false);}
  }
  function receiptButtons() {
    const container=receiptResult.querySelector(".history-receipt-devices");
    container.replaceChildren();
    receiptItems.forEach(item=>{
      const info=window.GREENLOOP_RECORD_SEARCH.describe(item);
      const button=document.createElement("button");button.type="button";button.className="history-receipt-device";button.dataset.searchReadOnly="true";
      const title=document.createElement("strong");title.textContent=info.title;
      const detail=document.createElement("small");detail.textContent=info.meta;
      button.append(title,detail);button.addEventListener("click",()=>openDevice(item));container.append(button);
    });
    if(!receiptItems.length)container.textContent="No phones have been entered for this stock receipt yet.";
  }
  async function openReceipt(item,append=false) {
    if(!allowed)return;
    searchWidget?.close();const version=++searchVersion;
    if(!append){receiptId=item.id;receiptOffset=0;receiptItems=[];result.hidden=true;receiptResult.hidden=true;query.value=item.invoice_number || item.identifier || "";}
    setMessage();setSubmitting(true);
    try {
      const data=await window.GREENLOOP_RECORD_SEARCH.rpc("get_search_receipt_returns_v1",{p_receipt_id:receiptId,p_offset:receiptOffset,p_limit:25});
      if(version!==searchVersion)return;
      if(!data.found){setMessage("This stock receipt is no longer available.");return;}
      const receipt=data.receipt || {};
      if(!Number.isSafeInteger(receipt.returned_quantity)||receipt.returned_quantity<0)throw new Error("Returned phone count could not be verified. Refresh and try again.");
      if(!append){
        query.value=receipt.invoice_number || receipt.batch_number || query.value;
        const values=[["Invoice",receipt.invoice_number],["Stock/Batch No",receipt.batch_number],["Stock received",moment(receipt.received_at)],
          ["Received by",receipt.received_by],["Supplier code",GREENLOOP_SUPPLIER_RECEIPT_LABEL(receipt.supplier_code,receipt.planned_quantity,null)],
          ...(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES?[["Supplier",receipt.supplier_name]]:[]),
          ["Quantity received",receipt.planned_quantity],["Phones entered",receipt.entered_quantity],["Phones returned",receipt.returned_quantity],["Stock channel",receipt.stock_channel]];
        receiptResult.innerHTML='<h2>Stock received details</h2><dl>'+values.map(([name,value])=>'<div><dt>'+escapeHtml(name)+'</dt><dd>'+safe(value)+'</dd></div>').join('')+'</dl><h3>Phones in this receipt</h3><div class="history-receipt-devices"></div><button type="button" class="secondary-button" data-search-read-only data-receipt-more hidden>Show more phones</button>';
        receiptResult.querySelector('[data-receipt-more]').addEventListener('click',()=>openReceipt({id:receiptId},true));
      }
      receiptItems.push(...(Array.isArray(data.items)?data.items:[]));receiptOffset=data.next_offset ?? receiptItems.length;
      receiptButtons();receiptResult.querySelector('[data-receipt-more]').hidden=!data.has_more;
      window.GREENLOOP_STOCK?.mount(receiptResult,[receipt]);
      receiptResult.hidden=false;
      window.history.replaceState(null,"",`?receipt=${encodeURIComponent(receiptId)}`);
    } catch(error){if(version===searchVersion)setMessage(error.message || "Stock receipt could not be loaded.");}
    finally{if(version===searchVersion)setSubmitting(false);}
  }
  let bulkSearchResult;
  async function bulkSearch(imeis,{isCurrent=()=>true,offset=0}={}){
    const version=++bulkVersion;closeHistoryPopup();searchWidget?.close();result.hidden=true;receiptResult.hidden=true;bulkSearchResult?.remove();
    const panel=document.createElement('section');bulkSearchResult=panel;panel.className='stock-bulk-results';panel.setAttribute('aria-label','Pasted phone results');panel.setAttribute('aria-busy','true');
    const heading=document.createElement('h2');heading.textContent=imeis.length+' pasted IMEIs';panel.append(heading);
    const status=document.createElement('p');status.setAttribute('role','status');status.textContent='Checking current stages…';panel.append(status);form.after(panel);
    const current=()=>version===bulkVersion&&isCurrent()&&panel.isConnected;
    try {
      const response=await withTimeout(getClient().rpc('get_imei_bulk_history_list_v1',{p_imeis:imeis,p_offset:offset,p_limit:50}));
      if(!current())return {loaded:0};if(response.error)throw response.error;
      const data=response.data;
      if(!Array.isArray(data?.rows)||!Number.isInteger(data.total)||data.rows.length>50)throw Error('The pasted phone list could not be verified. Please search again.');
      const wrap=document.createElement('div');wrap.className='history-bulk-scroll';const table=document.createElement('table');table.innerHTML='<thead><tr><th>S.No</th><th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>Supplier</th><th>Current stage</th><th>Details</th></tr></thead>';const tbody=document.createElement('tbody');table.append(tbody);wrap.append(table);panel.append(wrap);
      let loaded=0;
      data.rows.forEach((record,index)=>{
        const found=record.found===true,tr=document.createElement('tr');
        const fields=found?[offset+index+1,record.searched_imei,record.model||missing,record.storage_gb?window.GREENLOOP_STORAGE?.label(record.storage_gb)||record.storage_gb+' GB':missing,record.color||missing,window.GREENLOOP_STOCK?.labelRow(record)||record.supplier_code||missing,place(currentStage(record))]:[offset+index+1,record.searched_imei,'Not found','','','','Not found'];
        fields.forEach(value=>{const td=document.createElement('td');td.textContent=value;tr.append(td);});
        if(found&&record.imei_2===record.searched_imei){const note=document.createElement('small');note.className='history-secondary-imei';note.textContent='IMEI 2 of '+record.imei_1;tr.cells[1].append(note);}
        const td=document.createElement('td');if(found){loaded++;const button=document.createElement('button');button.type='button';button.className='secondary-button';button.textContent='Open history';button.dataset.searchReadOnly='';button.dataset.capability='view';button.dataset.capabilityPage='imei_search';button.addEventListener('click',()=>openDevice(record,{popup:true}));td.append(button);}tr.append(td);tbody.append(tr);
      });
      const end=offset+data.rows.length;status.textContent=data.total?`${offset+1}–${end} of ${data.total} IMEIs`:'No IMEIs to display.';
      if(data.total>50){const pager=document.createElement('div');pager.className='history-bulk-pager';for(const [text,next,disabled]of[['Previous',Math.max(0,offset-50),offset===0],['Next',offset+50,end>=data.total]]){const button=document.createElement('button');button.type='button';button.className='secondary-button';button.textContent=text;button.disabled=disabled;button.dataset.searchReadOnly='';button.dataset.capability='search';button.dataset.capabilityPage='imei_search';button.addEventListener('click',()=>bulkSearch(imeis,{offset:next}));pager.append(button);}panel.append(pager);}
      query.removeAttribute('maxlength');query.value=imeis.join(' ');return {loaded};
    }catch(error){if(current())status.textContent=error.message||'The pasted phone list could not be loaded.';return {loaded:0,issues:[error.message||'Search failed']};}
    finally{if(current())panel.setAttribute('aria-busy','false');}
  }
  window.GREENLOOP_BULK_IMEI?.register({selector:'#imei-query',capability:'search',load:bulkSearch});
  async function search(event) {
    event?.preventDefault();if(!allowed)return;const pasted=window.GREENLOOP_BULK_IMEI?.list(query.value);if(pasted){await bulkSearch(pasted);return;}
    if(!query.value.trim()){setMessage("Enter an IMEI, invoice, device number, serial number, or model.");return;}
    if(/^\d{15}$/.test(query.value.trim())&&window.GREENLOOP_CAN_SEARCH!==false){await openDevice({identifier:query.value.trim()});return;}
    await searchWidget.search({selectExact:true});
  }
  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData, error } = await getClient().auth.getSession();
    if (error) throw error;
    if (!sessionData?.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();
    if (!window.GREENLOOP_PAGE_ACCESS || window.GREENLOOP_PAGE_ACCESS.pageKey !== "imei_search") { permissionMessage.textContent = "Your account does not have IMEI Search permission."; permissionMessage.hidden = false; return; }
    allowed = true; app.hidden = false;
    searchWidget=window.GREENLOOP_RECORD_SEARCH.attach(query,{onExactIdentifier:value=>openDevice({identifier:value}),onSelect:item=>item.kind==="receipt"?openReceipt(item):openDevice(item)});
    const requestedReceipt=new URLSearchParams(window.location.search).get("receipt");
    if(requestedReceipt){await openReceipt({id:requestedReceipt});return;}
    if (requestedQuery.trim()) { query.value = requestedQuery.trim(); await search(); }
  }
  query.addEventListener("input", () => { ++searchVersion;++bulkVersion;closeHistoryPopup();bulkSearchResult?.remove(); setSubmitting(false); result.hidden = true; receiptResult.hidden=true; setMessage(); });
  form.addEventListener("submit", search);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  for(const name of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(name,()=>{searchVersion++;bulkVersion++;closeHistoryPopup();result.hidden=true;receiptResult.hidden=true;bulkSearchResult?.remove();});
  initialize().catch(error => { permissionMessage.textContent = error.message || "IMEI Search could not be loaded."; permissionMessage.hidden = false; });
})();
