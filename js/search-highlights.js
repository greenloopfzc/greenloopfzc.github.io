(() => {
  'use strict';
  const watchers = new WeakMap();
  const skipped = 'script,style,input,textarea,select,option,thead,label,[contenteditable],.table-filters,.table-sort-controls,[data-no-search-highlight]';
  function paint(root, term) {
    // Only replace text nodes. Row elements, links, event handlers and drafts stay intact.
    root.querySelectorAll('mark[data-greenloop-match]').forEach(mark => {
      const parent = mark.parentNode;
      mark.replaceWith(...mark.childNodes);
      parent.normalize();
    });
    if (!term) return;
    const pattern = new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    const groups = new Map();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {acceptNode(node) {
      return node.parentElement.closest(skipped) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
    }});
    let node;
    while ((node = walker.nextNode())) {
      const closest = node.parentElement.closest('td,article,li');
      const unit = closest && root.contains(closest) ? closest : node.parentElement;
      if (!groups.has(unit)) groups.set(unit, []);
      groups.get(unit).push(node);
    }
    for (const nodes of groups.values()) {
      const content = nodes.map(n => n.data).join('');
      const matches = [...content.matchAll(pattern)].map(m => [m.index, m.index + m[0].length]);
      let offset = 0;
      for (const textNode of nodes) {
        const start = offset, end = start + textNode.length; offset = end;
        const ranges = matches.filter(([a,b]) => a < end && b > start).map(([a,b]) => [Math.max(0,a-start),Math.min(end-start,b-start)]);
        if (!ranges.length) continue;
        const fragment = document.createDocumentFragment(); let position = 0;
        for (const [a,b] of ranges) {
          fragment.append(document.createTextNode(textNode.data.slice(position,a)));
          const mark = document.createElement('mark'); mark.className = 'search-match'; mark.dataset.greenloopMatch = '';
          mark.textContent = textNode.data.slice(a,b); fragment.append(mark); position = b;
        }
        fragment.append(document.createTextNode(textNode.data.slice(position))); textNode.replaceWith(fragment);
      }
    }
  }
  function show(root, query) {
    if (!root) return;
    let state = watchers.get(root);
    if (!state) {
      state = {query:'', scheduled:false};
      state.observer = new MutationObserver(() => schedule(state));
      state.run = () => {
        state.scheduled = false; state.observer.disconnect();
        paint(root, state.query);
        if (state.query) state.observer.observe(root, {subtree:true,childList:true,characterData:true});
      };
      watchers.set(root, state);
    }
    state.query = String(query || '').trim(); schedule(state);
  }
  function schedule(state) {
    if (state.scheduled) return;
    state.scheduled = true; queueMicrotask(state.run);
  }
  window.GREENLOOP_HIGHLIGHTS = {show};
})();
