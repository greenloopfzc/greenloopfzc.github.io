/* Greenloop workshop TV renderer, 20261003-tv-browser-1. ES5 syntax throughout. */
(function (window, document) {
  "use strict";

  var boardRows = [];
  var autoView = false;
  var activeTechnicianId = null;
  var rotationTimer = null;

  function byId(id) { return document.getElementById(id); }
  function text(id, value) { var element = byId(id); if (element) element.textContent = String(value); }
  function escapeHtml(value) {
    return String(value === null || value === undefined ? "" : value).replace(/[&<>"']/g, function (character) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character];
    });
  }
  function initials(name) {
    var words = String(name || "T").replace(/^\s+|\s+$/g, "").split(/\s+/);
    return ((words[0] ? words[0].charAt(0) : "T") + (words[1] ? words[1].charAt(0) : "")).toUpperCase();
  }
  function count(value) { return Number(value) || 0; }
  function pendingAge(hours) {
    var total, days, remaining;
    if (hours === null || hours === undefined || !isFinite(Number(hours)) || Number(hours) < 0) return "Age unavailable";
    total = Math.floor(Number(hours));
    if (!total) return "Less than 1 hour";
    days = Math.floor(total / 24);
    remaining = total % 24;
    return days ? days + " day" + (days === 1 ? "" : "s") + (remaining ? " " + remaining + "h" : "") : remaining + "h";
  }

  // Matches lab-live-board.js: 80 monthly repair/quality points and 20 current-queue points.
  function performance(row) {
    var keys = ["completed_month", "damage_month", "qc_returns_month", "pending_count", "overdue_count"];
    var values = [], i, value, completed, damages, returns, pending, overdue, quality, timely;
    for (i = 0; i < keys.length; i += 1) {
      value = row[keys[i]];
      if (value === null || value === undefined || !isFinite(Number(value)) || Number(value) < 0) return null;
      values.push(Number(value));
    }
    completed = values[0]; damages = values[1]; returns = values[2]; pending = values[3]; overdue = values[4];
    if (!completed && !damages && !returns) return null;
    if (!completed) return 0;
    quality = completed / (completed + 2 * returns + 3 * damages);
    timely = pending ? Math.max(0, 1 - overdue / pending) : 1;
    return Math.round(80 * quality + 20 * timely);
  }
  function deviceLabel(row) {
    if (!row.latest_imei) return "No phone currently assigned";
    return "<strong>" + escapeHtml(row.latest_imei) + "</strong> &middot; " + escapeHtml([
      row.latest_model || "Model -", row.latest_gb ? row.latest_gb + " GB" : "GB -", row.latest_color || "Color -"
    ].join(" - "));
  }
  function stat(label, value) { return "<div><span>" + label + "</span><strong>" + escapeHtml(value) + "</strong></div>"; }
  function card(row) {
    var pending = count(row.pending_count), working = count(row.working_count), overdue = count(row.overdue_count);
    var state = working ? "Working now" : pending ? "Pending work" : "Clear";
    var className = overdue ? "is-overdue" : working ? "is-busy" : pending ? "" : "is-clear";
    var score = performance(row), scoreLabel = score === null ? "N/A" : score + "%";
    var alert = overdue ? '<div class="tv-technician-alert"><strong>Oldest pending: ' + escapeHtml(pendingAge(row.oldest_pending_hours)) + '</strong><span>' + escapeHtml(row.oldest_imei || "Oldest pending phone") + " &middot; " + escapeHtml(overdue) + " overdue phone" + (overdue === 1 ? "" : "s") + "</span></div>" : "";
    var scoreBar = score === null ? "" : '<div class="tv-score-track" role="meter" aria-label="Performance" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + score + '"><span style="width:' + score + '%"></span></div>';
    return '<div class="tv-technician-cell"><article class="tv-technician-card tv-clear ' + className + '">' +
      '<div class="tv-technician-head tv-clear"><span class="tv-avatar" aria-hidden="true">' + escapeHtml(initials(row.technician_name)) + '</span><span class="tv-technician-identity"><strong>' + escapeHtml(row.technician_name) + '</strong><small>Lab &amp; Glass technician</small></span><span class="tv-technician-state">' + state + '</span></div>' +
      '<div class="tv-performance"><span class="tv-performance-label">Performance</span><strong>' + scoreLabel + '</strong><p>' + (score === null ? "Not enough monthly records to score" : "Monthly repairs &amp; quality + current pending queue") + '</p>' + scoreBar + '</div>' + alert +
      '<div class="tv-work-counts">' + stat("Pending phones", pending) + stat("Working now", working) + '</div>' +
      '<div class="tv-stats">' + stat("Awaiting Final QC", count(row.final_qc_handoff_count)) + stat("Completed today", count(row.completed_today)) + stat("Completed month", count(row.completed_month)) + '</div>' +
      '<div class="tv-quality">' + stat("Damages month", count(row.damage_month)) + stat("QC returns month", count(row.qc_returns_month)) + stat("Career completed", count(row.completed_total)) + '</div>' +
      '<div class="tv-technician-device">' + deviceLabel(row) + '</div></article></div>';
  }
  function activeIndex() {
    var i;
    for (i = 0; i < boardRows.length; i += 1) if (boardRows[i].technician_id === activeTechnicianId) return i;
    return 0;
  }
  function updateView() {
    var board = byId("tv-board"), grid = byId("tv-technicians"), cards, index = activeIndex(), i;
    if (!board || !grid) return;
    activeTechnicianId = boardRows.length ? boardRows[index].technician_id : null;
    cards = grid.querySelectorAll(".tv-technician-cell");
    for (i = 0; i < cards.length; i += 1) cards[i].style.display = autoView && i !== index ? "none" : "";
    board.className = "tv-board" + (autoView ? " tv-auto" : "");
    if (byId("tv-full-view")) byId("tv-full-view").setAttribute("aria-pressed", autoView ? "false" : "true");
    if (byId("tv-auto-toggle")) byId("tv-auto-toggle").setAttribute("aria-pressed", autoView ? "true" : "false");
    text("tv-board-count", autoView && boardRows.length ? (index + 1) + " / " + boardRows.length + " technicians \u00b7 Every 5 sec \u00b7 Loop" : boardRows.length + " technician" + (boardRows.length === 1 ? "" : "s"));
  }
  function setAuto(value) {
    autoView = Boolean(value);
    if (rotationTimer !== null) window.clearInterval(rotationTimer);
    rotationTimer = null;
    updateView();
    if (autoView) rotationTimer = window.setInterval(function () {
      if (document.hidden || boardRows.length < 2) return;
      activeTechnicianId = boardRows[(activeIndex() + 1) % boardRows.length].technician_id;
      updateView();
    }, 5000);
  }
  function render(rows) {
    var grid = byId("tv-technicians"), html = [], i;
    var totals = { pending: 0, working: 0, completed: 0, overdue: 0, month: 0 };
    boardRows = Object.prototype.toString.call(rows) === "[object Array]" ? rows : [];
    for (i = 0; i < boardRows.length; i += 1) {
      totals.pending += count(boardRows[i].pending_count);
      totals.working += count(boardRows[i].working_count);
      totals.completed += count(boardRows[i].completed_today);
      totals.overdue += count(boardRows[i].overdue_count);
      totals.month += count(boardRows[i].completed_month);
      html.push(card(boardRows[i]));
    }
    text("tv-summary-technicians", boardRows.length);
    text("tv-summary-pending", totals.pending);
    text("tv-summary-working", totals.working);
    text("tv-summary-completed", totals.completed);
    text("tv-summary-overdue", totals.overdue);
    text("tv-summary-month", totals.month);
    if (grid) grid.innerHTML = html.length ? html.join("") : '<p class="tv-empty">No active Lab &amp; Glass technicians are available.</p>';
    updateView();
  }
  function clear() {
    setAuto(false);
    activeTechnicianId = null;
    render([]);
  }
  function setTheme(mode) {
    var dark = mode === "dark", root = document.documentElement;
    root.className = root.className.replace(/(?:^|\s)tv-dark(?=\s|$)/g, "").replace(/^\s+|\s+$/g, "");
    if (dark) root.className += (root.className ? " " : "") + "tv-dark";
    if (byId("tv-theme-toggle")) {
      byId("tv-theme-toggle").setAttribute("aria-pressed", dark ? "true" : "false");
      text("tv-theme-toggle", dark ? "Light mode" : "Dark mode");
    }
  }
  function mountHelp() {
    var button = byId("tv-score-help-toggle"), content = byId("tv-score-help-content");
    if (!button || !content) return;
    button.addEventListener("click", function () {
      var open = button.getAttribute("aria-expanded") === "true";
      button.setAttribute("aria-expanded", open ? "false" : "true");
      content.style.display = open ? "none" : "block";
    });
  }
  window.GreenloopTVRender = {
    render: render,
    setAuto: setAuto,
    isAuto: function () { return autoView; },
    clear: clear,
    performance: performance,
    setTheme: setTheme
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mountHelp); else mountHelp();
}(window, document));
