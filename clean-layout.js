/* Progressive layout only: move existing controls, never clone forms or change grants. */
(() => {
  'use strict';
  if (!document.body.classList.contains('app-page') || window.GREENLOOP_CLEAN_LAYOUT) return;
  document.body.classList.add('gl-clean-layout');
  const node = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };
  const hidden = (element, value) => { if (element && element.hidden !== value) element.hidden = value; };
  const chipKeys = new WeakMap();
  const formatDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value || '')
    ? new Date(value + 'T12:00:00Z').toLocaleDateString('en-GB', {day:'2-digit', month:'short', year:'numeric', timeZone:'UTC'}) : value;
  function external(api, items) {
    if (!api?.externalFilters) return;
    const key = JSON.stringify(items.map(item => [item.label, item.value]));
    if (chipKeys.get(api) === key) return;
    chipKeys.set(api, key);
    api.externalFilters(items);
  }
  function dates(from, to, clear) {
    const values = [from?.value, to?.value];
    return values.some(Boolean) ? [{label:'Dates', value:values.map(value => formatDate(value) || 'Any').join(' – '), ...(clear ? {clear} : {})}] : [];
  }
  function adopt(api, element) {
    if (!api?.panel || !element || element.parentElement === api.panel) return;
    element.classList.add('gl-native-filter-content');
    api.adopt(element);
  }
  // Reuse the report's existing date form across its selected report. Some reports
  // have no local facets, in which case the same compact date-only toolbar is used.
  let previousReportApi;
  function reports() {
    const form = document.getElementById('report-filter');
    const host = document.querySelector('.report-panel');
    const filters = window.GREENLOOP_FILTERS;
    if (!form || !host || !filters?.find) return;
    const fallback = filters.find('report-date-filters');
    if (form.hidden) { hidden(fallback?.bar, true); return; }
    let bar = [...host.querySelectorAll('.table-filters')].find(element => !element.hidden && element.id !== 'report-date-filters');
    let api = bar && filters.find(bar.id);
    if (!api) {
      api = fallback || filters.get('report-date-filters', {before:document.getElementById('report-content'), search:false, fields:[], label:'Report date filters'});
      hidden(api.bar, false);
    } else hidden(fallback?.bar, true);
    if (previousReportApi && previousReportApi !== api) external(previousReportApi, []);
    previousReportApi = api;
    adopt(api, form);
    const chips = dates(document.getElementById('date-from'), document.getElementById('date-to'));
    // The Supplier Progress select is rendered anew with its report. Its change
    // handler is delegated to reports-app so moving the existing label is safe.
    const supplier = document.querySelector('#report-content #supplier-progress-filter');
    if (supplier && api.bar.id === 'report-supplier-progress') {
      api.panel.querySelectorAll('[data-clean-supplier-filter]').forEach(element => element.remove());
      for (const id of ['supplier-progress-filter','supplier-progress-batch']) {
        const select=document.getElementById(id);const label=select?.closest('label');
        if(label){label.dataset.cleanSupplierFilter='';adopt(api,label);}
      }
      chipKeys.delete(api);
    }
    for (const [id,label] of [['supplier-progress-filter','Supplier'],['supplier-progress-batch','Stock / Batch']]) {
      const select=api.panel.querySelector('#'+id);
      if(select?.value && select.value!=='all')chips.push({label,value:select.selectedOptions[0]?.textContent||select.value,clear:()=>{select.value='all';select.dispatchEvent(new Event('change',{bubbles:true}));}});
    }
    external(api, chips);
  }
  function journey() {
    const api = window.GREENLOOP_FILTERS?.find?.('journey-record-filters');
    if (!api?.toolbar || !api.panel) return;
    const form = document.getElementById('journey-search-form');
    if (form && form.parentElement !== api.toolbar) {
      api.toolbar.prepend(form);
      form.classList.add('gl-native-search');
      hidden(form.querySelector('button[type="submit"]'), true);
    }
    adopt(api, document.querySelector('#journey-app .ready-stock-filters'));
    external(api, dates(document.getElementById('journey-from'), document.getElementById('journey-to'), () => document.getElementById('clear-journey-range')?.click()));
    const cable = document.querySelector('#journey-app .journey-cable-card');
    if (cable && !cable.closest('.gl-secondary-tool')) {
      const disclosure = node('details', 'gl-secondary-tool');
      disclosure.append(node('summary', '', 'Update connected phone details'));
      document.getElementById('journey-app').append(disclosure);
      disclosure.append(cable);
    }
  }
  // Login Activity is the one native search/date form not backed by FILTERS.
  // Its original form, input IDs and live-search listeners remain intact.
  function loginActivity() {
    const form = document.getElementById('login-activity-filters');
    if (!form || form.dataset.cleanLayout) return;
    form.dataset.cleanLayout = 'native-filter';
    form.classList.add('table-filters', 'gl-native-filters');
    const children = [...form.children];
    const toolbar = node('div', 'table-filter-toolbar');
    const panel = node('div', 'table-filter-panel table-filter-native');
    panel.id = 'login-activity-filter-panel'; panel.hidden = true;
    panel.setAttribute('role', 'group'); panel.setAttribute('aria-label', 'Login activity filters');
    const toggle = node('button', 'secondary-button table-filter-toggle', 'Filters');
    toggle.type = 'button'; toggle.setAttribute('aria-controls', panel.id); toggle.setAttribute('aria-expanded', 'false');
    const searchLabel = document.getElementById('login-activity-search')?.closest('label');
    if (searchLabel) { searchLabel.classList.add('table-filter-field'); toolbar.append(searchLabel); }
    toolbar.append(toggle);
    children.filter(element => element !== searchLabel).forEach(element => panel.append(element));
    const chips = node('div', 'table-filter-chips');
    form.append(toolbar, panel, chips);
    function refresh() {
      const items = dates(document.getElementById('login-activity-from'), document.getElementById('login-activity-to'));
      const text = items.map(item => item.label + ': ' + item.value).join(' · ');
      if (chips.textContent !== text) chips.textContent = text;
      hidden(chips, !items.length);
      const label = items.length ? 'Filters (1)' : 'Filters';
      if (toggle.textContent !== label) toggle.textContent = label;
    }
    toggle.addEventListener('click', () => { panel.hidden = !panel.hidden; toggle.setAttribute('aria-expanded', String(!panel.hidden)); });
    form.addEventListener('input', refresh);
    form.addEventListener('change', refresh);
    form.addEventListener('reset', () => queueMicrotask(refresh));
    refresh();
  }
  const helpSelectors = [
    '.page-heading .heading-subtitle', '.page-heading > div > p:not(.eyebrow):not(.panel-kicker)',
    '.form-panel-heading > div > p:not(.panel-kicker)', '.qc-bulk-toolbar > div > p:not(.panel-kicker)',
    '.final-bulk-toolbar > div > p:not(.panel-kicker)', '#accounts-stock-note',
    '#report-panel-description', '.login-activity-help:not(#login-activity-since)'
  ];
  function routineHelp() {
    document.querySelectorAll(helpSelectors.join(',')).forEach(element => {
      if (!element.textContent.trim() || element.closest('dialog,.gl-clean-help') || element.matches('#ready-stock-subtitle,[role="status"],[role="alert"],[aria-live]')) return;
      const disclosure = node('details', 'gl-clean-help');
      disclosure.append(node('summary', '', element.closest('.page-heading') ? 'Page help' : 'Details'));
      element.before(disclosure); disclosure.append(element);
    });
    document.querySelectorAll('.gl-clean-help').forEach(disclosure => {
      hidden(disclosure, ![...disclosure.children].some(element => element.tagName !== 'SUMMARY' && element.textContent.trim()));
    });
    document.querySelectorAll('.receiving-side').forEach(side => {
      if (side.closest('.gl-secondary-tool') || side.querySelector('input,select,textarea,button,[role="status"],[role="alert"]')) return;
      const disclosure = node('details', 'gl-secondary-tool gl-workflow-help');
      disclosure.append(node('summary', '', 'Workflow help'));
      side.before(disclosure); disclosure.append(side);
      disclosure.closest('.receiving-layout')?.classList.add('gl-work-first');
    });
  }
  function inventory() {
    const app = document.getElementById('inventory-app');
    if (!app || app.dataset.cleanTabs) return;
    const panes = [
      ['stock', 'Current Stock', app.querySelector('.inventory-stock-panel')],
      ['receive', 'Receive Parts', app.querySelector('.inventory-receipt-panel')],
      ['history', 'Receipt History', app.querySelector('.inventory-history-panel')]
    ];
    if (panes.some(([, , panel]) => !panel)) return;
    app.dataset.cleanTabs = 'true';
    const tabs = node('nav', 'gl-work-tabs'); tabs.setAttribute('role', 'tablist'); tabs.setAttribute('aria-label', 'Inventory sections');
    const select = selected => panes.forEach(([key, , panel]) => {
      const button = tabs.querySelector('[data-work-tab="' + key + '"]');
      button.setAttribute('aria-selected', String(key === selected)); button.tabIndex = key === selected ? 0 : -1;
      hidden(panel, key !== selected);
    });
    panes.forEach(([key, label, panel]) => {
      const button = node('button', 'secondary-button gl-work-tab', label); button.type = 'button';
      button.dataset.workTab = key; button.id = 'inventory-tab-' + key; button.setAttribute('role', 'tab');
      panel.id ||= 'inventory-panel-' + key; button.setAttribute('aria-controls', panel.id);
      panel.setAttribute('role', 'tabpanel'); panel.setAttribute('aria-labelledby', button.id);
      button.addEventListener('click', () => select(key)); tabs.append(button);
    });
    tabs.addEventListener('keydown', event => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
      const keys = panes.map(([key]) => key), index = keys.indexOf(event.target.dataset.workTab);
      if (index < 0) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? keys.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + keys.length) % keys.length;
      select(keys[next]); tabs.querySelector('[data-work-tab="' + keys[next] + '"]').focus();
    });
    app.querySelector('.inventory-stats').after(tabs);
    select('stock');
  }
  function parts() {
    const summary = document.querySelector('#parts-app .parts-summary');
    const issue = document.querySelector('#parts-app .parts-sheet-panel');
    if (summary && issue && !issue.dataset.cleanPriority) {
      issue.dataset.cleanPriority = 'true'; summary.after(issue);
      [...document.querySelectorAll('#parts-app > .form-panel')].forEach((panel, index) => {
        const number = panel.querySelector('.section-number'); if (number) number.textContent = String(index + 1).padStart(2, '0');
      });
    }
  }
  let queued = false;
  function refresh() { reports(); journey(); loginActivity(); inventory(); parts(); routineHelp(); }
  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; refresh(); });
  }
  window.GREENLOOP_CLEAN_LAYOUT = {version:'20261017-clean-layout-1', refresh:schedule};
  const main = document.querySelector('.app-main');
  if (main) new MutationObserver(schedule).observe(main, {childList:true, subtree:true, attributes:true, attributeFilter:['hidden','aria-pressed']});
  document.addEventListener('change', schedule);
  document.addEventListener('input', schedule);
  document.addEventListener('submit', schedule);
  document.addEventListener('click', schedule);
  schedule();
})();
