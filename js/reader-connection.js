(() => {
  'use strict';
  const ports = [51892, 51893];
  let selected = '', pending = null;
  async function discover() {
    if (selected) return selected;
    if (pending) return pending;
    pending = (async () => {
      for (const port of ports) {
        const base = `http://127.0.0.1:${port}`;
        try {
          const response = await fetch(base + '/health', { cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(1200) });
          const health = await response.json();
          if (response.ok && health.ok === true && health.service === 'Greenloop Read-Only Device Reader' && health.mode === 'read-only') {
            selected = base;
            return base;
          }
        } catch (_) { /* Try the next fixed loopback port. */ }
      }
      throw new Error('Greenloop Cable Reader is not responding on its supported local ports.');
    })();
    try { return await pending; } finally { pending = null; }
  }
  async function request(path, options = {}) {
    if (!/^\/(?:health|v1\/device|v1\/details(?:\/probe|\/advanced)?)(?:\?refresh=1)?$/.test(path)) throw new Error('Unsupported reader path.');
    const base = await discover();
    try {
      return await fetch(base + path, { ...options, method: 'GET', credentials: 'omit', redirect: 'error', cache: 'no-store' });
    } catch (error) {
      if (selected === base) selected = '';
      throw error;
    }
  }
  window.GREENLOOP_READER_CONNECTION = Object.freeze({ fetch: request });
})();
