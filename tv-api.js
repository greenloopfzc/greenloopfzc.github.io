/* TV authentication and read-only board transport. ES5, no external runtime. */
(function (window) {
  "use strict";
  var config = window.GREENLOOP_TV_CONFIG || {};
  var base = String(config.supabaseUrl || "").replace(/\/$/, "");
  var key = String(config.supabaseAnonKey || "");
  var storageKey = "greenloop-tv-session-v1";
  var lockKey = storageKey + "-refresh";
  var owner = String(new Date().getTime()) + "-" + String(Math.random()).slice(2);
  var session = null, persistent = false, generation = 0;
  var refreshing = false, refreshWaiters = [], refreshTimer = null;
  var api = {};

  function now() { return Math.floor(new Date().getTime() / 1000); }
  function noop() {}
  function error(code, message, clearSession) {
    return { code: code, message: message, clearSession: !!clearSession };
  }
  function storage(kind) {
    try { return window[kind]; } catch (ignored) { return null; }
  }
  function read(kind, name) {
    try { var store = storage(kind); return store ? store.getItem(name) : null; } catch (ignored) { return null; }
  }
  function remove(kind, name) {
    try { var store = storage(kind); if (store) store.removeItem(name); } catch (ignored) {}
  }
  function write(kind, name, value) {
    try { var store = storage(kind); if (!store) return false; store.setItem(name, value); return true; } catch (ignored) { return false; }
  }
  function parse(text) {
    try { return JSON.parse(text); } catch (ignored) { return null; }
  }
  function validSession(value) {
    return value && typeof value.access_token === "string" && value.access_token.length > 0 &&
      typeof value.refresh_token === "string" && value.refresh_token.length > 0 &&
      typeof value.expires_at === "number" && isFinite(value.expires_at) && value.expires_at > 0 &&
      value.user && typeof value.user.id === "string" && value.user.id.length > 0;
  }
  function stored(kind) {
    var value = parse(read(kind, storageKey));
    return value && value.project === base && validSession(value.session) ? value.session : null;
  }
  function persist() {
    if (!session) return;
    var kind = persistent ? "localStorage" : "sessionStorage";
    var other = persistent ? "sessionStorage" : "localStorage";
    remove(other, storageKey);
    if (!write(kind, storageKey, JSON.stringify({ project: base, session: session }))) {
      // A browser with blocked storage can still sign in for this open page.
      remove(kind, storageKey);
    }
  }
  function releaseLock() {
    var lease = parse(read("localStorage", lockKey));
    if (lease && lease.owner === owner) remove("localStorage", lockKey);
  }
  function clear(reason, notify, keepStorage) {
    generation += 1;
    session = null;
    refreshing = false;
    refreshWaiters = [];
    if (refreshTimer !== null) window.clearTimeout(refreshTimer);
    refreshTimer = null;
    releaseLock();
    if (!keepStorage) {
      remove("localStorage", storageKey);
      remove("sessionStorage", storageKey);
    }
    if (notify && typeof api.onSessionInvalidated === "function") api.onSessionInvalidated(reason);
  }
  function failSession(code, message, callback) {
    var problem = error(code, message, true);
    clear(problem, true);
    callback(problem);
  }
  function request(method, path, payload, token, callback, independent) {
    var stamp = generation, xhr, settled = false, timer;
    function finish(problem, data) {
      if (settled) return;
      settled = true;
      if (timer) window.clearTimeout(timer);
      if (!independent && stamp !== generation) return;
      callback(problem, data);
    }
    if (!/^https:\/\/[^\/]+/.test(base) || !key) {
      callback(error("CONFIGURATION", "The TV connection is not configured. Please contact your administrator."));
      return;
    }
    try {
      xhr = new window.XMLHttpRequest();
      xhr.open(method, base + path, true);
      xhr.setRequestHeader("apikey", key);
      if (token) xhr.setRequestHeader("Authorization", "Bearer " + token);
      if (payload !== null) xhr.setRequestHeader("Content-Type", "application/json");
      xhr.onreadystatechange = function () {
        if (xhr.readyState !== 4) return;
        var status = xhr.status === 1223 ? 204 : xhr.status;
        if (!status) { finish(error("NETWORK", "Cannot reach Greenloop. Check the TV internet connection and try again.")); return; }
        var value = xhr.responseText ? parse(xhr.responseText) : null;
        if (status < 200 || status >= 300) {
          var problem = error(status === 429 ? "RATE_LIMIT" : "HTTP", status === 429 ? "Too many sign-in attempts. Please wait and try again." : "Greenloop could not complete this request. Please try again.");
          problem.status = status;
          problem.serverCode = value && typeof value.code === "string" ? value.code : "";
          finish(problem);
          return;
        }
        if (status !== 204 && value === null) { finish(error("INVALID_RESPONSE", "Greenloop returned an unreadable response. Please try again.")); return; }
        finish(null, value);
      };
      xhr.onerror = function () { finish(error("NETWORK", "Cannot reach Greenloop. Check the TV internet connection and try again.")); };
      xhr.ontimeout = function () { finish(error("NETWORK", "Greenloop took too long to respond. Please try again.")); };
      timer = window.setTimeout(function () {
        finish(error("NETWORK", "Greenloop took too long to respond. Please try again."));
        try { xhr.abort(); } catch (ignored) {}
      }, 15000);
      xhr.send(payload === null ? null : JSON.stringify(payload));
    } catch (ignored) { finish(error("NETWORK", "This browser could not connect securely to Greenloop. Please try another browser or an HDMI connection.")); }
  }
  function normaliseSession(reply) {
    if (!reply || !reply.user || typeof reply.user.id !== "string") return null;
    var meta = reply.user.user_metadata || {};
    var expiry = typeof reply.expires_at === "number" ? reply.expires_at : now() + Number(reply.expires_in);
    var result = {
      access_token: reply.access_token,
      refresh_token: reply.refresh_token,
      expires_at: expiry,
      user: { id: reply.user.id, displayName: typeof meta.full_name === "string" ? meta.full_name : "Greenloop user" }
    };
    return validSession(result) ? result : null;
  }
  function finishRefresh(problem) {
    var callbacks = refreshWaiters.slice(0), index;
    refreshWaiters = [];
    refreshing = false;
    releaseLock();
    if (problem && problem.clearSession) clear(problem, true);
    for (index = 0; index < callbacks.length; index += 1) callbacks[index](problem);
  }
  function refresh(callback) {
    if (!session) { callback(error("NO_SESSION", "Please sign in to open the Damage Report.", true)); return; }
    refreshWaiters.push(callback);
    if (refreshing) return;
    refreshing = true;
    var stamp = generation, startingToken = session.access_token;
    function acquireAndRefresh() {
      if (stamp !== generation || !session) return;
      refreshTimer = null;
      // Remembered sessions may be open in two TV tabs: reuse the other tab's
      // rotated token, or wait for its short lease before refreshing ourselves.
      if (persistent) {
        var latest = stored("localStorage");
        if (latest && latest.user.id === session.user.id && latest.access_token !== startingToken) {
          session = latest;
          finishRefresh(null);
          return;
        }
        var lease = parse(read("localStorage", lockKey));
        if (lease && lease.owner !== owner && lease.until > now() && lease.until <= now() + 20) {
          refreshTimer = window.setTimeout(acquireAndRefresh, 250);
          return;
        }
        write("localStorage", lockKey, JSON.stringify({ owner: owner, until: now() + 20 }));
        lease = parse(read("localStorage", lockKey));
        if (lease && lease.owner !== owner) {
          refreshTimer = window.setTimeout(acquireAndRefresh, 250);
          return;
        }
      }
      request("POST", "/auth/v1/token?grant_type=refresh_token", { refresh_token: session.refresh_token }, null, function (problem, reply) {
        if (problem) {
          if (problem.status === 400 || problem.status === 401 || problem.status === 403 || problem.code === "INVALID_RESPONSE") {
            finishRefresh(error("SESSION_EXPIRED", "Your TV session has expired. Please sign in again.", true));
          } else finishRefresh(problem);
          return;
        }
        var renewed = normaliseSession(reply);
        if (!renewed || renewed.user.id !== session.user.id) { finishRefresh(error("SESSION_EXPIRED", "Your TV session could not be verified. Please sign in again.", true)); return; }
        session = renewed;
        persist();
        finishRefresh(null);
      });
    }
    acquireAndRefresh();
  }
  function ensureSession(callback) {
    if (!session) { callback(error("NO_SESSION", "Please sign in to open the Damage Report.", true)); return; }
    if (session.expires_at <= now() + 60) refresh(callback);
    else callback(null);
  }
  function authorised(method, path, payload, callback) {
    ensureSession(function (problem) {
      if (problem) { callback(problem); return; }
      function send(retried) {
        if (!session) { callback(error("NO_SESSION", "Please sign in again.", true)); return; }
        var usedToken = session.access_token;
        request(method, path, payload, usedToken, function (requestError, reply) {
          if (requestError && requestError.status === 401) {
            if (retried) { failSession("SESSION_EXPIRED", "Your TV session has expired. Please sign in again.", callback); return; }
            if (session && session.access_token !== usedToken) send(true);
            else refresh(function (refreshError) { if (refreshError) callback(refreshError); else send(true); });
            return;
          }
          if (requestError && (requestError.status === 403 || requestError.serverCode === "42501")) {
            failSession("PERMISSION_DENIED", "Your account does not have permission to open this report. Ask an administrator to check User Access.", callback);
            return;
          }
          callback(requestError, reply);
        });
      }
      send(false);
    });
  }
  function checkAccess(callback, pageKey) {
    pageKey = pageKey || "damage_report";
    authorised("POST", "/rest/v1/rpc/get_my_page_access_v2", {}, function (problem, rows) {
      if (problem) {
        if (problem.code === "INVALID_RESPONSE") { failSession("INVALID_RESPONSE", "Page permissions could not be verified. Please sign in again.", callback); return; }
        callback(problem);
        return;
      }
      var index, allowed = false;
      if (Object.prototype.toString.call(rows) !== "[object Array]") { failSession("INVALID_RESPONSE", "Page permissions could not be verified. Please sign in again.", callback); return; }
      for (index = 0; index < rows.length; index += 1) {
        if (!rows[index] || typeof rows[index].page_key !== "string" || !/^(view|edit|none)$/.test(rows[index].access_level)) {
          failSession("INVALID_RESPONSE", "Page permissions could not be verified. Please sign in again.", callback);
          return;
        }
        if (rows[index].page_key === pageKey && /^(view|edit)$/.test(rows[index].access_level)) allowed = true;
      }
      if (!allowed) { failSession("PERMISSION_DENIED", "Your account does not have permission to open this report. Ask an administrator to check User Access.", callback); return; }
      callback(null);
    });
  }
  function signedIn(callback) {
    checkAccess(function (problem) {
      if (problem) { callback(problem); return; }
      persist();
      callback(null, { authenticated: true, user: { id: session.user.id, displayName: session.user.displayName } });
    });
  }
  api.login = function (username, password, remember, callback) {
    callback = typeof callback === "function" ? callback : noop;
    username = String(username || "").replace(/^\s+|\s+$/g, "");
    if (!username || typeof password !== "string" || !password) { callback(error("VALIDATION", "Enter your username and password.")); return; }
    clear(null, false);
    persistent = !!remember;
    request("POST", "/rest/v1/rpc/resolve_login_username", { p_username: username }, null, function (problem, reply) {
      if (problem) { callback(problem); return; }
      var record = Object.prototype.toString.call(reply) === "[object Array]" ? (reply.length === 1 ? reply[0] : null) : reply;
      if (!record || typeof record.email !== "string" || !record.email) { callback(error("INVALID_CREDENTIALS", "Username or password is incorrect.")); return; }
      request("POST", "/auth/v1/token?grant_type=password", { email: record.email, password: password }, null, function (authError, response) {
        password = "";
        if (authError) {
          callback(authError.status === 400 || authError.status === 401 ? error("INVALID_CREDENTIALS", "Username or password is incorrect.") : authError);
          return;
        }
        session = normaliseSession(response);
        if (!session) { callback(error("INVALID_RESPONSE", "Sign-in could not be verified. Please try again.", true)); return; }
        signedIn(callback);
      });
      password = "";
    });
  };
  api.restore = function (callback) {
    callback = typeof callback === "function" ? callback : noop;
    var temporary = stored("sessionStorage"), remembered = stored("localStorage");
    session = temporary || remembered;
    persistent = !temporary && !!remembered;
    if (!session) { callback(error("NO_SESSION", "Sign in with your Greenloop account.", true)); return; }
    authorised("GET", "/auth/v1/user", null, function (problem, user) {
      if (problem) { callback(problem); return; }
      if (!user || user.id !== session.user.id) { failSession("SESSION_EXPIRED", "Your TV session could not be verified. Please sign in again.", callback); return; }
      signedIn(callback);
    });
  };
  api.loadBoard = function (callback) {
    callback = typeof callback === "function" ? callback : noop;
    checkAccess(function (problem) {
      if (problem) { callback(problem); return; }
      authorised("POST", "/rest/v1/rpc/get_lab_live_board", {}, function (boardError, rows) {
        if (boardError) { callback(boardError); return; }
        if (Object.prototype.toString.call(rows) !== "[object Array]") { callback(error("INVALID_RESPONSE", "The Live Board response could not be read. Please refresh.")); return; }
        for (var index = 0; index < rows.length; index += 1) {
          if (!rows[index] || typeof rows[index] !== "object" || typeof rows[index].technician_id !== "string" || typeof rows[index].technician_name !== "string") {
            callback(error("INVALID_RESPONSE", "The Live Board response could not be read. Please refresh."));
            return;
          }
        }
        callback(null, rows);
      });
    }, "lab_live_board");
  };
  api.logout = function (callback) {
    var oldToken = session && session.access_token;
    clear(error("NO_SESSION", "You have signed out.", true), true);
    if (typeof callback === "function") callback(null, { authenticated: false });
    if (oldToken) request("POST", "/auth/v1/logout?scope=local", {}, oldToken, noop, true);
  };
  function array(value) { return Object.prototype.toString.call(value) === "[object Array]"; }
  function count(value) { return typeof value === "number" && isFinite(value) && value >= 0 && value % 1 === 0; }
  function timestamp(value) {
    // PostgreSQL includes microseconds; older TV Date.parse implementations
    // reject them. Check ISO calendar fields without relying on that parser.
    if (typeof value !== "string") return false;
    var p = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)$/.exec(value);
    if (!p || Number(p[4]) > 23 || Number(p[5]) > 59 || Number(p[6]) > 59) return false;
    var date = new Date(0), zone = p[7].slice(1).replace(":", "");
    date.setUTCFullYear(Number(p[1]), Number(p[2]) - 1, Number(p[3]));
    return date.getUTCFullYear() === Number(p[1]) && date.getUTCMonth() + 1 === Number(p[2]) && date.getUTCDate() === Number(p[3]) &&
      (p[7] === "Z" || Number(zone.slice(0, 2)) <= 23 && Number(zone.slice(2) || 0) <= 59);
  }
  api.loadDamages = function (offset, limit, callback) {
    callback = typeof callback === "function" ? callback : noop;
    if (typeof offset !== "number" || offset < 0 || offset > 1000000 || offset % 1 || typeof limit !== "number" || limit < 1 || limit > 100 || limit % 1) {
      callback(error("VALIDATION", "Choose a valid damage report page."));
      return;
    }
    checkAccess(function (problem) {
      if (problem) { callback(problem); return; }
      authorised("POST", "/rest/v1/rpc/get_manual_damage_report_v1", { p_offset: offset, p_limit: limit }, function (reportError, report) {
        if (reportError) {
          if (reportError.status === 404 && reportError.serverCode === "PGRST202") {
            reportError.message = "The Damage Report database update is not installed yet. Ask your administrator to finish the update.";
          }
          callback(reportError);
          return;
        }
        var valid = report && count(report.today_count) && count(report.month_count) && count(report.total_count) &&
          array(report.rows) && report.rows.length <= limit && array(report.technicians) && typeof report.has_more === "boolean";
        var index, row;
        if (valid) for (index = 0; index < report.rows.length; index += 1) {
          row = report.rows[index];
          if (!row || typeof row.id !== "string" || typeof row.damaged_by !== "string" || typeof row.model !== "string" ||
            (row.identifier !== null && typeof row.identifier !== "string") || typeof row.damage !== "string" || typeof row.reason !== "string" ||
            typeof row.reported_by !== "string" || !timestamp(row.occurred_at) || !timestamp(row.created_at)) { valid = false; break; }
        }
        if (valid) for (index = 0; index < report.technicians.length; index += 1) {
          row = report.technicians[index];
          if (!row || typeof row.damaged_by !== "string" || !count(row.count)) { valid = false; break; }
        }
        if (!valid) { callback(error("INVALID_RESPONSE", "The Damage Report response could not be read. Select Refresh to retry.")); return; }
        callback(null, report);
      });
    }, "tv_manual_entry");
  };
  function pageArguments(offset, limit) {
    return count(offset) && offset <= 1000000 && count(limit) && limit >= 1 && limit <= 100;
  }
  function damageRows(rows, limit) {
    if (!array(rows) || rows.length > limit) return false;
    var index, row, seen = {};
    for (index = 0; index < rows.length; index += 1) {
      row = rows[index];
      if (!row || typeof row.id !== "string" || !row.id || seen["id:" + row.id] ||
        typeof row.model !== "string" || typeof row.reason !== "string" || typeof row.reported_by !== "string" ||
        (row.part_name !== null && typeof row.part_name !== "string") ||
        (row.identifier !== null && typeof row.identifier !== "string") ||
        !timestamp(row.occurred_at) || !timestamp(row.created_at)) return false;
      seen["id:" + row.id] = true;
    }
    return true;
  }
  function damageCardsRequest(name, args, callback) {
    checkAccess(function (problem) {
      if (problem) { callback(problem); return; }
      authorised("POST", "/rest/v1/rpc/" + name, args, function (reportError, report) {
        if (reportError && reportError.status === 404 && reportError.serverCode === "PGRST202") {
          reportError.message = "The Damage Cards database update is not installed yet. Ask your administrator to finish the update.";
        }
        if (reportError && name === "get_manual_damage_employee_rows_v1" && reportError.serverCode === "22023") {
          reportError = error("EMPLOYEE_NOT_FOUND", "This employee is no longer on the Damage Report. Refresh the employee cards.");
        }
        callback(reportError, report);
      });
    });
  }
  api.loadDamageCards = function (offset, limit, rowLimit, callback) {
    callback = typeof callback === "function" ? callback : noop;
    if (!pageArguments(offset, limit) || !pageArguments(0, rowLimit)) {
      callback(error("VALIDATION", "Choose a valid employee card page."));
      return;
    }
    damageCardsRequest("get_manual_damage_cards_v1", { p_offset: offset, p_limit: limit, p_row_limit: rowLimit }, function (problem, report) {
      if (problem) { callback(problem); return; }
      var valid = report && count(report.employee_count) && count(report.today_count) && count(report.month_count) && count(report.total_count) &&
        report.today_count <= report.month_count && report.month_count <= report.total_count &&
        array(report.activity) && report.activity.length <= 5 && array(report.employees) && report.employees.length <= limit && report.employees.length <= report.employee_count && typeof report.has_more === "boolean";
      var index, employee, seen = {};
      if (valid) for (index = 0; index < report.employees.length; index += 1) {
        employee = report.employees[index];
        if (!employee || typeof employee.id !== "string" || !employee.id || seen["id:" + employee.id] || typeof employee.name !== "string" || !employee.name ||
          !count(employee.total_damage) || !damageRows(employee.rows, rowLimit) || employee.rows.length > employee.total_damage || typeof employee.has_more !== "boolean") {
          valid = false; break;
        }
        seen["id:" + employee.id] = true;
      }
      if (valid) for (index = 0; index < report.activity.length; index += 1) {
        var entry = report.activity[index];
        if (!entry || typeof entry.id !== "string" || !entry.id || typeof entry.damaged_by !== "string" ||
          typeof entry.model !== "string" || typeof entry.reason !== "string" ||
          (entry.part_name !== null && typeof entry.part_name !== "string") ||
          !timestamp(entry.created_at) || !timestamp(entry.occurred_at)) { valid = false; break; }
      }
      if (!valid) { callback(error("INVALID_RESPONSE", "The employee cards could not be read. Select Refresh to retry.")); return; }
      callback(null, report);
    });
  };
  api.loadEmployeeDamageRows = function (employeeId, offset, limit, callback) {
    callback = typeof callback === "function" ? callback : noop;
    if (typeof employeeId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(employeeId) || !pageArguments(offset, limit)) {
      callback(error("VALIDATION", "Choose a valid employee history page."));
      return;
    }
    employeeId = employeeId.toLowerCase();
    damageCardsRequest("get_manual_damage_employee_rows_v1", { p_employee_id: employeeId, p_offset: offset, p_limit: limit }, function (problem, report) {
      if (problem) { callback(problem); return; }
      if (!report || report.employee_id !== employeeId || !count(report.total_damage) || !damageRows(report.rows, limit) ||
        report.rows.length > report.total_damage || typeof report.has_more !== "boolean") {
        callback(error("INVALID_RESPONSE", "This employee's damage history could not be read. Select Refresh to retry."));
        return;
      }
      callback(null, report);
    });
  };
  api.onSessionInvalidated = null;
  if (window.addEventListener) window.addEventListener("storage", function (event) {
    if (!persistent || !session || (event.key !== storageKey && event.key !== null)) return;
    if (event.storageArea && event.storageArea !== storage("localStorage")) return;
    var latest = stored("localStorage");
    if (!latest || latest.user.id !== session.user.id) {
      clear(error("NO_SESSION", "The TV session changed in another tab. Please sign in again.", true), true, true);
      return;
    }
    session = latest;
  }, false);
  window.GREENLOOP_TV_API = api;
}(window));
