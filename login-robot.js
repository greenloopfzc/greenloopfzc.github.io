(() => {
  'use strict';
  const scene = document.getElementById('login-greeting');
  const sign = document.getElementById('login-robot-sign');
  if (!scene || !sign) return;

  // This flag changes only the greeting. Authentication remains in auth/config.
  // Consume it once so refresh and copied addresses show the ordinary welcome.
  let goodbye = false;
  try {
    const url = new URL(window.location.href);
    goodbye = url.searchParams.get('greeting') === 'bye';
    if (url.searchParams.has('greeting')) {
      url.searchParams.delete('greeting');
      window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash);
    }
  } catch (_) {}
  scene.dataset.greeting = goodbye ? 'bye' : 'hello';
  sign.textContent = goodbye ? 'Bye Bye' : 'Hiii';
  scene.classList.add('gl-greeting-ready');

  // A restored browser-history page is a new welcome, not a repeated logout.
  window.addEventListener('pageshow', event => {
    if (!event.persisted) return;
    scene.dataset.greeting = 'hello';
    sign.textContent = 'Hiii';
  });
})();
