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
    frame: "Frame Department", frame_department: "Frame Department", final_qc: "Final QC",
    ready_stock: "Ready Stock", rework: "Rework", export: "Export Boxes", export_box: "Export Boxes",
    stock_return: "Stock Return", supplier_return: "Stock Return", movement: "Location change",
    correction: "Data correction", job: "Job history", event: "Recorded activity",
    assignment: "Technician assignment", technician: "Technician time", workflow: "Process update"
  };
  let client;
  let allowed = false;
  let toastTimer;
  let autoSearchTimer;
  let searchVersion = 0;

  function getClient() { return (client ||= window.GREENLOOP_GET_CLIENT()); }
  function scalar(value) { return ["string", "number", "boolean"].includes(typeof value) ? String(value).trim() : ""; }
  function escapeHtml(value) { return scalar(value).replace(/[&<>'"]/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function label(value) {
    return scalar(value).replaceAll("_", " ").replace(/\b\w/g, character => character.toUpperCase()).replace(/\bQc\b/g, "QC").replace(/\bImei\b/g, "IMEI") || missing;
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
// Pure presentation grouping for search_imei_journey_v1. Uses scalar/timestamp.
// A structured work pair shares laboratory/glass-start:<id> and -complete:<id>.
// job_number is the only job link exposed by this RPC. Parts expose no work-step
// link: their own actor/date/price stay on the raw record, never on the technician.
function buildSteps(sortedRows) {
  const text = value => scalar(value).toLowerCase().replace(/[_–—]+/g, " ").replace(/\s+/g, " ").trim();
  const detail = (row, name) => (Array.isArray(row.details) ? row.details : []).find(item => text(item?.label) === text(name))?.value;
  const entries = (Array.isArray(sortedRows) ? sortedRows : []).map((row, index) => ({ row, index, at: timestamp(row?.occurred_at), job: scalar(row?.job_number) }));
  const groups = [], assigned = new Set(), sessions = [];
  const rawPrefix = row => scalar(row.id).split(":")[0];
  const workDepartment = row => /glass/.test(text(row.stage)) ? "glass" : "laboratory";
  const routeTitle = title => /^(?:initial qc sent (?:phone |job )?(?:directly )?to (?:frame|final qc|parts|laboratory)|initial qc (?:direct to frame|lab parts skipped|parallel routing)|final qc (?:sent to frame|routed to frame|received(?: phone from laboratory)?)|laboratory completed and sent to final qc)/.test(title);
  function kind(row) {
    const prefix = rawPrefix(row), stage = text(row.stage), title = text(row.title);
    if (/^(?:receipt|individual-receipt)$/.test(prefix)) return "receipt";
    if (prefix === "entry") return "entry";
    if (prefix === "initial-qc") return "initial";
    if (/^(?:laboratory|glass)-start$/.test(prefix)) return "work-start";
    if (/^(?:laboratory|glass)-complete$/.test(prefix)) return "work-complete";
    if (/^(?:part-request|part-issue|part-installation|manual-part|part-return)$/.test(prefix)) return "parts";
    if (prefix === "final-qc") return "final";
    if (prefix === "frame") return "frame";
    if (/^(?:export-box|dispatch)$/.test(prefix)) return "export";
    if (prefix === "supplier-return") return "return";
    if (/^(?:assignment|timer-start|timer-stop|service)$/.test(prefix)) return "support";
    if (prefix === "movement" || stage === "movement") return "movement";
    if (stage === "rework") return "rework";
    if (stage === "ready stock") return "ready";
    if (/^(?:stock return|supplier return)$/.test(stage)) return "return";
    if (/^laboratory (?:work )?completed(?: and sent to final qc)?$/.test(title) || /^glass work completed$/.test(title)) return "work-complete";
    if (/^(?:laboratory|glass) work started$/.test(title)) return "work-start";
    if (routeTitle(title)) return "route";
    if (/^(?:assignment|technician)$/.test(stage)) return "support";
    // Stage fallbacks support older/synthetic fixtures; no UUID pairing is inferred.
    if (/^(?:stock received|receiving|receipt)$/.test(stage)) return "receipt";
    if (/^(?:imei entry|intake|job created)$/.test(stage)) return "entry";
    if (stage === "initial qc") return "initial";
    if (stage === "final qc" && /(?:passed|failed|inspection)/.test(title)) return "final";
    if (/^(?:frame|frame department)$/.test(stage) && /(?:passed|failed|inspection)/.test(title)) return "frame";
    if (/^(?:parts|part request|part issue|part installation|manual part|part return)$/.test(stage)) return "parts";
    if (/^(?:export|export box)$/.test(stage)) return "export";
    return "other";
  }
  entries.forEach(entry => { entry.kind = kind(entry.row || {}); });
  const dated = entry => entry.at !== null && Number.isFinite(entry.at);
  const sameJob = (a, b) => Boolean(a.job) && a.job === b.job;
  const boundaries = entries.filter(entry => dated(entry) && (["entry", "rework", "return"].includes(entry.kind) || (entry.kind === "final" && /^(?:fail|failed)$/.test(text(entry.row.status)))));
  const blocked = (start, end) => boundaries.some(entry => sameJob(entry, start) && entry.index !== start.index && entry.at > start.at && entry.at <= end.at);
  function add(entry) {
    const group = { row: entry.row, members: [entry], anchor: entry.index };
    groups.push(group); assigned.add(entry.index); return group;
  }
  function append(group, entry) { group.members.push(entry); assigned.add(entry.index); }
  function workKey(entry, ending) {
    const match = scalar(entry.row.id).match(ending ? /^(laboratory|glass)-complete:(.+)$/ : /^(laboratory|glass)-start:(.+)$/);
    return match ? `${match[1]}:${match[2]}` : null;
  }
  const workStarts = entries.filter(entry => dated(entry) && entry.kind === "work-start");
  const interveningKinds = new Set(["receipt", "entry", "initial", "final", "frame", "ready", "export", "rework", "return", "route", "movement", "work-start", "work-complete"]);
  // A combined row must not show its later completion before an intervening
  // numbered business step. Equal completion timestamps can remain together.
  const interrupted = (start, end) => entries.some(entry => dated(entry) && entry.at > start.at && entry.at < end.at &&
    (interveningKinds.has(entry.kind) || (entry.kind === "parts" && !sameJob(start, entry))));
  function recordedEnd(start) {
    const key = workKey(start, false);
    if (!key || workStarts.filter(entry => sameJob(start, entry) && workKey(entry, false) === key).length !== 1) return null;
    const ends = entries.filter(entry => dated(entry) && entry.kind === "work-complete" && sameJob(start, entry) && workKey(entry, true) === key && entry.at >= start.at);
    return ends.length === 1 ? ends[0] : null;
  }
  function overlaps(start, end) {
    return workStarts.some(other => {
      if (other.index === start.index || !sameJob(start, other) || other.at >= end.at) return false;
      const recorded = recordedEnd(other);
      const closures = entries.filter(entry => dated(entry) && sameJob(other, entry) && entry.at > other.at && ["entry", "final", "ready", "export", "rework", "return"].includes(entry.kind));
      const until = Math.min(recorded?.at ?? Infinity, ...closures.map(entry => entry.at));
      return until > start.at;
    });
  }
  // Create work sessions first, merging only the exact persisted work-record pair.
  for (const start of workStarts) {
    const group = add(start), recorded = recordedEnd(start);
    const end = recorded && !blocked(start, recorded) && !interrupted(start, recorded) && !overlaps(start, recorded) ? recorded : null;
    if (end && !assigned.has(end.index)) append(group, end);
    sessions.push({ start, end, recorded, group, department: workDepartment(start.row) });
  }
  const closureKinds = new Set(["entry", "rework", "return", "final", "ready", "export"]);
  function sessionEnd(session) {
    const stops = entries.filter(entry => dated(entry) && sameJob(entry, session.start) && entry.at > session.start.at &&
      (closureKinds.has(entry.kind) || (!session.recorded && entry.kind === "work-complete" && workDepartment(entry.row) === session.department) || (entry.kind === "route" && /^final qc /.test(text(entry.row.title)))));
    return Math.min(session.end?.at ?? session.recorded?.at ?? Infinity, ...stops.map(entry => entry.at));
  }
  const containing = entry => sessions.filter(session => sameJob(session.start, entry) && entry.at >= session.start.at && entry.at <= sessionEnd(session) && !blocked(session.start, entry));
  // The fast Lab workflow emits an event instead of completing its table row.
  // Only explicit elapsed time that identifies one start can join that session.
  for (const entry of entries.filter(entry => dated(entry) && entry.kind === "work-complete" && !assigned.has(entry.index))) {
    const title = text(entry.row.title), elapsed = Number(entry.row.duration_seconds);
    const fast = /^(?:laboratory completed|laboratory completed and sent to final qc)$/.test(title) && text(entry.row.duration_label) === "elapsed laboratory time" && entry.row.duration_seconds !== null && entry.row.duration_seconds !== undefined && Number.isFinite(elapsed) && elapsed >= 0;
    const candidates = fast ? containing(entry).filter(session => session.department === "laboratory" && !session.end && !interrupted(session.start, entry) && !overlaps(session.start, entry) && Math.abs(entry.at - session.start.at - elapsed * 1000) < 1) : [];
    if (candidates.length === 1) { candidates[0].end = entry; append(candidates[0].group, entry); }
    else add(entry);
  }
  // Other confirmed business milestones always survive as their own step.
  for (const entry of entries) {
    if (!dated(entry) || assigned.has(entry.index)) continue;
    if (["receipt", "entry", "initial", "final", "frame", "ready", "rework", "return", "export"].includes(entry.kind)) add(entry);
  }
  for (const entry of entries.filter(entry => dated(entry) && entry.kind === "parts")) {
    const candidates = containing(entry);
    if (candidates.length === 1 && !interrupted(candidates[0].start, entry)) append(candidates[0].group, entry);
    else add(entry);
  }
  for (const entry of entries.filter(entry => dated(entry) && entry.kind === "support")) {
    const department = text(detail(entry.row, "Department"));
    const candidates = containing(entry).filter(session => !department || department === session.department || (department === "lab" && session.department === "laboratory"));
    if (candidates.length === 1 && !interrupted(candidates[0].start, entry)) append(candidates[0].group, entry);
  }
  function routeTarget(row) {
    let value = text(detail(row, "To") || detail(row, "Next step") || detail(row, "Next department") || detail(row, "Department"));
    if (!value) {
      const title = text(row.title);
      if (/to final qc$/.test(title)) value = "final qc";
      else if (/to frame$/.test(title)) value = "frame";
      else if (/to laboratory$/.test(title)) value = "laboratory";
      else if (/to parts$/.test(title)) value = "parts";
    }
    if (/^(?:lab|laboratory)$/.test(value)) return "laboratory";
    if (/^(?:final[ -]?qc|final qc department)$/.test(value)) return "final qc";
    if (/^(?:frame|frame department)$/.test(value)) return "frame";
    if (/^(?:parts|parts department)$/.test(value)) return "parts";
    return value;
  }
  // Merge same-transaction route echoes only into a unique business companion.
  // When two milestones share a time, an explicit source title disambiguates QC.
  const routes = entries.filter(entry => dated(entry) && entry.kind === "route");
  const movements = entries.filter(entry => dated(entry) && entry.kind === "movement");
  for (const entry of [...routes, ...movements]) {
    const title = text(entry.row.title);
    let candidates = groups.filter(group => group.members.some(member => sameJob(member, entry) && member.at === entry.at && !["parts", "support", "movement"].includes(member.kind)));
    if (candidates.length > 1 && entry.kind === "route") {
      const sourceKind = /^initial qc/.test(title) ? "initial" : /^final qc/.test(title) && !/^final qc received/.test(title) ? "final" : null;
      if (sourceKind) candidates = candidates.filter(group => group.members.some(member => member.kind === sourceKind && member.at === entry.at));
    }
    if (candidates.length > 1 && entry.kind === "movement" && routeTarget(entry.row)) {
      const target = routeTarget(entry.row);
      candidates = candidates.filter(group => group.members.some(member => member.kind === "route" && member.at === entry.at && routeTarget(member.row) === target));
    }
    if (candidates.length === 1) append(candidates[0], entry);
    else add(entry);
  }
  groups.sort((a, b) => timestamp(a.row.occurred_at) - timestamp(b.row.occurred_at) || a.anchor - b.anchor);
  // Within the same job and timestamp only: QC/Frame precedes Ready, then Export.
  // Reorder just these slots; unrelated equal-time records retain their positions.
  const rank = { final: 0, frame: 0, ready: 1, export: 2 }, ties = new Map();
  groups.forEach((group, index) => {
    const first = entries[group.anchor];
    if (!first.job || rank[first.kind] === undefined) return;
    const key = `${first.job}\u0000${first.at}`;
    if (!ties.has(key)) ties.set(key, []);
    ties.get(key).push(index);
  });
  for (const indexes of ties.values()) {
    const ordered = indexes.map(index => groups[index]).sort((a, b) => rank[entries[a.anchor].kind] - rank[entries[b.anchor].kind] || a.anchor - b.anchor);
    indexes.forEach((index, position) => { groups[index] = ordered[position]; });
  }
  return {
    steps: groups.map(group => ({ row: group.row, records: group.members.sort((a, b) => a.index - b.index).map(entry => entry.row) })),
    other: entries.filter(entry => !assigned.has(entry.index)).map(entry => entry.row)
  };
}

  function visibleDetails(row) {
    return (Array.isArray(row.details) ? row.details : []).filter(item => item && scalar(item.label) && scalar(item.value) &&
      (window.GREENLOOP_CAN_VIEW_PARTNER_NAMES || !/^(?:supplier|customer)(?: company)? name$/i.test(scalar(item.label))));
  }
  function field(row, key) {
    return scalar(visibleDetails(row).find(item => scalar(item.label).toLowerCase() === key.toLowerCase())?.value);
  }
  function destination(value) {
    const names = { LAB: "Lab & Glass", LABORATORY: "Laboratory", GLASS: "Glass", "FINAL-QC": "Final QC", FINAL_QC: "Final QC", "INITIAL-QC": "Initial QC", INITIAL_QC: "Initial QC", FRAME: "Frame Department", READY: "Ready Stock", "READY-STOCK": "Ready Stock", READY_STOCK: "Ready Stock", PARTS: "Parts", OUTBOUND: "Export" };
    return names[scalar(value).toUpperCase()] || scalar(value);
  }
  function businessTitle(row) {
    const id = scalar(row.id), stage = scalar(row.stage), title = scalar(row.title);
    if (/^(receipt:|individual-receipt:)/.test(id) || stage === "stock_received") return "Stock received";
    if (id.startsWith("entry:") || stage === "imei_entry") return /another job/i.test(title) ? "Phone entered again for a new job" : "IMEI entry completed";
    if (id.startsWith("initial-qc:") || (stage === "initial_qc" && !/sent|route|moved/i.test(title))) return "Initial QC completed";
    if (stage === "movement") return field(row, "To") ? `Sent to ${destination(field(row, "To"))}` : title || "Phone moved";
    if (id.startsWith("laboratory-start:")) return "Laboratory work started";
    if (id.startsWith("laboratory-complete:")) return "Laboratory work completed";
    if (id.startsWith("glass-start:")) return "Glass work started";
    if (id.startsWith("glass-complete:")) return "Glass work completed";
    if (id.startsWith("final-qc:")) return /^(pass|passed)$/i.test(scalar(row.status)) ? "Final QC passed" : /^(fail|failed)$/i.test(scalar(row.status)) ? "Final QC failed" : title;
    if (stage === "ready_stock") return "Moved to Ready Stock";
    if (stage === "rework") return "Sent back for rework";
    if (id.startsWith("export-box:")) return "Scanned into export box";
    if (id.startsWith("dispatch:")) return "Stock dispatched";
    const routes = {
      "Initial Qc Direct To Frame": "Initial QC sent phone to Frame Department",
      "Initial Qc Lab Parts Skipped": "Initial QC sent phone to Final QC",
      "Initial Qc Parallel Routing": "Sent to Parts and Laboratory",
      "Final Qc Routed To Frame": "Final QC sent phone to Frame Department",
      "Final Qc Received": "Phone received at Final QC",
      "Laboratory Completed": "Laboratory work completed; sent to Final QC"
    };
    return routes[title] || title || stages[stage] || "Saved activity";
  }
  function when(value) {
    const stamp = timestamp(value);
    return stamp === null ? '<span class="journey-missing">Date not recorded</span>' : `<time datetime="${escapeHtml(new Date(stamp).toISOString())}"><span class="journey-date">${escapeHtml(date(value))}</span><span class="journey-clock">${escapeHtml(date(value, true))}</span></time>`;
  }
  function facts(items) {
    return items.length ? `<dl class="journey-detail-list">${items.map(item => {
      const isRoute = /^(department|next department|next step|from|to|failure department)$/i.test(item.label);
      const name = ({Findings:"Problem found", "Next step":"Sent to", "Next department":"Sent to", To:"Sent to", "Required work":"Work needed", "Final battery health":"Battery health"})[item.label] || item.label;
      return `<div><dt>${escapeHtml(name)}</dt><dd>${escapeHtml(isRoute ? destination(item.value) : item.value)}</dd></div>`;
    }).join("")}</dl>` : "";
  }
  function partFacts(row) {
    const parts = Array.isArray(row.parts) ? row.parts.filter(part => part && typeof part === "object") : [];
    return parts.length ? `<ul class="journey-part-list">${parts.map(part => {
      const quantity = number(part.quantity), unit = number(part.unit_cost), total = number(part.total_cost);
      return `<li><strong>${escapeHtml(scalar(part.name) || "Part name not recorded")}${quantity === null ? "" : ` × ${escapeHtml(quantity)}`}</strong><span>${unit === null ? "Price not recorded" : `${escapeHtml(money(unit))} each`}${total === null ? "" : ` · Total <b>${escapeHtml(money(total))}</b>`}</span></li>`;
    }).join("")}</ul>` : "";
  }
  function recordContent(row, {main = false, compact = false} = {}) {
    const visible = visibleDetails(row);
    const technical = /^(cost basis|timing basis|record type|assignment|rework cycle|repair cycle|current request status|request source|job type|stock channel)$/i;
    const relevant = visible.filter(item => !technical.test(item.label));
    // Keep the business facts visible. Technical metadata stays available on demand.
    const primary = relevant.slice(0, 5);
    const remaining = visible.filter(item => !primary.includes(item));
    const actor = scalar(row.actor);
    const actorRole = /^(stock_received|receiving|receipt)$/.test(row.stage) ? "Received by" : row.stage === "imei_entry" ? "Entered by" : /sent|routed|moved/i.test(scalar(row.title)) || row.stage === "movement" ? "Sent by" : row.stage === "initial_qc" || row.stage === "final_qc" ? "Checked by" : scalar(row.id).startsWith("part-installation:") ? "Installed by" : scalar(row.id).startsWith("part-issue:") ? "Issued by" : "By";
    const durationValue = number(row.duration_seconds);
    const hasParts = Array.isArray(row.parts) && row.parts.length > 0;
    const costLabel = row.stage === "imei_entry" ? "Purchase cost" : /laboratory|glass/.test(row.stage) ? "Materials cost" : scalar(row.cost_label) || "Recorded cost";
    return `<div class="journey-record${main ? " is-main" : ""}${compact ? " is-supporting" : ""}" data-record-id="${escapeHtml(row.id)}" data-job-number="${escapeHtml(row.job_number)}">
      ${main ? "" : `<div class="journey-record-heading"><span class="journey-record-time">${timestamp(row.occurred_at) === null ? "Date not recorded" : `${escapeHtml(date(row.occurred_at))} · ${escapeHtml(date(row.occurred_at, true))}`}</span><strong>${escapeHtml(businessTitle(row))}</strong></div>`}
      ${actor ? `<p class="journey-person"><span>${actorRole}</span> ${escapeHtml(actor)}</p>` : (main && /stock_received|imei_entry|initial_qc|final_qc/.test(row.stage) ? '<p class="journey-missing">Name not recorded</p>' : "")}
      ${facts(primary)}${partFacts(row)}
      ${!hasParts && number(row.cost) !== null && (number(row.cost) !== 0 || row.stage === "imei_entry") ? `<p class="journey-inline-cost">${escapeHtml(costLabel)}: <b>${escapeHtml(money(row.cost))}</b></p>` : ""}
      ${durationValue !== null && durationValue >= 0 ? `<p class="journey-work-time">${escapeHtml(scalar(row.duration_label) || "Recorded time")}: <strong>${escapeHtml(duration(durationValue))}</strong></p>` : ""}
      ${remaining.length ? `<details class="journey-more"><summary>More details</summary>${scalar(row.job_number) ? `<p class="journey-job">Job: ${escapeHtml(row.job_number)}</p>` : ""}${facts(remaining)}</details>` : ""}
    </div>`;
  }
  function renderStep(step, index) {
    const row = step.row;
    const records = step.records || [row];
    const isSession = /^(laboratory|glass)-start:/.test(scalar(row.id)) && records.some(record => /^(laboratory|glass)-complete:/.test(scalar(record.id)));
    const title = isSession ? row.stage === "glass" ? "Glass repair" : "Laboratory repair" : businessTitle(row);
    const supporting = records.filter(record => record !== row);
    const installedNames = new Set(records.filter(record => /^(part-installation:|manual-part:)/.test(scalar(record.id))).flatMap(record => (record.parts || []).map(part => scalar(part.name).toLowerCase())));
    const isSecondary = record => /^(assignment:|timer-start:|timer-stop:|service:|part-request:)/.test(scalar(record.id)) || (scalar(record.id).startsWith("part-issue:") && (record.parts || []).length && record.parts.every(part => installedNames.has(scalar(part.name).toLowerCase())));
    const extra = supporting.filter(isSecondary);
    return `<tr data-history-id="${escapeHtml(row.id)}">
      <td class="journey-number-cell" data-label="Step"><span class="journey-step-number" data-tone="${tone(row.status,row.stage)}">${index + 1}</span></td>
      <td class="journey-when-cell" data-label="Date &amp; time">${isSession ? '<span class="journey-record-time">Started</span>' : ""}${when(row.occurred_at)}</td>
      <td class="journey-description-cell" data-label="What happened"><h3 class="journey-event-title">${escapeHtml(title)}</h3>${recordContent(row,{main:true})}${supporting.filter(record => !isSecondary(record)).map(record => recordContent(record)).join("")}${extra.length ? `<details class="journey-more journey-support"><summary>Parts issued &amp; supporting details (${extra.length})</summary>${extra.map(record => recordContent(record,{compact:true})).join("")}</details>` : ""}</td>
    </tr>`;
  }
  function renderSummary(data) {
    const amount = number(data.recorded_total_cost), elapsed = number(data.receipt_to_ready_seconds), unpriced = number(data.unpriced_manual_part_quantity) || 0;
    summary.innerHTML = `<span><span>Stock received → ready</span><strong>${escapeHtml(duration(elapsed))}</strong></span><span><span>${unpriced > 0 ? "Recorded cost (some prices missing)" : "Total recorded cost"}</span><strong>${escapeHtml(money(amount))}</strong></span><details class="journey-more"><summary>Cost &amp; timing details</summary><p>Elapsed time includes waiting and rework.</p>${facts([
      {label:"Purchase",value:money(data.purchase_cost)}, {label:"Installed parts",value:money(data.installed_parts_cost)}, {label:"Damaged / faulty parts",value:money(data.damaged_parts_cost)}, {label:"Lab materials",value:money(data.laboratory_material_cost)}, {label:"Glass materials",value:money(data.glass_material_cost)}
    ])}<p>Part issue and installation are not charged twice.${unpriced > 0 ? ` ${escapeHtml(unpriced)} manual part(s) have no recorded price.` : ""}</p></details>`;
  }
  function renderHistory(data) {
    const device = data.device || {};
    const identity = [device.brand, device.model, number(device.storage_gb) === null ? "" : `${device.storage_gb} GB`, device.color].map(scalar).filter(Boolean).join(" · ");
    const identifiers = [["IMEI",device.imei_1],["Serial",device.serial_number],["IMEI 2",device.imei_2]];
    header.innerHTML = `<div class="imei-journey-identity"><p class="panel-kicker">Phone history · step by step</p><h2 id="history-device-name">${escapeHtml(identity || "Device details not recorded")}</h2><div class="imei-journey-identifiers">${identifiers.filter(([name,value]) => name === "IMEI" || scalar(value)).map(([name,value]) => `<span>${name} <b>${escapeHtml(scalar(value) || missing)}</b></span>`).join("")}</div></div><div class="imei-journey-current"><small>Now</small>${scalar(device.current_status) ? badge(device.current_status) : absent()}${scalar(device.current_location) ? `<small>${escapeHtml(destination(device.current_location))}</small>` : ""}</div>`;
    const rows = (Array.isArray(data.rows) ? data.rows : []).filter(row => row && typeof row === "object").map((row,index) => ({row,index,stamp:timestamp(row.occurred_at)})).sort((a,b) => (a.stamp === null ? Infinity : a.stamp) - (b.stamp === null ? Infinity : b.stamp) || a.index-b.index).map(item => item.row);
    const grouped = buildSteps(rows);
    body.innerHTML = grouped.steps.map(renderStep).join("") || '<tr><td colspan="3"><span class="journey-missing">No dated process steps have been recorded for this phone.</span></td></tr>';
    if (grouped.other.length) body.innerHTML += `<tr class="journey-other-row"><td colspan="3"><details class="journey-other"><summary>Other saved details (${grouped.other.length})</summary><p class="journey-missing">Assignments, timer records and entries without a recorded date.</p>${grouped.other.map(row => recordContent(row,{compact:true})).join("")}</details></td></tr>`;
    count.textContent = `${grouped.steps.length} ${grouped.steps.length === 1 ? "step" : "steps"}`;
    renderSummary(data.summary || {});
    result.hidden = false;
  }

  function setMessage(text = "") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); }
  function setSubmitting(busy) { searchButton.disabled = busy; searchButton.textContent = busy ? "Searching..." : "Search device"; form.setAttribute("aria-busy", String(busy)); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function showToast(text) { clearTimeout(toastTimer); toast.textContent = text; toast.hidden = false; toast.classList.add("is-visible"); toastTimer = setTimeout(() => { toast.hidden = true; toast.classList.remove("is-visible"); }, 3400); }
  function withTimeout(promise) {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("History is taking too long to load. Please search again.")), 25000); })]).finally(() => clearTimeout(timer));
  }
  async function search(event) {
    event?.preventDefault();
    if (!allowed) return;
    window.clearTimeout(autoSearchTimer);
    setMessage(); result.hidden = true;
    const version = ++searchVersion;
    const identifier = query.value.trim();
    const current = () => version === searchVersion && query.value.trim() === identifier;
    if (!identifier) { setSubmitting(false); setMessage("Enter an IMEI, device number, or serial number first."); return; }
    setSubmitting(true);
    try {
      const response = await withTimeout(getClient().rpc("search_imei_journey_v1", { p_imei: identifier }));
      if (!current()) return;
      if (response.error) {
        if (response.error.code === "PGRST202" || response.error.code === "42883") throw new Error("The complete history update is not installed yet. Ask your administrator to install the IMEI History update.");
        throw response.error;
      }
      const raw = response.data;
      const history = Array.isArray(raw) ? raw[0]?.search_imei_journey_v1 || raw[0] : raw;
      if (!history?.found) { setMessage("No active device was found for this IMEI, device number, or serial number."); return; }
      renderHistory(history);
      showToast("Complete device journey loaded.");
    } catch (error) {
      if (current()) setMessage(error.message || "Device history could not be loaded. Please try again.");
    } finally {
      if (version === searchVersion) setSubmitting(false);
    }
  }
  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) { permissionMessage.textContent = "Supabase authentication is not configured."; permissionMessage.hidden = false; return; }
    const { data: sessionData, error } = await getClient().auth.getSession();
    if (error) throw error;
    if (!sessionData?.session) { window.location.replace("index.html"); return; }
    await window.GREENLOOP_ACCESS_READY;
    if (!window.GREENLOOP_PAGE_ACCESS || window.GREENLOOP_PAGE_ACCESS.pageKey !== "imei_search") { permissionMessage.textContent = "Your account does not have IMEI Search permission."; permissionMessage.hidden = false; return; }
    allowed = true; app.hidden = false;
    if (requestedQuery.trim()) { query.value = requestedQuery.trim(); await search(); }
  }
  query.addEventListener("input", () => { ++searchVersion; window.clearTimeout(autoSearchTimer); setSubmitting(false); result.hidden = true; setMessage(); const value = query.value.trim(); if (/^\d{15}$/.test(value) || /^DEV-\d+$/i.test(value)) autoSearchTimer = window.setTimeout(() => search(), 300); });
  form.addEventListener("submit", search);
  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  initialize().catch(error => { permissionMessage.textContent = error.message || "IMEI Search could not be loaded."; permissionMessage.hidden = false; });
})();
