// Compatibility entry used by the original flat GitHub Pages files.
// It exposes the Supabase settings immediately, then loads the current shared
// Greenloop configuration and page-permission guard from /js/config.js.
window.GREENLOOP_CONFIG = Object.freeze({
  supabaseUrl: "https://prypklagfznpdlleldll.supabase.co",
  supabaseAnonKey: "sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt"
});

(() => {
  if (window.__GREENLOOP_CURRENT_CONFIG_LOADING__) return;
  window.__GREENLOOP_CURRENT_CONFIG_LOADING__ = true;

  const script = document.createElement("script");
  script.src = "js/config.js?v=20260814-143817-2";
  script.async = false;
  script.dataset.greenloopCurrentConfig = "true";
  document.head.append(script);
})();
