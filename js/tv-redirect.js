(function () {
  "use strict";
  // This entry point must parse before the normal application's modern scripts.
  var choice = /(?:\?|&)tv=([^&]*)/.exec(window.location.search);
  if (choice && choice[1] === "0") return;
  var agent = window.navigator.userAgent || "";
  var television = /SMART[- ]?TV|SmartTV|Tizen|Web0S|webOS|NetCast|HbbTV|Viera|BRAVIA|GoogleTV|Android TV|AFT[A-Z0-9]|Philips[ _]TV|Hisense|VIDAA/i.test(agent);
  var modernLayout = window.CSS && typeof window.CSS.supports === "function" && window.CSS.supports("display", "grid") && window.CSS.supports("width", "min(100%, 430px)");
  var modernRuntime = window.Promise && window.fetch && window.Map && Object.assign && String.prototype.replaceAll;
  if (television || choice && choice[1] === "1" || !modernLayout || !modernRuntime) {
    var page = (window.location.pathname || "").split("/").pop();
    window.location.replace(page === "lab-live-board.html" ? "live-tv.html" : "tv.html");
  }
}());
