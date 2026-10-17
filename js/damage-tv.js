/* Manual damage TV views, 20261006-damage-quantity-1. ES5, no external runtime. */
(function () {
  "use strict";
  function start() {
    var api = window.GREENLOOP_TV_API;
    var display=window.GREENLOOP_DAMAGE_DISPLAY;
    function get(id) { return document.getElementById(id); }
    var login = get("tv-login"), board = get("tv-board"), form = get("tv-login-form");
    var username = get("tv-username"), password = get("tv-password"), submit = get("tv-sign-in");
    var active = false, loading = false, busy = false, generation = 0, theme = "light";
    function historySize() { var height = window.innerHeight || document.documentElement.clientHeight; return height <= 650 ? 3 : height <= 800 ? 4 : 6; }
    var rowSize = historySize(), employees = [], rosterRequest = 0, selection = 0, detail = null;
    var autoView = false, autoTimer = null, view = "all";
    var activity = [], updatesPaused = false;
    var tvMode = false, idleTimer = null, autoDeadline = 0, summaries = null;
    function text(id, value) { get(id).textContent = String(value === null || value === undefined ? "" : value); }
    function message(id, value) { text(id, value); get(id).style.display = value ? "block" : "none"; }
    function escape(value) {
      return String(value === null || value === undefined ? "" : value).replace(/[&<>"']/g, function (character) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character];
      });
    }
    function count(value) { return isFinite(Number(value)) && Number(value) >= 0 ? Math.floor(Number(value)) : 0; }
    function validCount(value) { return typeof value === "number" && isFinite(value) && value >= 0 && Math.floor(value) === value; }
    function two(value) { return value < 10 ? "0" + value : String(value); }
    function uaeDate(value) {
      var parts = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)$/.exec(String(value || ""));
      if (!parts) return "Date unavailable";
      var zone = parts[7], shift = 0;
      if (zone !== "Z") {
        var numbers = zone.slice(1).replace(":", "");
        shift = (Number(numbers.slice(0, 2)) * 60 + Number(numbers.slice(2) || 0)) * (zone.charAt(0) === "+" ? 1 : -1);
      }
      var date = new Date(Date.UTC(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]), Number(parts[4]), Number(parts[5]), Number(parts[6])) + (240 - shift) * 60000);
      var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      return two(date.getUTCDate()) + " " + months[date.getUTCMonth()] + " " + date.getUTCFullYear() + " \u00b7 " + clockLabel(date, false);
    }
    function clockLabel(date, seconds) {
      function two(n) { return n < 10 ? "0" + n : String(n); }
      var hour=date.getUTCHours();
      return two(hour % 12 || 12) + ":" + two(date.getUTCMinutes()) + (seconds ? ":" + two(date.getUTCSeconds()) : "") + (hour < 12 ? " AM" : " PM");
    }
    function stamp() {
      var date = new Date(new Date().getTime() + 4 * 60 * 60 * 1000);
      return "Updated " + clockLabel(date, true) + " (UAE)";
    }
    function findEmployee(id, list) {
      list = list || employees;
      for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
      return null;
    }
    function selectedIndex() {
      for (var i = 0; i < employees.length; i++) if (detail && employees[i].id === detail.id) return i;
      return -1;
    }
    function firstPage(employee) {
      return { has_damage:display.hasDamage(employee), id: employee.id, name: employee.name, total_damage: employee.total_damage, record_count: employee.record_count, value_totals: employee.value_totals, unpriced_quantity: employee.unpriced_quantity, copy_value_totals:employee.copy_value_totals, copy_unpriced_quantity:employee.copy_unpriced_quantity, rows: employee.rows, has_more: employee.has_more, offset: 0, loading: false, request: 0, error: "" };
    }
    function controls() {
      var index = selectedIndex(), pending = loading || !!(detail && detail.loading);
      get("tv-refresh").disabled = pending;
      get("tv-auto-toggle").disabled = !employees.length;
      get("damage-prev").disabled = index <= 0;
      get("damage-next").disabled = index < 0 || index >= employees.length - 1;
      get("damage-detail-nav").style.display = view === "detail" && detail ? "block" : "none";
      get("damage-all").setAttribute("aria-pressed", view === "all" ? "true" : "false");
      get("tv-auto-toggle").setAttribute("aria-pressed", autoView ? "true" : "false");
      text("tv-auto-toggle", autoView ? "Pause Auto View \u00b7 5 sec" : "Auto View \u00b7 5 sec");
      text("damage-page", index < 0 ? "" : "Employee " + (index + 1) + " of " + employees.length + (autoView ? " \u00b7 Auto View" : " \u00b7 Paused"));
      var previous = get("damage-history-prev"), next = get("damage-history-next");
      if (previous) previous.disabled = pending || !detail || detail.offset === 0;
      if (next) next.disabled = pending || !detail || !detail.has_more;
      text("damage-view-help", view === "all" ? "Select an employee to read their complete history. Totals include all recorded damage." : "Newest first \u00b7 UAE dates \u00b7 History controls pause Auto View so you can read.");
    }
    function autoProgress() {
      var progress = get("damage-auto-progress"), fill = get("damage-auto-fill");
      if (!progress) return;
      var index = selectedIndex(), upcoming = employees.length ? employees[(index + 1) % employees.length] : null;
      text("damage-auto-label", autoView ? "AUTO VIEW · " + (index + 1) + " / " + employees.length : "EMPLOYEE HISTORY");
      text("damage-up-next", autoView && upcoming ? "Up next: " + upcoming.name : "Use Previous / Next employee to browse");
      text("damage-countdown", autoView ? Math.max(1, Math.ceil((autoDeadline - new Date().getTime()) / 1000)) + " sec" : "Paused");
      progress.style.display = autoView ? "block" : "none";
      var elapsed = autoView && autoDeadline ? Math.max(0, Math.min(100, (1 - (autoDeadline - new Date().getTime()) / 5000) * 100)) : 0;
      fill.style.width = elapsed + "%";
      progress.setAttribute("aria-valuenow", String(Math.round(elapsed)));
    }
    function stopTimer() { if (autoTimer !== null) window.clearTimeout(autoTimer); autoTimer = null; autoDeadline = 0; autoProgress(); }
    function scheduleAuto() {
      stopTimer();
      if (!active || !autoView || document.hidden || !employees.length) return;
      autoDeadline = new Date().getTime() + 5000; autoProgress();
      // A fresh timeout follows each displayed employee: everyone receives the full five seconds.
      autoTimer = window.setTimeout(function () {
        autoTimer = null;
        if (!active || !autoView || document.hidden || !employees.length) return;
        selectEmployee(employees[(selectedIndex() + 1) % employees.length].id, true);
      }, 5000);
    }
    function pauseAuto() { autoView = false; stopTimer(); controls(); }
    function wakeControls() {
      document.body.className = "tv-page damage-tv-page" + (tvMode ? " damage-tv-mode" : "");
      if (idleTimer !== null) window.clearTimeout(idleTimer);
      idleTimer = null;
      if (!active || !tvMode || document.hidden) return;
      idleTimer = window.setTimeout(function () {
        idleTimer = null;
        if (active && tvMode && !document.hidden) document.body.className = "tv-page damage-tv-page damage-tv-mode damage-controls-idle";
      }, 8000);
    }
    function mode(value) {
      tvMode = !!value; get("tv-mode").setAttribute("aria-pressed", tvMode ? "true" : "false");
      text("tv-mode", tvMode ? "Exit TV mode" : "TV mode"); wakeControls();
    }
    function clock() {
      var date = new Date(new Date().getTime() + 4 * 60 * 60 * 1000);
      text("tv-clock", clockLabel(date, true) + " UAE");
    }
    function connection(state) {
      get("tv-connection").className = "tv-live-label" + (state === "Live · 30 sec refresh" ? "" : " tv-connection-stale");
      get("tv-connection").innerHTML = '<i></i>' + escape(state);
    }
    function initials(name) {
      var words = String(name || "").replace(/^\s+|\s+$/g, "").split(/\s+/);
      return (words.length > 1 ? words[0].charAt(0) + words[words.length - 1].charAt(0) : words[0].slice(0, 2)).toUpperCase();
    }
    function moneyValues(employee, copy) {
      var totals = (copy ? employee.copy_value_totals : employee.value_totals) || [], values = [], i;
      for (i = 0; i < totals.length; i++) values.push('<span>' + escape(totals[i].currency) + ' ' + escape(totals[i].amount) + '</span>');
      return values.length ? values.join(' ') : (employee.total_damage ? 'Price not recorded' : 'No damage');
    }
    function dualValues(employee) { return display.dual(moneyValues(employee),moneyValues(employee,true)); }
    function boardValues(data) {
      get("damage-value").innerHTML = dualValues({value_totals:data.value_totals,copy_value_totals:data.copy_value_totals,total_damage:data.total_count});
      text("damage-unpriced", "All history · Separate valuations");
    }
    function selectEmployee(id, automatic) {
      var employee = findEmployee(id);
      if (!employee) return;
      if (summaries) summaries.close(false);
      selection++; detail = firstPage(employee); view = "detail";
      if (!automatic) pauseAuto();
      renderEmployees();
      if (automatic) scheduleAuto();
    }
    function showAll() { if (summaries) summaries.close(false); pauseAuto(); selection++; detail = null; view = "all"; renderEmployees(); }
    function sizeTicker() {
      var track = get("damage-live-track"), first = get("damage-live-text"), copy = get("damage-live-copy");
      var viewport = first.parentNode.parentNode;
      first.style.minWidth = copy.style.minWidth = viewport.clientWidth + "px";
      var seconds = Math.max(20, first.offsetWidth / 45);
      track.style.animationDuration = track.style.webkitAnimationDuration = seconds + "s";
    }
    function tickerState() {
      var state = updatesPaused || !active || document.hidden ? "paused" : "running";
      var track = get("damage-live-track");
      track.style.animationPlayState = track.style.webkitAnimationPlayState = state;
      get("damage-updates-toggle").disabled = !active;
      get("damage-updates-toggle").setAttribute("aria-pressed", updatesPaused ? "true" : "false");
      text("damage-updates-toggle", updatesPaused ? "Resume updates" : "Pause updates");
    }
    function detailText(value) { return typeof value === "string" && value.replace(/\s/g, "") ? value.replace(/\s+/g, " ").replace(/^ | $/g, "") : "Not recorded"; }
    function showActivity() {
      var messages = [], i, entry;
      for (i = 0; i < activity.length; i++) {
        entry = activity[i];
        var amount = price(entry.price_amount), currency = detailText(entry.currency);
        var unitPrice = amount + (currency !== "Not recorded" ? " " + currency : "");
        var cents = amount === "Not recorded" ? null : Math.round(entry.price_amount * 100) * count(entry.quantity);
        var total = cents === null ? "Not recorded" : Math.floor(cents / 100) + "." + two(cents % 100) + (currency !== "Not recorded" ? " " + currency : "");
        var d=display.get(),pieces=["Tech: "+detailText(entry.damaged_by)];
        if(d.show_parts)pieces.push("Model: "+detailText(entry.model),"IMEI / serial / device: "+detailText(entry.identifier),"Part: "+detailText(entry.part_name),"Qty: "+count(entry.quantity));
        if(d.show_original)pieces.push("Original / part: "+unitPrice,"Original total: "+rowTotal(entry));
        if(d.show_copy)pieces.push("Copy / part: "+price(entry.copy_price_amount)+(entry.currency ? " "+entry.currency : ""),"Copy total: "+rowTotal(entry,true));
        if(d.show_parts)pieces.push("Source: "+detailText(entry.part_source),"Reason: "+detailText(entry.reason),"Damage time: "+uaeDate(entry.occurred_at)+" UAE","Entered by: "+detailText(entry.reported_by),"Saved "+uaeDate(entry.created_at)+" UAE");
        messages.push(pieces.join(" · "));
      }
      var line = messages.length ? messages.join("     |     ") : "No damage entries yet. New damage reports will appear here automatically.";
      // Text-only rendering, with an aria-hidden duplicate for the seamless loop.
      // Unchanged refreshes do not restart or jump the running line.
      if (get("damage-live-text").textContent !== line) {
        text("damage-live-text", line); text("damage-live-copy", line);
        var track = get("damage-live-track");
        track.style.animationName = track.style.webkitAnimationName = "none";
        sizeTicker();
        void track.offsetWidth;
        track.style.animationName = track.style.webkitAnimationName = "";
      }
      sizeTicker(); tickerState();
    }
    function renderActivity(entries) {
      activity = (entries || []).slice(0, 5);
      showActivity();
    }
    function clear() {
      if (summaries) summaries.clear();
      activity = []; updatesPaused = false; showActivity();
      employees = []; detail = null; selection++; rosterRequest++; view = "all"; pauseAuto();
      text("damage-today", 0); text("damage-month", 0); text("damage-total", 0);
      text("damage-value", "—"); text("damage-unpriced", "Recorded prices · currencies separate"); mode(false); connection("Connecting");
      get("damage-employees").innerHTML = "";
      text("damage-range", "Waiting for employees"); controls();
    }
    function loginBusy(value) {
      busy = value;
      submit.disabled = value; username.disabled = value; password.disabled = value;
      get("tv-remember").disabled = value; get("tv-show-password").disabled = value;
      submit.textContent = value ? "Signing in..." : "Sign in to damage report";
    }
    function showLogin(value) {
      active = false; loading = false; generation++; syncThemeAccess(); clear();
      get("tv-restoring").style.display = "none"; board.style.display = "none"; login.style.display = "block";
      password.value = ""; password.type = "password";
      get("tv-show-password").textContent = "Show";
      get("tv-show-password").setAttribute("aria-label", "Show password");
      get("tv-show-password").setAttribute("aria-pressed", "false");
      loginBusy(false); message("tv-board-message", ""); text("tv-last-updated", "");
      message("tv-login-message", value);
    }
    function expired(error) { return error && (error.clearSession || /^(NO_SESSION|SESSION_EXPIRED|PERMISSION_DENIED)$/.test(error.code || "")); }
    function inactiveEmployee(error) { return error && /^(EMPLOYEE_NOT_FOUND|EMPLOYEE_INACTIVE)$/.test(error.code || ""); }
    function price(value) {
      return typeof value === "number" && isFinite(value) && value >= 0 && value <= 99999999.99 &&
        Math.round(value * 100) / 100 === value ? value.toFixed(2) : "Not recorded";
    }
    function dualCell(original, copy, label) { return '<td data-label="'+label+'">'+display.dual(escape(original),escape(copy))+'</td>'; }
    function priceCell(row) { var cur=row.currency ? " "+row.currency : "";return dualCell(price(row.price_amount)+cur,price(row.copy_price_amount)+cur,"Price / part"); }
    function cell(value, className, label) { return '<td class="' + className + '" data-label="' + label + '">' + escape(value || "Not recorded") + '</td>'; }
    function valueSummary(employee) {
      var d=display.get(),notes=[];
      if(d.show_original && employee.unpriced_quantity)notes.push('Original '+count(employee.unpriced_quantity));
      if(d.show_copy && employee.copy_unpriced_quantity)notes.push('Copy '+count(employee.copy_unpriced_quantity));
      return '<div class="damage-value-summary">'+(display.prices() ? '<span><small>TOTAL VALUE · ALL RECORDS</small><strong>'+dualValues(employee)+'</strong></span>' : '')+'<span class="damage-record-count">'+count(employee.record_count)+' entries'+(notes.length ? ' · Unpriced parts: '+notes.join(' / ') : '')+'</span></div>';
    }
    function rowTotal(row, copy) {
      var saved=row[copy ? 'copy_entry_total' : 'entry_total'];
      if(saved!==undefined)return saved===null ? 'Not recorded' : Number(saved).toFixed(2)+(row.currency ? ' '+row.currency : '');
      var unit=copy ? row.copy_price_amount : row.price_amount;
      if (price(unit) === "Not recorded") return "Not recorded";
      var cents = Math.round(unit * 100) * count(row.quantity);
      return Math.floor(cents / 100) + "." + two(cents % 100) + (row.currency ? " " + row.currency : "");
    }
    function cardMarkup(employee) {
      var rows = employee.rows || [], html = '', i, row, date;
      html += '<header class="damage-employee-header tv-clear"><div class="damage-identity"><span class="damage-avatar" aria-hidden="true">' + escape(initials(employee.name)) + '</span><p class="damage-identity-label">EMPLOYEE DAMAGE HISTORY</p><h2>' + escape(employee.name) + '</h2></div>' +
        (display.get().show_parts ? '<p class="damage-employee-total"><span>DAMAGED PARTS</span><strong>' + count(employee.total_damage) + '</strong><small>All recorded history</small></p>' : '') + valueSummary(employee) + '</header>' +
        '<div class="damage-auto-caption"><span id="damage-auto-label"></span><strong id="damage-up-next"></strong><span id="damage-countdown"></span></div>' +
        '<div id="damage-auto-progress" class="damage-auto-progress" role="progressbar" aria-label="Time until next employee" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0" style="display:none"><span id="damage-auto-fill"></span></div>' +
        '<div class="damage-table-shell"><table class="damage-table" aria-label="Damage history for ' + escape(employee.name) + '">' +
        '<colgroup><col class="damage-date-column"><col class="damage-model-column"><col class="damage-part-column"><col class="damage-quantity-column"><col class="damage-price-column"><col class="damage-total-column"><col class="damage-source-column"><col class="damage-reason-column"><col class="damage-recorder-column"></colgroup>' +
        '<thead><tr><th scope="col">DATE</th><th scope="col">MODEL / IDENTIFIER</th><th scope="col">PART NAME</th><th scope="col">QTY</th><th scope="col">PRICE / PART</th><th scope="col">ENTRY TOTAL</th><th scope="col">PART SOURCE</th><th scope="col">REASON</th><th scope="col">ENTERED BY / SAVED</th></tr></thead><tbody>';
      for (i = 0; i < rows.length; i++) {
        row = rows[i]; date = uaeDate(row.occurred_at).split(" \u00b7 ");
        html += '<tr><td class="damage-date" data-label="Date" title="' + escape(uaeDate(row.occurred_at)) + ' UAE">' + escape(date[0]) + '<small>' + escape(date[1] || '') + '</small></td>' +
          '<td class="damage-model" data-label="Model / identifier">' + escape(row.model) + '<small class="damage-cell-note">ID: ' + escape(row.identifier || 'Not recorded') + '</small></td>' + cell(row.part_name, "damage-part", "Part name") + cell(row.quantity, "damage-quantity", "Qty") + priceCell(row) + dualCell(rowTotal(row), rowTotal(row,true), "Entry total") + cell(row.part_source, "damage-source", "Part source") + cell(row.reason, "damage-reason", "Reason") + '<td class="damage-recorder" data-label="Entered by / saved">' + escape(row.reported_by || 'Not recorded') + '<small class="damage-cell-note">' + escape(uaeDate(row.created_at)) + ' UAE</small></td></tr>';
      }
      if (!rows.length) html += '<tr><td colspan="9" class="damage-empty-history">' + (display.hasDamage(employee) ? 'History unavailable. Select Refresh now to retry.' : '<span class="damage-zero-symbol" aria-hidden="true">&#10003;</span><strong>No damages recorded</strong><span class="damage-zero-caption">No recorded damage for this employee.</span>') + '</td></tr>';
      html += '</tbody></table></div><div class="damage-history-controls tv-clear">' +
        '<button id="damage-history-prev" class="tv-button damage-history-prev" type="button" data-direction="-1" aria-label="Previous damage records for ' + escape(employee.name) + '">Previous records</button>' +
        '<span class="damage-history-range">' + (rows.length ? (employee.offset + 1) + '\u2013' + (employee.offset + rows.length) + ' of ' + count(employee.record_count) : '0 records') +
        '<small>Page ' + (Math.floor(employee.offset / rowSize) + 1) + ' of ' + Math.max(1, Math.ceil(employee.record_count / rowSize)) + '</small></span>' +
        '<button id="damage-history-next" class="tv-button damage-history-next" type="button" data-direction="1" aria-label="Next damage records for ' + escape(employee.name) + '">Next records</button></div>' +
        '<p class="damage-history-message" role="status"' + (employee.error || employee.loading ? '' : ' style="display:none"') + '>' + escape(employee.loading ? 'Loading history...' : employee.error || '') + '</p>';
      var hidden=[];
      if(!display.get().show_parts)hidden=hidden.concat([0,1,2,3,6,7,8]);
      if(!display.prices())hidden=hidden.concat([4,5]);
      return display.table(html,hidden);
    }
    function renderEmployees() {
      var html = '', i, focused = document.activeElement && document.activeElement.id;
      display.apply();
      board.className = "tv-board damage-" + view;
      if (view === "detail" && detail) html = '<article id="damage-detail" class="damage-employee' + (display.hasDamage(detail) ? ' damage-has-damage' : '') + '" tabindex="0">' + cardMarkup(detail) + '</article>';
      else for (i = 0; i < employees.length; i++) {
        html += '<div class="damage-employee-cell"><button id="damage-employee-' + i + '" class="damage-compact-card' + (display.hasDamage(employees[i]) ? ' damage-has-damage' : '') + '" type="button" data-employee="' + escape(employees[i].id) + '" aria-label="' + escape(employees[i].name) + (display.get().show_parts ? ', ' + count(employees[i].total_damage) + ' total damage.' : '') + ' Open history.">' +
          '<span class="damage-card-top"><span class="damage-card-avatar" aria-hidden="true">' + escape(initials(employees[i].name)) + '</span><span class="damage-card-state">' + (display.hasDamage(employees[i]) ? 'DAMAGE RECORDED' : 'CLEAR RECORD') + '</span></span>' +
          '<span class="damage-compact-name">' + escape(employees[i].name) + '</span>' + (display.get().show_parts ? '<span class="damage-compact-total"><strong>' + count(employees[i].total_damage) + '</strong><small>damaged parts</small></span>' : '') +
          '<span class="damage-compact-value">' + (display.hasDamage(employees[i]) ? (display.prices() ? dualValues(employees[i]) : 'View damage details') : '&#10003; No damage') + '</span>' +
          (employees[i].unpriced_quantity && employees[i].value_totals && employees[i].value_totals.length ? '<span class="damage-compact-unpriced">' + count(employees[i].unpriced_quantity) + ' parts without price</span>' : '') + '</button></div>';
      }
      get("damage-employees").innerHTML = html || '<p class="tv-empty">No active employees are available.</p>';
      text("damage-range", employees.length + " employees · Select a card for complete history"); controls(); autoProgress();
      var target = focused && get(focused);
      if (target && target.disabled && /^damage-history-/.test(focused)) target = get("damage-detail");
      if (target && !target.disabled && target.getClientRects().length) target.focus();
    }
    function refresh(retried) {
      if (!active || loading || (detail && detail.loading)) return;
      var ticket = generation, request = ++rosterRequest, collected = [], seen = {}, first = null;
      loading = true; controls();
      function current() { return ticket === generation && request === rosterRequest && active; }
      function fail(error) {
        if (!current()) return;
        loading = false; controls();
        if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); }
        else { connection(navigator.onLine === false ? "Offline · saved display" : "Update delayed · retrying"); message("tv-board-message", (error.message || "The report could not be refreshed.") + " Last shown figures have not been updated. Select Refresh now to retry."); }
      }
      function changed() {
        if (!current()) return;
        loading = false;
        if (!retried) { refresh(true); return; }
        fail({ message: "The employee list changed while loading." });
      }
      function commit(savedSelection, refreshed, warning) {
        if (!current()) return;
        employees = collected; loading = false;
        if (detail) {
          var incoming = findEmployee(detail.id);
          if (!incoming) { selection++; detail = employees.length && autoView ? firstPage(employees[0]) : null; if (!detail) { view = "all"; pauseAuto(); } scheduleAuto(); }
          else detail = selection === savedSelection && refreshed ? refreshed : firstPage(incoming);
        }
        renderActivity(first.activity);
        text("damage-today", count(first.today_count)); text("damage-month", count(first.month_count)); text("damage-total", count(first.total_count));
        boardValues(first); connection("Live · 30 sec refresh"); renderEmployees(); text("tv-last-updated", stamp()); message("tv-board-message", warning || "");
        if (summaries) summaries.refresh();
      }
      function finish() {
        if (!current()) return;
        var chosen = detail, savedSelection = selection, incoming = chosen && findEmployee(chosen.id, collected);
        if (!chosen || !incoming || !chosen.offset) { commit(savedSelection, null, ""); return; }
        var next = firstPage(incoming), attempts = 0;
        next.offset = Math.min(chosen.offset, Math.max(0, Math.floor((incoming.record_count - 1) / rowSize) * rowSize));
        function rows() {
          api.loadEmployeeDamageRows(next.id, next.offset, rowSize, function (error, history) {
            if (!current()) return;
            if (error && expired(error)) { fail(error); return; }
            if (selection !== savedSelection) { commit(savedSelection, null, ""); return; }
            if (error && inactiveEmployee(error)) { changed(); return; }
            if (error) {
              next = chosen; next.loading = false; next.error = "History not updated. Select Refresh now to retry.";
              commit(savedSelection, next, "This employee's history could not be refreshed. Previous rows remain visible."); return;
            }
            next.has_damage=display.hasDamage(history); next.copy_value_totals=history.copy_value_totals; next.copy_unpriced_quantity=history.copy_unpriced_quantity; next.value_totals = history.value_totals; next.unpriced_quantity = history.unpriced_quantity; next.rows = history.rows; next.total_damage = count(history.total_damage); next.record_count = count(history.record_count); next.has_more = !!history.has_more;
            if (!next.rows.length && next.offset && next.offset >= next.record_count) {
              if (attempts++) { changed(); return; }
              next.offset = Math.max(0, Math.floor((next.record_count - 1) / rowSize) * rowSize); rows(); return;
            }
            commit(savedSelection, next, "");
          });
        }
        if (next.offset) rows(); else commit(savedSelection, next, "");
      }
      function page(offset) {
        api.loadDamageCards(offset, 100, rowSize, function (error, data) {
          if (!current()) return;
          if (error) { fail(error); return; }
          var i, employee;
          if (!data || !validCount(data.employee_count) || !data.employees || typeof data.has_more !== "boolean" || data.employees.length > 100) { changed(); return; }
          if (!first) first = data;
          else if (data.employee_count !== first.employee_count || data.today_count !== first.today_count || data.month_count !== first.month_count || data.total_count !== first.total_count || data.record_count !== first.record_count || JSON.stringify(data.value_totals) !== JSON.stringify(first.value_totals) || data.unpriced_quantity !== first.unpriced_quantity || JSON.stringify(data.copy_value_totals) !== JSON.stringify(first.copy_value_totals) || data.copy_unpriced_quantity !== first.copy_unpriced_quantity) { changed(); return; }
          for (i = 0; i < data.employees.length; i++) {
            employee = data.employees[i];
            if (!employee || typeof employee.id !== "string" || !employee.id || seen["id:" + employee.id]) { changed(); return; }
            seen["id:" + employee.id] = true; collected.push(employee);
          }
          // Every page must advance towards the same count. Never publish a partial roster.
          if (collected.length > first.employee_count || (data.has_more && (!data.employees.length || collected.length >= first.employee_count)) || (!data.has_more && collected.length !== first.employee_count)) { changed(); return; }
          if (data.has_more) page(collected.length); else finish();
        });
      }
      page(0);
    }
    function historyPage(direction) {
      if (!active || loading || !detail || detail.loading) return;
      var employee = detail, requested = Math.max(0, employee.offset + direction * rowSize);
      if (requested === employee.offset || direction > 0 && !employee.has_more) return;
      pauseAuto(); employee.loading = true; employee.error = '';
      var ticket = generation, roster = rosterRequest, chosen = selection, request = ++employee.request;
      renderEmployees();
      api.loadEmployeeDamageRows(employee.id, requested, rowSize, function (error, data) {
        if (!active || ticket !== generation || roster !== rosterRequest || chosen !== selection || detail !== employee || request !== employee.request) return;
        employee.loading = false;
        if (error) {
          if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); return; }
          if (inactiveEmployee(error)) { employee.error = "Employee roster changed. Refreshing..."; renderEmployees(); refresh(); return; }
          employee.error = (error.message || "History could not be loaded.") + " Select Next or Previous to retry."; renderEmployees(); return;
        }
        employee.has_damage=display.hasDamage(data); employee.copy_value_totals=data.copy_value_totals; employee.copy_unpriced_quantity=data.copy_unpriced_quantity; employee.value_totals = data.value_totals; employee.unpriced_quantity = data.unpriced_quantity; employee.total_damage = count(data.total_damage); employee.record_count = count(data.record_count); employee.rows = data.rows; employee.has_more = !!data.has_more; employee.offset = requested;
        if (!employee.rows.length && requested >= employee.record_count) { employee.offset = 0; refresh(); return; }
        renderEmployees();
      });
    }
    if (api) api.onDisplayChanged=function(){
      generation++;loading=false;clear();display.apply();
      if(active){message("tv-board-message","Display settings updated. Loading…");refresh();}
    };
    function openBoard() {
      active = true; loading = false; syncThemeAccess();
      get("tv-restoring").style.display = "none"; login.style.display = "none"; board.style.display = "block";
      message("tv-login-message", ""); message("tv-board-message", "Loading damage report...");
      pauseAuto(); refresh(); clock(); get("damage-all").focus(); wakeControls();
    }
    function canChangeDisplayMode() {
      return !!api && active && typeof api.canAppearance === "function" && api.canAppearance("display_mode");
    }
    function syncThemeAccess() {
      var button = get("tv-theme-toggle"), allowed = canChangeDisplayMode();
      button.disabled = !allowed;
      button.hidden = !allowed;
      button.style.display = allowed ? "" : "none";
      button.setAttribute("aria-disabled", allowed ? "false" : "true");
    }
    function setTheme(value) {
      theme = value === "dark" ? "dark" : "light";
      document.documentElement.className = theme === "dark" ? "tv-dark" : "";
      get("tv-theme-toggle").textContent = theme === "dark" ? "Light mode" : "Dark mode";
      get("tv-theme-toggle").setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
      try { window.localStorage.setItem("greenloop-tv-theme", theme); } catch (ignore) {}
    }
    try { theme = window.localStorage.getItem("greenloop-tv-theme") || "light"; } catch (ignore) {}
    setTheme(theme);
    if (api) api.onAppearanceChanged = syncThemeAccess;
    syncThemeAccess();
    get("tv-theme-toggle").onclick = function () {
      if (!canChangeDisplayMode()) { syncThemeAccess(); return; }
      pauseAuto(); setTheme(theme === "light" ? "dark" : "light");
    };
    if (!api || typeof api.restore !== "function" || typeof api.login !== "function" || typeof api.logout !== "function" || typeof api.loadDamageCards !== "function" || typeof api.loadEmployeeDamageRows !== "function" || typeof api.loadDamageSummary !== "function" || typeof window.GREENLOOP_DAMAGE_SUMMARY !== "function") {
      showLogin("This page did not finish loading. Reload the page and check the TV internet connection."); submit.disabled = true; return;
    }
    summaries = window.GREENLOOP_DAMAGE_SUMMARY(api, {onOpen:showAll, expired:expired, date:uaeDate, onExpired:function(error){showLogin(error.message || "Please sign in again.");username.focus();}});
    api.onSessionInvalidated = function (error) { showLogin(error && error.message || "Please sign in again."); username.focus(); };
    get("tv-show-password").onclick = function () {
      var show = password.type === "password"; password.type = show ? "text" : "password";
      this.textContent = show ? "Hide" : "Show"; this.setAttribute("aria-label", show ? "Hide password" : "Show password"); this.setAttribute("aria-pressed", show ? "true" : "false");
    };
    form.onsubmit = function (event) {
      if (event) event.preventDefault();
      if (busy) return false;
      var name = username.value.replace(/^\s+|\s+$/g, "");
      if (!name || !password.value) { message("tv-login-message", "Enter your username and password."); (name ? password : username).focus(); return false; }
      var ticket = ++generation;
      loginBusy(true); message("tv-login-message", "Signing in...");
      api.login(name, password.value, get("tv-remember").checked, function (error) {
        if (ticket !== generation) return;
        password.value = ""; loginBusy(false);
        if (error) { showLogin(error.message || "Could not sign in. Please try again."); return; }
        openBoard();
      });
      return false;
    };
    get("damage-employees").onclick = function (event) {
      var target = (event || window.event).target || (event || window.event).srcElement;
      while (target && target !== this && target.tagName !== "BUTTON") target = target.parentNode;
      if (!target || target === this || target.disabled) return;
      var employeeId = target.getAttribute("data-employee"), direction = target.getAttribute("data-direction");
      if (employeeId) { selectEmployee(employeeId, false); get("damage-detail").focus(); }
      else if (direction) historyPage(Number(direction));
    };
    get("damage-all").onclick = showAll;
    get("tv-refresh").onclick = function () { pauseAuto(); refresh(); };
    get("damage-prev").onclick = function () { var index = selectedIndex(); if (index > 0) selectEmployee(employees[index - 1].id, false); };
    get("damage-next").onclick = function () { var index = selectedIndex(); if (index >= 0 && index + 1 < employees.length) selectEmployee(employees[index + 1].id, false); };
    get("tv-auto-toggle").onclick = function () {
      if (autoView) { pauseAuto(); return; }
      if (!employees.length) return;
      autoView = true; selectEmployee(detail ? detail.id : employees[0].id, true);
    };
    get("tv-mode").onclick = function () { mode(!tvMode); };
    get("tv-logout").onclick = function () { showLogin("Signed out."); api.logout(function () {}); username.focus(); };
    get("tv-fullscreen").onclick = function () {
      pauseAuto();
      var root = document.documentElement;
      var full = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
      var action = full ? document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen : root.requestFullscreen || root.webkitRequestFullscreen || root.mozRequestFullScreen;
      function unavailable() { message("tv-board-message", "Use the TV browser's full-screen option to hide its address bar."); }
      if (!action) { unavailable(); return; }
      try { var result = action.call(full ? document : root); if (result && typeof result["catch"] === "function") result["catch"](unavailable); } catch (ignore) { unavailable(); }
    };
    function fullChanged() { mode(!!(document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement)); text("tv-fullscreen", document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement ? "Exit full screen" : "Full screen"); }
    document.addEventListener("fullscreenchange", fullChanged); document.addEventListener("webkitfullscreenchange", fullChanged); document.addEventListener("mozfullscreenchange", fullChanged);
    // Clicking/touching a record or navigating with the remote gives the reader control.
    document.addEventListener("click", function (event) { if (event.target !== get("tv-auto-toggle") && autoView) pauseAuto(); }, true);
    document.addEventListener("keydown", function (event) {
      wakeControls();
      var key = event.keyCode || event.which;
      if (autoView && !(document.activeElement === get("tv-auto-toggle") && (key === 13 || key === 32))) pauseAuto();
      if (key < 37 || key > 40 || event.altKey || event.ctrlKey || event.metaKey) return;
      var current = document.activeElement;
      if ((current === username || current === password) && (key === 37 || key === 39)) return;
      var nodes = document.querySelectorAll("a[href],button,input,select,[tabindex='0']"), controlsList = [], i, index = -1;
      for (i = 0; i < nodes.length; i++) if (!nodes[i].disabled && nodes[i].getClientRects().length) {
        if (nodes[i] === current) index = controlsList.length;
        controlsList.push(nodes[i]);
      }
      if (!controlsList.length) return;
      var next = index < 0 ? 0 : (index + (key === 37 || key === 38 ? -1 : 1) + controlsList.length) % controlsList.length;
      event.preventDefault(); controlsList[next].focus();
    });
    get("damage-updates-toggle").onclick = function () { updatesPaused = !updatesPaused; tickerState(); };
    window.addEventListener("resize", function () { sizeTicker(); var nextSize = historySize(); if (rowSize !== nextSize) { rowSize = nextSize; refresh(); } });
    document.addEventListener("mousemove", wakeControls);
    document.addEventListener("touchstart", wakeControls);
    document.addEventListener("focusin", wakeControls);
    window.addEventListener("offline", function () { if (active) connection("Offline · saved display"); });
    window.setInterval(function () { if (active && !document.hidden) { clock(); autoProgress(); } }, 100);
    clock();
    window.setInterval(function () { if (!document.hidden) refresh(); }, 30000);
    document.addEventListener("visibilitychange", function () { stopTimer(); tickerState(); wakeControls(); if (!document.hidden) { scheduleAuto(); refresh(); } });
    window.addEventListener("online", function () { refresh(); });
    var restoreTicket = generation;
    api.restore(function (error, result) {
      if (restoreTicket !== generation) return;
      if (!error && result && result.authenticated) openBoard();
      else showLogin(error && error.code !== "NO_SESSION" ? error.message || "Please sign in again." : "");
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
}());
