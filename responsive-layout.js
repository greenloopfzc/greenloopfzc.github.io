/* Layout only. No requests, storage, data edits, cloned inputs or replacement
   rows. Existing listeners, focus, selections and workflow state stay intact. */
(() => {
  'use strict';
  // Includes pending-QC overlays outside .page-content as well as native dialogs.
  const selector = 'table';
  const states = new WeakMap();
  const observed = new Set();
  const widths = new WeakMap();
  let scheduled = false;
  let printing = false;
  const interactive = 'button,input,select,a[href],[tabindex],th[onclick],[role="button"]';
  const observerOptions = { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'open', 'class', 'style', 'colspan', 'rowspan'] };

  function schedule() {
    if (scheduled || printing) return;
    scheduled = true;
    requestAnimationFrame(refresh);
  }
  const mutations = new MutationObserver(records => {
    if (records.some(record => !record.target.closest?.('.live-headlines'))) schedule();
  });
  const sizes = new ResizeObserver(entries => {
    for (const entry of entries) {
      const width = entry.contentRect.width;
      if (Math.abs((widths.get(entry.target) ?? -1) - width) > 1) {
        widths.set(entry.target, width);
        schedule();
      }
    }
  });
  function role(node, value) { if (!node.hasAttribute('role')) node.setAttribute('role', value); }

  function headers(table) {
    const rows = table.tHead ? Array.from(table.tHead.rows) : [];
    const matrix = [];
    rows.forEach((row, rowIndex) => {
      matrix[rowIndex] ||= [];
      let column = 0;
      Array.from(row.cells).forEach(cell => {
        while (matrix[rowIndex][column]) column++;
        const text = cell.textContent.trim().replace(/\s+/g, ' ');
        for (let y = 0; y < cell.rowSpan; y++) {
          matrix[rowIndex + y] ||= [];
          for (let x = 0; x < cell.colSpan; x++) matrix[rowIndex + y][column + x] = text;
        }
        column += cell.colSpan;
        role(cell, 'columnheader');
      });
      role(row, 'row');
    });
    const count = Math.max(0, ...matrix.map(row => row.length));
    return Array.from({ length: count }, (_, column) => [...new Set(matrix.map(row => row[column]).filter(Boolean))].join(' / '));
  }

  function prepare(table) {
    const labels = headers(table);
    role(table, 'table');
    table.classList.add('gl-responsive-table');
    if (table.tHead) {
      role(table.tHead, 'rowgroup');
      table.tHead.classList.toggle('gl-interactive-head', !!table.tHead.querySelector(interactive));
    }
    const fieldWidths = labels.map(label => {
      if (/^(#|no\.?|qty|quantity|gb|bh|pass|fail)$/i.test(label)) return 65;
      if (/imei|serial/i.test(label)) return 175;
      if (/date|time|created|received at/i.test(label)) return 155;
      return 115;
    });
    let ordinaryRows = 0;
    for (const group of [...table.tBodies, ...(table.tFoot ? [table.tFoot] : [])]) {
      role(group, 'rowgroup');
      Array.from(group.rows).forEach((row, rowIndex) => {
        role(row, 'row');
        let column = 0;
        if (row.cells.length > 1) ordinaryRows++;
        Array.from(row.cells).forEach(cell => {
          role(cell, cell.tagName === 'TH' ? 'rowheader' : 'cell');
          const label = labels.slice(column, column + cell.colSpan).filter(Boolean).join(' / ');
          const wide = cell.colSpan > 1;
          cell.classList.toggle('gl-wide-cell', wide);
          if (label && !wide) cell.setAttribute('data-label', label);
          else cell.removeAttribute('data-label');
          const controls = Array.from(cell.querySelectorAll('input,select,textarea')).filter(control => control.closest('table') === table);
          if (!wide && controls.some(control => !['checkbox', 'radio', 'hidden'].includes(control.type))) {
            fieldWidths[column] = Math.max(fieldWidths[column] || 0, cell.querySelector('.batch-option-control,.stock-plan-option-control') ? 240 : 180);
          }
          controls.forEach(control => {
            if (label && !control.labels?.length && !control.hasAttribute('aria-label') && !control.hasAttribute('aria-labelledby')) {
              control.setAttribute('aria-label', `${label}, row ${rowIndex + 1}`);
            }
          });
          column += cell.colSpan;
        });
      });
    }
    states.set(table, { minimum: ordinaryRows ? fieldWidths.reduce((sum, width) => sum + width, 0) : 0 });
    const container = table.parentElement;
    container.classList.add('gl-table-container');
    if (!observed.has(container)) { observed.add(container); sizes.observe(container); }
  }

  function refresh() {
    scheduled = false;
    if (printing) return;
    mutations.disconnect();
    try {
      // Reports replace table markup; release old containers promptly.
      for (const container of observed) {
        if (!container.isConnected) { sizes.unobserve(container); observed.delete(container); }
      }
      const tables = Array.from(document.querySelectorAll(selector));
      // Prepare whole tables together, never read layout once per record.
      for (const table of tables) {
        prepare(table);
        table.classList.remove('gl-table-reflow');
      }
      // DOM order makes outer tables settle before measuring nested detail tables.
      // Measuring children against an expanded parent causes resize oscillation.
      for (const table of tables) {
        if (!table.getClientRects().length) continue;
        const container = table.parentElement;
        const css = getComputedStyle(container);
        const available = container.clientWidth - parseFloat(css.paddingLeft || 0) - parseFloat(css.paddingRight || 0);
        // Dense editable worksheets can declare a measured compact-row budget.
        // Other tables retain the shared readable-column estimate.
        const rowMinimum = Number.parseFloat(getComputedStyle(table).getPropertyValue('--gl-table-row-min-width'));
        const minimum = Number.isFinite(rowMinimum) && rowMinimum > 0 ? rowMinimum : states.get(table).minimum;
        table.classList.toggle('gl-table-reflow', available > 0 && (table.scrollWidth > available + 2 || minimum > available + 2));
      }
    } finally { mutations.observe(document.body, observerOptions); }
  }
  function start() {
    mutations.observe(document.body, observerOptions);
    window.addEventListener('resize', schedule, { passive: true });
    document.addEventListener('toggle', schedule, true);
    document.addEventListener('change', schedule, true);
    window.addEventListener('beforeprint', () => { printing = true; });
    window.addEventListener('afterprint', () => { printing = false; schedule(); });
    document.fonts?.ready.then(schedule);
    schedule();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
