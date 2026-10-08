(function () {
  "use strict";
  function start() {
    var api = window.GREENLOOP_TV_API;
    var renderer = window.GreenloopTVRender;
    function get(id) { return document.getElementById(id); }
    var login = get("tv-login"), board = get("tv-board"), form = get("tv-login-form");
    var username = get("tv-username"), password = get("tv-password"), submit = get("tv-sign-in");
    var active = false, loading = false, busy = false, generation = 0, theme = "light";
    function text(id, value) { get(id).textContent = value || ""; }
    function message(id, value) { text(id, value); get(id).style.display = value ? "block" : "none"; }
    function loginBusy(value) {
      busy = value;
      submit.disabled = value; username.disabled = value; password.disabled = value;
      get("tv-remember").disabled = value; get("tv-show-password").disabled = value;
      submit.textContent = value ? "Signing in..." : "Sign in to live board";
    }
    function showLogin(value) {
      active = false; loading = false; generation++;
      if (renderer) renderer.clear();
      board.style.display = "none"; login.style.display = "block";
      password.value = ""; password.type = "password";
      get("tv-show-password").textContent = "Show";
      get("tv-show-password").setAttribute("aria-label", "Show password");
      get("tv-show-password").setAttribute("aria-pressed", "false");
      loginBusy(false);
      message("tv-board-message", ""); text("tv-last-updated", "");
      message("tv-login-message", value);
    }
    function expired(error) {
      return error && (error.clearSession || /^(NO_SESSION|SESSION_EXPIRED|PERMISSION_DENIED)$/.test(error.code || ""));
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
    function refresh() {
      if (!active || loading) return;
      loading = true; get("tv-refresh").disabled = true;
      var ticket = generation;
      api.loadBoard(function (error, rows) {
        if (ticket !== generation || !active) return;
        loading = false; get("tv-refresh").disabled = false;
        if (error) {
          if (expired(error)) { showLogin(error.message || "Please sign in again."); username.focus(); }
          else message("tv-board-message", (error.message || "The board could not be refreshed.") + " Last shown figures have not been updated. Select Refresh to retry.");
          return;
        }
        renderer.render(rows);
        message("tv-board-message", ""); text("tv-last-updated", stamp());
      });
    }
    function openBoard() {
      active = true; loading = false;
      login.style.display = "none"; board.style.display = "block";
      message("tv-login-message", ""); message("tv-board-message", "Loading live board...");
      get("tv-refresh").disabled = false;
      renderer.setAuto(false);
      refresh();
      get("tv-full-view").focus();
    }
    function setTheme(value) {
      theme = value === "dark" ? "dark" : "light";
      renderer.setTheme(theme);
      get("tv-theme-toggle").textContent = theme === "dark" ? "Light mode" : "Dark mode";
      try { window.localStorage.setItem("greenloop-tv-theme", theme); } catch (ignore) {}
    }
    if (!api || !renderer) {
      message("tv-login-message", "This page did not finish loading. Reload the page and check the TV internet connection.");
      submit.disabled = true;
      return;
    }
    api.onSessionInvalidated = function (error) {
      showLogin(error && error.message || "Please sign in again.");
      username.focus();
    };
    try { theme = window.localStorage.getItem("greenloop-tv-theme") || "light"; } catch (ignore) {}
    setTheme(theme);
    get("tv-theme-toggle").onclick = function () { setTheme(theme === "light" ? "dark" : "light"); };
    get("tv-show-password").onclick = function () {
      var show = password.type === "password";
      password.type = show ? "text" : "password";
      this.textContent = show ? "Hide" : "Show";
      this.setAttribute("aria-label", show ? "Hide password" : "Show password");
      this.setAttribute("aria-pressed", show ? "true" : "false");
    };
    form.onsubmit = function (event) {
      if (event) event.preventDefault();
      if (busy) return false;
      var name = username.value.replace(/^\s+|\s+$/g, "");
      if (!name || !password.value) {
        message("tv-login-message", "Enter your username and password.");
        (name ? password : username).focus();
        return false;
      }
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
    get("tv-refresh").onclick = refresh;
    get("tv-auto-toggle").onclick = function () { renderer.setAuto(true); };
    get("tv-full-view").onclick = function () { renderer.setAuto(false); };
    get("tv-logout").onclick = function () {
      showLogin("Signed out.");
      api.logout(function () {});
      username.focus();
    };
    get("tv-fullscreen").onclick = function () {
      var root = document.documentElement;
      var full = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
      var action = full ? document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen
        : root.requestFullscreen || root.webkitRequestFullscreen || root.mozRequestFullScreen;
      if (!action) { message("tv-board-message", "Use the TV browser's full-screen option to hide its address bar."); return; }
      try {
        var result = action.call(full ? document : root);
        if (result && typeof result["catch"] === "function") result["catch"](function () { message("tv-board-message", "Use the TV browser's full-screen option to hide its address bar."); });
      } catch (ignore) { message("tv-board-message", "Use the TV browser's full-screen option to hide its address bar."); }
    };
    function fullChanged() {
      get("tv-fullscreen").textContent = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement ? "Exit full screen" : "Full screen";
    }
    document.addEventListener("fullscreenchange", fullChanged);
    document.addEventListener("webkitfullscreenchange", fullChanged);
    document.addEventListener("mozfullscreenchange", fullChanged);
    // Remotes send the same arrow keys as a keyboard. Keep left/right editing
    // native inside text fields; up/down can leave a field for the next control.
    document.addEventListener("keydown", function (event) {
      var key = event.keyCode || event.which;
      if (key < 37 || key > 40 || event.altKey || event.ctrlKey || event.metaKey) return;
      var current = document.activeElement;
      if (current && (current === username || current === password) && (key === 37 || key === 39)) return;
      var nodes = document.querySelectorAll("a[href],button,input,select,[tabindex='0']");
      var controls = [], i, index = -1;
      for (i = 0; i < nodes.length; i++) {
        if (!nodes[i].disabled && nodes[i].getClientRects().length) {
          if (nodes[i] === current) index = controls.length;
          controls.push(nodes[i]);
        }
      }
      if (!controls.length) return;
      var next = index < 0 ? 0 : (index + (key === 37 || key === 38 ? -1 : 1) + controls.length) % controls.length;
      event.preventDefault(); controls[next].focus();
    });
    window.setInterval(function () { if (!document.hidden) refresh(); }, 30000);
    document.addEventListener("visibilitychange", function () { if (!document.hidden) refresh(); });
    window.addEventListener("online", refresh);
    showLogin("");
    var restoreTicket = generation;
    api.restore(function (error, result) {
      if (restoreTicket !== generation) return;
      if (!error && result && result.authenticated) openBoard();
      else if (error && error.code !== "NO_SESSION") message("tv-login-message", error.message || "Please sign in again.");
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
}());
