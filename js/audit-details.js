(() => {
  "use strict";

  // Render only saved values. Audit details never fetch current records or infer
  // a person's identity from a UUID, so later edits cannot rewrite this history.
  const labels = Object.freeze({
    devices: "Phones", jobs: "Jobs", receiving_batches: "Receiving batches",
    stock_batch_plan_lines: "Receiving plan lines", export_boxes: "Export boxes",
    export_box_items: "Phones in export boxes", job_work_orders: "Work orders",
    job_work_order_steps: "Work order steps", initial_qc_inspections: "Initial QC inspections",
    initial_qc_findings: "Initial QC findings", initial_qc_part_requirements: "Initial QC parts required",
    final_qc_inspections: "Final QC inspections", final_qc_check_results: "Final QC check results",
    laboratory_work_records: "Laboratory work", glass_work_records: "Glass work",
    frame_department_results: "Frame department results", technician_job_timers: "Technician work times",
    job_part_requests: "Parts requested", part_issue_transactions: "Parts issued",
    part_installations: "Parts installed", lab_manual_part_installations: "Manual parts installed",
    lab_part_return_requests: "Part return requests", part_return_audit: "Part return history",
    part_return_stock_corrections: "Part return stock corrections", part_stock_movements: "Parts stock movements",
    lab_service_reviews: "Laboratory service reviews", device_events: "Phone activity",
    device_location_history: "Phone location history", production_records: "Production records",
    packing_records: "Packing records", stock_out_records: "Stock out records",
    data_change_history: "Saved data corrections", records: "Related saved records",
    counts: "Saved record counts", inventory_before: "Parts inventory before deletion",
    inventory_after: "Parts inventory after deletion", professional_lots_before: "Stock lots before deletion",
    professional_lots_after: "Stock lots after deletion", professional_balances_before: "Stock balances before deletion",
    professional_balances_after: "Stock balances after deletion", professional_inventory_policy: "Stock handling",
    restored_part_units: "Unused part units returned to stock", actor: "Saved account details",
    record_type: "Item type", record_label: "Item", deletion_method: "Deletion method",
    deleted_by: "Deleted by", deleted_at: "Deleted at", deletion_reason: "Reason",
    imei: "IMEI", imei_1: "IMEI 1", imei_2: "IMEI 2", scope: "Deletion scope",
    box_number: "Box number", box_status: "Box status", capacity: "Capacity",
    storage_gb: "Storage (GB)", full_name: "Full name", assigned_technician_name: "Assigned technician",
    quantity_requested: "Quantity requested", quantity_issued: "Quantity issued",
    quantity_installed: "Quantity installed", quantity_returned: "Quantity returned",
    stock_quantity: "Stock quantity", inventory_part_id: "Inventory part reference",
    part_request_id: "Part request reference", part_issue_id: "Part issue reference",
    work_order_id: "Work order reference", work_order_step_id: "Work order step reference",
    device_id: "Phone reference", job_id: "Job reference", box_id: "Box reference",
    technician_id: "Technician reference", assigned_technician_id: "Assigned technician reference",
    record_id: "Record reference", audit_id: "Audit reference", id: "Record ID",
    restricted_data_deletion: "Restricted Data deletion", hard_delete: "Hard delete",
    soft_delete: "Soft delete", old_values: "Previous values", new_values: "Updated values"
  });
  const identityKeys = ["box_number", "imei", "imei_1", "device_number", "job_number", "work_order_number", "batch_number", "part_name", "technician_name", "assigned_technician_name", "full_name", "name", "sku"];
  const fieldPriority = ["imei", "imei_1", "imei_2", "device_number", "job_number", "box_number", "batch_number", "part_name", "technician_name", "assigned_technician_name", "full_name", "name", "model", "serial_number", "status", "current_status", "box_status", "department", "stage", "quantity_requested", "quantity_issued", "quantity_installed", "quantity_returned"];
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const escape = value => String(value).replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const present = value => value !== null && value !== undefined && value !== "";

  function friendly(key) {
    const raw = String(key);
    if (own(labels, raw)) return labels[raw];
    return raw.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/_/g, " ")
      .replace(/\b(imei|qc|id|sku|gb|utc)\b/gi, word => word.toUpperCase())
      .replace(/^./, first => first.toUpperCase());
  }

  function dateValue(value, key) {
    if (typeof value !== "string" || !/(?:^date(?:_from|_to)?$|_at$|_date$|_on$)/.test(key)) return null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
      const date = new Date(`${value}T00:00:00Z`);
      if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) return null;
      return new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "2-digit", month: "short", year: "numeric" }).format(date);
    }
    // A timestamp without an offset has no reliable saved time zone. Keep it
    // verbatim instead of silently interpreting it as the viewer's local time.
    if (!/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$/i.test(value)) return null;
    const calendar = new Date(`${value.slice(0, 10)}T00:00:00Z`);
    if (Number.isNaN(calendar.getTime()) || calendar.toISOString().slice(0, 10) !== value.slice(0, 10)
      || Number(value.slice(11, 13)) > 23 || Number(value.slice(14, 16)) > 59) return null;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return null;
    return `${new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: true }).format(date)} (Dubai)`;
  }

  function primitive(value, key = "") {
    if (!present(value)) return '<span class="audit-snapshot-empty">Not recorded</span>';
    if (typeof value === "boolean") return value ? "Yes" : "No";
    const date = dateValue(value, key);
    if (date) return `<time title="Saved value: ${escape(value)}">${escape(date)}</time>`;
    if (key === "scope" && ["single", "all"].includes(value)) return value === "single" ? "Single IMEI" : "All IMEIs";
    if (key === "selected_pages" && typeof value === "string") {
      const pages = { dashboard: "Dashboard", laboratory: "Lab & Glass", lab_glass: "Lab & Glass", lab_live_board: "Lab Live Board", imei_entry: "IMEI Entry", imei_search: "IMEI Search", stock_received: "Stock Received", initial_qc: "Initial QC", final_qc: "Final QC", frame_department: "Frame Department", ready_stock: "Ready Stock", export_boxes: "Export Boxes", user_access: "User Access" };
      return `<span title="Saved value: ${escape(value)}">${escape(own(pages, value) ? pages[value] : friendly(value))}</span>`;
    }
    if (typeof value === "string" && /(?:^record_type$|^deletion_method$|^status$|_status$|^stage$|_stage$|^department$)/.test(key)) return escape(friendly(value));
    return escape(value);
  }

  function reference(key, value) {
    return key === "id" || /(?:_id|_ids)$/.test(key)
      || (/(?:^|_)(?:created|updated|deleted|opened|closed|requested|issued|installed|returned|assigned|approved|rejected|completed|checked|received|inspected|recorded|started|stopped|reviewed|submitted|corrected)_by$/.test(key) && (uuidPattern.test(String(value)) || !present(value)))
      || (typeof value === "string" && uuidPattern.test(value));
  }

  function identity(row) {
    if (!object(row)) return "";
    for (const key of identityKeys) {
      if (present(row[key]) && ["string", "number"].includes(typeof row[key])) {
        return /^imei/.test(key) ? `IMEI ${row[key]}` : String(row[key]);
      }
    }
    return "";
  }

  function savedReferences(snapshot) {
    const found = new Map();
    const visiting = new WeakSet();
    function visit(value) {
      if (!value || typeof value !== "object" || visiting.has(value)) return;
      visiting.add(value);
      if (object(value) && present(value.id)) {
        const name = identity(value);
        if (name) {
          const key = String(value.id);
          const existing = found.get(key);
          // Conflicting saved labels remain references; never guess which row
          // an ambiguous ID belongs to.
          found.set(key, existing === undefined || existing === name ? name : null);
        }
      }
      Object.values(value).forEach(visit);
    }
    visit(snapshot);
    return found;
  }

  function field(label, content) {
    return `<div class="audit-snapshot-field"><dt>${escape(label)}</dt><dd>${content}</dd></div>`;
  }

  function render(snapshot, context = {}) {
    if (typeof snapshot === "string") {
      try { snapshot = JSON.parse(snapshot); } catch (_) { /* Older text snapshots remain readable saved text. */ }
    }
    if (!object(context)) context = {};
    const references = savedReferences(snapshot);
    const ancestors = new WeakSet();

    function valueHtml(value, key = "") {
      if (value === null || typeof value !== "object") return primitive(value, key);
      if (ancestors.has(value)) return '<span class="audit-snapshot-empty">Circular saved reference</span>';
      ancestors.add(value);
      let result;
      if (Array.isArray(value)) {
        if (!value.length) result = '<p class="audit-snapshot-empty">No saved records</p>';
        else result = `<div class="audit-snapshot-grid">${value.map((row, index) => {
          const title = identity(row) || `Record ${index + 1}`;
          if (row !== null && typeof row === "object") return `<details class="audit-snapshot-record"><summary>${escape(title)}</summary>${valueHtml(row, key)}</details>`;
          return `<div class="audit-snapshot-record"><dl class="audit-snapshot-fields">${field(`Item ${index + 1}`, primitive(row, key))}</dl></div>`;
        }).join("")}</div>`;
      } else result = objectHtml(value);
      ancestors.delete(value);
      return result;
    }

    function objectHtml(value) {
      const entries = Object.entries(value);
      if (!entries.length) return '<p class="audit-snapshot-empty">No saved details</p>';
      const regular = [], refs = [], groups = [];
      entries.sort(([a], [b]) => {
        const order = key => fieldPriority.includes(key) ? fieldPriority.indexOf(key) : fieldPriority.length;
        return order(a) - order(b);
      });
      for (const [key, entry] of entries) {
        if (reference(key, entry)) {
          refs.push(field(friendly(key), valueHtml(entry, key)));
          const resolved = references.get(String(entry));
          if (resolved && key !== "id") regular.push(field(`${friendly(key).replace(/ reference$/i, "")} (saved record)`, escape(resolved)));
        } else if (entry && typeof entry === "object") {
          const suffix = Array.isArray(entry) ? ` · ${entry.length} ${entry.length === 1 ? "record" : "records"}` : "";
          groups.push(`<details class="audit-snapshot-group"><summary>${escape(friendly(key))}${suffix}</summary>${valueHtml(entry, key)}</details>`);
        } else regular.push(field(friendly(key), valueHtml(entry, key)));
      }
      return (regular.length ? `<dl class="audit-snapshot-fields">${regular.join("")}</dl>` : "")
        + groups.join("")
        + (refs.length ? `<details class="audit-snapshot-references"><summary>System references</summary><p class="audit-snapshot-note">Saved record and account IDs. Names appear only when included in this saved data.</p><dl class="audit-snapshot-fields">${refs.join("")}</dl></details>` : "");
    }

    const summaryReferences = [];
    const summary = ["record_label", "record_type", "deleted_by", "deleted_at", "deletion_method", "deletion_reason"]
      .filter(key => own(context, key))
      .map(key => {
        if (reference(key, context[key]) && present(context[key])) {
          summaryReferences.push(field(friendly(key), valueHtml(context[key], key)));
          return field(friendly(key), escape(references.get(String(context[key])) || "Name not saved; see System references"));
        }
        return field(friendly(key), valueHtml(context[key], key));
      }).join("");
    const isBatch = object(snapshot) && object(snapshot.records);
    let body;
    if (isBatch) {
      const metadata = Object.fromEntries(Object.entries(snapshot).filter(([key]) => key !== "records" && key !== "counts"));
      const counts = object(snapshot.counts) ? `<section class="audit-snapshot-section"><h4>Saved record counts</h4>${valueHtml(snapshot.counts, "counts")}</section>` : "";
      const sections = Object.entries(snapshot.records).map(([table, rows]) => {
        const count = Array.isArray(rows) ? ` · ${rows.length} ${rows.length === 1 ? "record" : "records"}` : "";
        const retained = table === "data_change_history" ? '<p class="audit-snapshot-note">Earlier correction audit records are retained. This is the saved copy included with this action.</p>' : "";
        return `<details class="audit-snapshot-group"><summary>${escape(friendly(table))}${count}</summary>${retained}${valueHtml(rows, table)}</details>`;
      }).join("");
      body = `<section class="audit-snapshot-section"><h4>Deletion details</h4>${valueHtml(metadata)}</section>${counts}<section class="audit-snapshot-section"><h4>Related saved records</h4>${sections}</section>`;
      // Preserve unusual historical count representations rather than hiding
      // fields just because they differ from today's batch schema.
      if (own(snapshot, "counts") && !object(snapshot.counts)) body += `<section class="audit-snapshot-section"><h4>Saved counts</h4>${valueHtml(snapshot.counts, "counts")}</section>`;
    } else body = `<section class="audit-snapshot-section"><h4>Saved record details</h4>${valueHtml(snapshot)}</section>`;
    const summaryIds = summaryReferences.length ? `<details class="audit-snapshot-references"><summary>System references</summary><dl class="audit-snapshot-fields">${summaryReferences.join("")}</dl></details>` : "";
    return `<div class="audit-snapshot">${summary ? `<dl class="audit-snapshot-summary">${summary}</dl>` : ""}${summaryIds}<p class="audit-snapshot-note">These are the saved details of this audit record. Times with a saved time zone are shown in Dubai time (UTC+4).</p>${body}</div>`;
  }

  window.GREENLOOP_AUDIT_DETAILS = Object.freeze({ render });
})();
