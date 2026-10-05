/* Manual damage TV report, 20261005-tv-damage-access-1. ES5, no external runtime. */
(function () {
  "use strict";
  function start() {
    var api = window.GREENLOOP_TV_API;
    function get(id) { return document.getElementById(id); }
    var login = get("tv-login"), board = get("tv-board"), form = get("tv-login-form");
    var username = get("tv-username"), password = get("tv-password"), submit = get("tv-sign-in");
    var active = false, loading = false, busy = false, generation = 0, theme = "light";
    // Keep this size stable until reload: changing it mid-session would skip employees.
    var pageSize = (window.innerWidth || document.documentElement.clientWidth) >= 1600 ? 4 : 2;
    var rowSize = 6, offset = 0, total = 0, hasMore = false, autoPages = false;
    var employees = [], rosterRequest = 0;
    var activity = [], activityIndex = 0, updatesPaused = false;
    function text(id, value) { get(id).textContent = String(value === null || value === undefined ? "" : value); }
    function message(id, value) { text(id, value); get(id).style.display = value ? "block" : "none"; }
    function escape(value) {
      return String(value === null || value === undefined ? "" : value).replace(/[&<>"']/g, function (character) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character];
      });
    }
    function count(value) { return isFinite(Number(value)) && Number(value) >= 0 ? Math.floor(Number(value)) : 0; }
    function two(value) { return value < 10 ? "0" + value : String(value); }
    function uaeDate(value) {
      // Parse PostgreSQL ISO timestamps directly; old TV engines differ on Date.parse.
      var parts = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)$/.exec(String(value || ""));
      if (!parts) return "Date unavailable";
      var zone = parts[7], shift = 0;
      if (zone !== "Z") {
        var numbers = zone.slice(1).replace(":", "");
        shift = (Number(numbers.slice(0, 2)) * 60 + Number(numbers.slice(2) || 0)) * (zone.charAt(0) === "+" ? 1 : -1);
      }
      var date = new Date(Date.UTC(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]), Number(parts[4]), Number(parts[5]), Number(parts[6])) + (240 - shift) * 60000);
      var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      return two(date.getUTCDate()) + " " + months[date.getUTCMonth()] + " " + date.getUTCFullYear() + " \u00b7 " + two(date.getUTCHours()) + ":" + two(date.getUTCMinutes());
    }
    function stamp() {
      var date = new Date(new Date().getTime() + 4 * 60 * 60 * 1000);
      return "Updated " + two(date.getUTCHours()) + ":" + two(date.getUTCMinutes()) + ":" + two(date.getUTCSeconds()) + " (UAE)";
    }
    function pendingHistory() {
      for (var i = 0; i < employees.length; i++) if (employees[i].loading) return true;
      return false;
    }
    function controls() {
      var pending = loading || pendingHistory(), i, employee, previous, next;
      get("tv-refresh").disabled = pending;
      get("damage-prev").disabled = pending || offset === 0;
      get("damage-next").disabled = pending || !hasMore;
      text("damage-page", "Page " + (Math.floor(offset / pageSize) + 1) + " of " + Math.max(1, Math.ceil(total / pageSize)));
      for (i = 0; i < employees.length; i++) {
        employee = employees[i]; previous = get("damage-history-prev-" + i); next = get("damage-history-next-" + i);
        if (previous) previous.disabled = loading || employee.loading || employee.offset === 0;
        if (next) next.disabled = loading || employee.loading || !employee.has_more;
      }
    }
    function setAuto(value) {
      autoPages = !!value;
      get("tv-auto-toggle").setAttribute("aria-pressed", autoPages ? "true" : "false");
      text("tv-auto-toggle", autoPages ? "Auto pages: on \u00b7 15 sec" : "Auto pages: off");
    }
    function showActivity() {
      var entry = activity[activityIndex];
      text("damage-live-text", entry ? entry.damaged_by + " \u00b7 " + entry.model + " \u00b7 Part: " +
        (entry.part_name || "Not recorded") + " \u00b7 Reason: " + entry.reason +
        " \u00b7 Saved " + uaeDate(entry.created_at) + " UAE" : "No damage entries yet.");
      get("damage-updates-toggle").disabled = activity.length < 2;
      get("damage-updates-toggle").setAttribute("aria-pressed", updatesPaused ? "true" : "false");
      text("damage-updates-toggle", updatesPaused ? "Resume updates" : "Pause updates");
    }
    function renderActivity(entries) {
      var previous = activity[activityIndex], newest = activity[0], i;
      activity = entries || []; activityIndex = 0;
      if (previous && newest && activity[0] && newest.id === activity[0].id) {
        for (i = 0; i < activity.length; i++) if (activity[i].id === previous.id) activityIndex = i;
      }
      showActivity();
    }
    function clear() {
      activity = []; activityIndex = 0; updatesPaused = false; showActivity();
      offset = 0; total = 0; hasMore = false; employees = []; rosterRequest++; setAuto(false);
      text("damage-today", 0); text("damage-month", 0); text("damage-total", 0);
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
      active = false; loading = false; generation++; clear();
      board.style.display = "none"; login.style.display = "block";
      password.value = ""; password.type = "password";
      get("tv-show-password").textContent = "Show";
      get("tv-show-password").setAttribute("aria-label", "Show password");
      get("tv-show-password").setAttribute("aria-pressed", "false");
      loginBusy(false); message("tv-board-message", ""); text("tv-last-updated", "");
      message("tv-login-message", value);
    }
    function expired(error) {
      return error && (error.clearSession || /^(NO_SESSION|SESSION_EXPIRED|PERMISSION_DENIED)$/.test(error.code || ""));
    }
    function inactiveEmployee(error) {
      return error && /^(EMPLOYEE_NOT_FOUND|EMPLOYEE_INACTIVE)$/.test(error.code || "");
    }
    function findEmployee(id) {
      for (var i = 0; i < employees.length; i++) if (employees[i].id === id) return employees[i];
      return null;
    }
    function cell(value, className) {
      return '<td class="' + (className || "") + '">' + escape(value || "Not recorded") + '</td>';
    }
    function cardMarkup(employee, index) {
      var rows = employee.rows || [], html = '', i, row, date;
      html += '<header class="damage-employee-header tv-clear"><h2>' + escape(employee.name) + '</h2>' +
        '<p class="damage-employee-total"><span>TOTAL DAMAGE</span><strong>' + count(employee.total_damage) + '</strong></p></header>' +
        '<div class="damage-table-shell"><table class="damage-table" aria-label="Damage history for ' + escape(employee.name) + '">' +
        '<colgroup><col class="damage-date-column"><col class="damage-model-column"><col class="damage-part-column"><col class="damage-reason-column"></colgroup>' +
        '<thead><tr><th scope="col">DATE</th><th scope="col">MODEL</th><th scope="col">PART NAME</th><th scope="col">REASON</th></tr></thead><tbody>';
      for (i = 0; i < rows.length; i++) {
        row = rows[i]; date = uaeDate(row.occurred_at).split(" \u00b7 ");
        html += '<tr><td class="damage-date" title="' + escape(uaeDate(row.occurred_at)) + ' UAE" aria-label="' + escape(uaeDate(row.occurred_at)) + ' UAE">' + escape(date[0]) + '</td>' +
          cell(row.model, "damage-model") + cell(row.part_name, "damage-part") + cell(row.reason, "damage-reason") + '</tr>';
      }
      if (!rows.length) html += '<tr><td colspan="4" class="damage-empty-history">' + (employee.total_damage ? 'History unavailable. Select Refresh now to retry.' : 'No damages recorded') + '</td></tr>';
      html += '</tbody></table></div><div class="damage-history-controls tv-clear">' +
        '<button id="damage-history-prev-' + index + '" class="tv-button damage-history-prev" type="button" data-employee="' + escape(employee.id) + '" aria-label="Previous damage records for ' + escape(employee.name) + '">Previous</button>' +
        '<span class="damage-history-range">' + (rows.length ? (employee.offset + 1) + '\u2013' + (employee.offset + rows.length) + ' of ' + count(employee.total_damage) : '0 records') +
        '<small>Page ' + (Math.floor(employee.offset / rowSize) + 1) + ' of ' + Math.max(1, Math.ceil(employee.total_damage / rowSize)) + '</small></span>' +
        '<button id="damage-history-next-' + index + '" class="tv-button damage-history-next" type="button" data-employee="' + escape(employee.id) + '" aria-label="Next damage records for ' + escape(employee.name) + '">Next</button></div>' +
        '<p class="damage-history-message" role="status"' + (employee.error || employee.loading ? '' : ' style="display:none"') + '>' + escape(employee.loading ? 'Loading history...' : employee.error || '') + '</p>';
      return html;
    }
    function restoreFocus(id) {
      var target = id && get(id), card;
      if (target && target.disabled) {
        card = /^damage-history-(?:prev|next)-(\d+)$/.exec(id);
        if (card) target = get("damage-employee-" + card[1]);
      }
      if (target && !target.disabled && target.getClientRects().length) target.focus();
    }
    function renderCard(employee) {
      var index, element, focused = document.activeElement && document.activeElement.id;
      for (index = 0; index < employees.length; index++) if (employees[index] === employee) break;
      element = get("damage-employee-" + index);
      if (!element) return;
      element.innerHTML = cardMarkup(employee, index); controls(); restoreFocus(focused);
    }
    function render(data) {
      renderActivity(data.activity);
      var html = '', i, focused = document.activeElement && document.activeElement.id;
      text("damage-today", count(data.today_count)); text("damage-month", count(data.month_count)); text("damage-total", count(data.total_count));
      for (i = 0; i < employees.length; i++) {
        html += '<div class="damage-employee-cell"><article id="damage-employee-' + i + '" class="damage-employee" tabindex="0" aria-label="' + escape(employees[i].name) + ' damage card">' + cardMarkup(employees[i], i) + '</article></div>';
      }
      get("damage-employees").innerHTML = html || '<p class="tv-empty">No active employees are available.</p>';
      text("damage-range", employees.length ? (offset + 1) + "\u2013" + (offset + employees.length) + " of " + total + " employees" : "0 employees");
      controls(); restoreFocus(focused);
    }
    function refresh(nextOffset, rosterRetried) {
      if (!active || loading || pendingHistory()) return;
      var requested = typeof nextOffset === "number" ? Math.max(0, nextOffset) : offset;
      var changingPage = requested !== offset, ticket = generation, request = ++rosterRequest;
      loading = true; controls();
      function current() { return ticket === generation && request === rosterRequest && active; }
      function fail(error) {
        if (!current()) return;
        loading = false; controls();
        if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); }
        else message("tv-board-message", (error.message || "The report could not be refreshed.") + " Last shown figures have not been updated. Select Refresh now to retry.");
      }
      api.loadDamageCards(requested, pageSize, rowSize, function (error, data) {
        if (!current()) return;
        if (error) { fail(error); return; }
        var employeeTotal = count(data.employee_count), nextEmployees = [], remaining = 0, stale = false, rosterChanged = false, finished = false, i, previous, incoming, state;
        if (requested > 0 && requested >= employeeTotal) {
          loading = false;
          refresh(employeeTotal ? Math.floor((employeeTotal - 1) / pageSize) * pageSize : 0, rosterRetried);
          return;
        }
        for (i = 0; i < data.employees.length; i++) {
          incoming = data.employees[i]; previous = changingPage ? null : findEmployee(incoming.id);
          state = { id: incoming.id, name: incoming.name, total_damage: count(incoming.total_damage), rows: incoming.rows, has_more: incoming.has_more, offset: 0, loading: false, request: 0, error: '' };
          // Re-fetch selected history pages: never show the first six rows under
          // a page-two label when the 30-second roster refresh arrives.
          if (previous && previous.offset) {
            state.offset = Math.min(previous.offset, Math.max(0, Math.floor((state.total_damage - 1) / rowSize) * rowSize));
            if (state.offset) remaining++;
          }
          nextEmployees.push(state);
        }
        function finish() {
          if (!current() || remaining || finished) return;
          finished = true; loading = false;
          if (rosterChanged && !rosterRetried) { refresh(requested, true); return; }
          employees = nextEmployees; offset = requested; total = employeeTotal; hasMore = !!data.has_more;
          render(data); text("tv-last-updated", stamp());
          message("tv-board-message", rosterChanged ? "The employee roster changed. Select Refresh now to reload it." : stale ? "Some employee histories could not be refreshed. Their previous rows remain visible." : "");
        }
        function updateHistory(employee) {
          api.loadEmployeeDamageRows(employee.id, employee.offset, rowSize, function (rowError, history) {
            if (!current()) return;
            if (rowError && expired(rowError)) { fail(rowError); return; }
            if (rowError) {
              if (inactiveEmployee(rowError)) {
                rosterChanged = true;
                for (var j = nextEmployees.length - 1; j >= 0; j--) if (nextEmployees[j] === employee) nextEmployees.splice(j, 1);
              } else {
                var old = findEmployee(employee.id);
                if (old) { employee.rows = old.rows; employee.offset = old.offset; employee.has_more = old.has_more; }
                employee.error = "History not updated. Select Refresh now to retry."; stale = true;
              }
            } else {
              employee.rows = history.rows; employee.total_damage = count(history.total_damage); employee.has_more = !!history.has_more;
              // An incident can disappear between the summary and history calls.
              // Move to the last remaining page, keeping rows and page labels aligned.
              if (!employee.rows.length && employee.offset && employee.offset >= employee.total_damage) {
                employee.offset = Math.max(0, Math.floor((employee.total_damage - 1) / rowSize) * rowSize);
                updateHistory(employee); return;
              }
            }
            remaining--; finish();
          });
        }
        // Populate the whole list before callbacks, including synchronous APIs.
        var details = nextEmployees.slice(0);
        for (i = 0; i < details.length; i++) if (details[i].offset) updateHistory(details[i]);
        finish();
      });
    }
    function historyPage(id, direction) {
      var employee = findEmployee(id);
      if (!active || loading || !employee || employee.loading) return;
      var requested = Math.max(0, employee.offset + direction * rowSize);
      if (requested === employee.offset || direction > 0 && !employee.has_more) return;
      setAuto(false); employee.loading = true; employee.error = '';
      var ticket = generation, roster = rosterRequest, request = ++employee.request;
      controls();
      api.loadEmployeeDamageRows(id, requested, rowSize, function (error, data) {
        if (!active || ticket !== generation || roster !== rosterRequest || findEmployee(id) !== employee || request !== employee.request) return;
        employee.loading = false;
        if (error) {
          if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); return; }
          if (inactiveEmployee(error)) {
            employee.rows = []; employee.error = "Employee roster changed. Refreshing..."; renderCard(employee); refresh(); return;
          }
          employee.error = (error.message || "History could not be loaded.") + " Select Next or Previous to retry.";
          renderCard(employee); return;
        }
        employee.total_damage = count(data.total_damage); employee.rows = data.rows; employee.has_more = !!data.has_more; employee.offset = requested;
        if (!employee.rows.length && requested >= employee.total_damage) {
          employee.offset = 0; refresh(); return;
        }
        renderCard(employee);
      });
    }
    function openBoard() {
      active = true; loading = false;
      login.style.display = "none"; board.style.display = "block";
      message("tv-login-message", ""); message("tv-board-message", "Loading damage report...");
      setAuto(false); refresh(0); get("tv-auto-toggle").focus();
    }
    function setTheme(value) {
      theme = value === "dark" ? "dark" : "light";
      document.documentElement.className = theme === "dark" ? "tv-dark" : "";
      get("tv-theme-toggle").textContent = theme === "dark" ? "Light mode" : "Dark mode";
      get("tv-theme-toggle").setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
      try { window.localStorage.setItem("greenloop-tv-theme", theme); } catch (ignore) {}
    }
    if (!api || typeof api.loadDamageCards !== "function" || typeof api.loadEmployeeDamageRows !== "function") {
      message("tv-login-message", "This page did not finish loading. Reload the page and check the TV internet connection.");
      submit.disabled = true; return;
    }
    api.onSessionInvalidated = function (error) { showLogin(error && error.message || "Please sign in again."); username.focus(); };
    try { theme = window.localStorage.getItem("greenloop-tv-theme") || "light"; } catch (ignore) {}
    setTheme(theme);
    get("tv-theme-toggle").onclick = function () { setTheme(theme === "light" ? "dark" : "light"); };
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
      var employeeId = target.getAttribute("data-employee");
      if (employeeId) historyPage(employeeId, target.className.indexOf("damage-history-prev") >= 0 ? -1 : 1);
    };
    get("tv-refresh").onclick = function () { refresh(); };
    get("damage-prev").onclick = function () { setAuto(false); refresh(Math.max(0, offset - pageSize)); };
    get("damage-next").onclick = function () { if (hasMore) { setAuto(false); refresh(offset + pageSize); } };
    get("tv-auto-toggle").onclick = function () { setAuto(!autoPages); };
    get("tv-logout").onclick = function () { showLogin("Signed out."); api.logout(function () {}); username.focus(); };
    get("tv-fullscreen").onclick = function () {
      var root = document.documentElement;
      var full = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
      var action = full ? document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen : root.requestFullscreen || root.webkitRequestFullscreen || root.mozRequestFullScreen;
      function unavailable() { message("tv-board-message", "Use the TV browser's full-screen option to hide its address bar."); }
      if (!action) { unavailable(); return; }
      try { var result = action.call(full ? document : root); if (result && typeof result["catch"] === "function") result["catch"](unavailable); } catch (ignore) { unavailable(); }
    };
    function fullChanged() { text("tv-fullscreen", document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement ? "Exit full screen" : "Full screen"); }
    document.addEventListener("fullscreenchange", fullChanged); document.addEventListener("webkitfullscreenchange", fullChanged); document.addEventListener("mozfullscreenchange", fullChanged);
    document.addEventListener("keydown", function (event) {
      var key = event.keyCode || event.which;
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
    get("damage-updates-toggle").onclick = function () { updatesPaused = !updatesPaused; showActivity(); };
    window.setInterval(function () {
      if (active && !document.hidden && !updatesPaused && activity.length > 1) {
        activityIndex = (activityIndex + 1) % activity.length; showActivity();
      }
    }, 8000);
    window.setInterval(function () { if (!document.hidden) refresh(); }, 30000);
    window.setInterval(function () { if (active && autoPages && !document.hidden && !loading && total > pageSize) refresh(hasMore ? offset + pageSize : 0); }, 15000);
    document.addEventListener("visibilitychange", function () { if (!document.hidden) refresh(); });
    window.addEventListener("online", function () { refresh(); });
    showLogin("");
    var restoreTicket = generation;
    api.restore(function (error, result) {
      if (restoreTicket !== generation) return;
      if (!error && result && result.authenticated) openBoard();
      else if (error && error.code !== "NO_SESSION") message("tv-login-message", error.message || "Please sign in again.");
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
}());
