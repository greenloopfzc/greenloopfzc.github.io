/* Manual damage TV report, 20261003-manual-damage-1. ES5, no external runtime. */
(function () {
  "use strict";
  function start() {
    var api = window.GREENLOOP_TV_API;
    function get(id) { return document.getElementById(id); }
    var login = get("tv-login"), board = get("tv-board"), form = get("tv-login-form");
    var username = get("tv-username"), password = get("tv-password"), submit = get("tv-sign-in");
    var active = false, loading = false, busy = false, generation = 0, theme = "light";
    var pageSize = 4, offset = 0, total = 0, hasMore = false, autoPages = false;
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
    function controls() {
      get("tv-refresh").disabled = loading;
      get("damage-prev").disabled = loading || offset === 0;
      get("damage-next").disabled = loading || !hasMore;
      text("damage-page", "Page " + (Math.floor(offset / pageSize) + 1) + " of " + Math.max(1, Math.ceil(total / pageSize)));
    }
    function setAuto(value) {
      autoPages = !!value;
      get("tv-auto-toggle").setAttribute("aria-pressed", autoPages ? "true" : "false");
      text("tv-auto-toggle", autoPages ? "Auto pages: on \u00b7 15 sec" : "Auto pages: off");
    }
    function clear() {
      offset = 0; total = 0; hasMore = false; setAuto(false);
      text("damage-today", 0); text("damage-month", 0); text("damage-total", 0);
      get("damage-technicians").innerHTML = ""; get("damage-incidents").innerHTML = "";
      text("damage-range", "Waiting for records"); controls();
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
    function field(label, value, className) {
      return '<div class="damage-detail ' + (className || "") + '"><dt>' + label + '</dt><dd>' + escape(value || "Not recorded") + '</dd></div>';
    }
    function render(data) {
      var technicians = data.technicians || [], rows = data.rows || [], html = "", i, row;
      text("damage-today", count(data.today_count)); text("damage-month", count(data.month_count)); text("damage-total", total);
      for (i = 0; i < technicians.length; i++) {
        html += '<span class="damage-technician"><span>' + escape(technicians[i].damaged_by || "Not recorded") + '</span><strong>' + count(technicians[i].count) + '</strong></span>';
      }
      get("damage-technicians").innerHTML = html || '<p class="damage-empty-month">No manual damage incidents this month.</p>';
      html = "";
      for (i = 0; i < rows.length; i++) {
        row = rows[i];
        html += '<div class="damage-incident-cell"><article class="damage-incident" tabindex="0" aria-label="Incident ' + (offset + i + 1) + '">' +
          '<p class="damage-incident-date">' + escape(uaeDate(row.occurred_at)) + ' UAE</p>' +
          '<p class="damage-person-label">Damaged by</p><h3>' + escape(row.damaged_by || "Not recorded") + '</h3><dl>' +
          field("Model", row.model) + field("IMEI / Serial number", row.identifier, "damage-identifier") +
          field("Damage", row.damage) + field("Reason", row.reason) + '</dl>' +
          '<p class="damage-reporter"><span>Reported by</span> ' + escape(row.reported_by || "Not recorded") +
          '<small>Recorded ' + escape(uaeDate(row.created_at)) + ' UAE</small></p></article></div>';
      }
      get("damage-incidents").innerHTML = html || '<p class="tv-empty">No manual damage incidents have been reported. Use Manual Entry to record an incident.</p>';
      text("damage-range", rows.length ? (offset + 1) + "\u2013" + (offset + rows.length) + " of " + total + " incidents" : "0 incidents");
      controls();
    }
    function refresh(nextOffset) {
      if (!active || loading) return;
      var requested = typeof nextOffset === "number" ? Math.max(0, nextOffset) : offset;
      loading = true; controls();
      var ticket = generation;
      api.loadDamages(requested, pageSize, function (error, data) {
        if (ticket !== generation || !active) return;
        loading = false;
        if (error) {
          controls();
          if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); }
          else message("tv-board-message", (error.message || "The report could not be refreshed.") + " Last shown figures have not been updated. Select Refresh now to retry.");
          return;
        }
        total = count(data.total_count);
        // A page can disappear if records change while the report is open.
        if (requested > 0 && requested >= total) {
          refresh(total ? Math.floor((total - 1) / pageSize) * pageSize : 0);
          return;
        }
        var focused = document.activeElement, cardIndex = -1, cards = get("damage-incidents").getElementsByTagName("article"), i;
        for (i = 0; i < cards.length; i++) if (cards[i] === focused) cardIndex = i;
        offset = requested; hasMore = !!data.has_more;
        render(data); message("tv-board-message", ""); text("tv-last-updated", stamp());
        cards = get("damage-incidents").getElementsByTagName("article");
        if (cardIndex >= 0 && cards.length) cards[Math.min(cardIndex, cards.length - 1)].focus();
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
    if (!api || typeof api.loadDamages !== "function") {
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
