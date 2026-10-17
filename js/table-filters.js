(() => {
  'use strict';
  const instances = new Map();
  const text = value => value == null ? '' : String(value);
  const normalized = value => text(value).trim().toLocaleLowerCase('en');
  const fieldValue = (row, field) => typeof field === 'function' ? field(row) : text(field).split('.').reduce((v, k) => v?.[k], row);
  const day = value => {
    if (!value) return '';
    if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? new Date(date.getTime() + 14400000).toISOString().slice(0, 10) : '';
  };
  const node = (tag, cls, value) => {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (value !== undefined) el.textContent = value;
    return el;
  };
  // Debounce reads, not typing. Composition is committed only when it ends.
  function liveSearch(input, run) {
    let timer, composing = false;
    const cancel = () => { clearTimeout(timer); timer = null; };
    const schedule = event => {
      cancel();
      if (composing || event?.isComposing) return;
      timer = setTimeout(() => { timer = null; run(); }, input.value ? 200 : 0);
    };
    input.addEventListener('input', schedule);
    input.addEventListener('search', schedule);
    input.addEventListener('compositionstart', () => { composing = true; cancel(); });
    input.addEventListener('compositionend', () => { composing = false; schedule(); });
    return {cancel};
  }
  function create(id, options) {
    const bar = node('div', 'table-filters'); bar.id = id;
    bar.setAttribute('role', 'search'); bar.setAttribute('aria-label', options.label || 'Filter records');
    const controls = new Map(), fields = options.fields || [];
    let applied = {}, source = [], sourceRows = [], latestOptions = options, busy = false, pendingChange = null, live, external = [];
    const toolbar = node('div', 'table-filter-toolbar');
    const panel = node('div', 'table-filter-panel'); panel.id = id + '-panel'; panel.hidden = true;
    const chips = node('div', 'table-filter-chips'); chips.hidden = true;
    const actions = node('div', 'table-filter-actions');
    const toggle = node('button', 'secondary-button table-filter-toggle', 'Filters');
    toggle.type = 'button'; toggle.setAttribute('aria-controls', panel.id); toggle.setAttribute('aria-expanded', 'false');
    const close = node('button', 'secondary-button table-filter-close', 'Done'); close.type = 'button';
    bar.append(toolbar, chips, panel);
    function control(key, label, type) {
      const wrap = node('label', 'table-filter-field');
      wrap.append(node('span', '', label));
      const input = node(type === 'select' ? 'select' : 'input');
      input.id = id + '-' + key; input.dataset.searchReadOnly = '';
      input.setAttribute('aria-label', label); if (type !== 'select') input.type = type;
      if (type === 'search') { input.placeholder = options.placeholder || 'Type to search…'; input.maxLength = 160; }
      wrap.append(input); (type === 'search' ? toolbar : panel).append(wrap); controls.set(key, input);
      if (type === 'search') wrap.classList.add('table-filter-search');
    }
    if (options.searchInput) controls.set('_search', options.searchInput);
    else if (options.search !== false) control('_search', 'Search', 'search');
    if (options.dateKey) { control('_from', 'From date', 'date'); control('_to', 'To date', 'date'); for (const key of ['_from', '_to']) controls.get(key).title = (options.dateLabel || 'Record') + ' date range'; }
    fields.forEach(([key, label]) => control(key, label, 'select'));
    const panelActions = node('div', 'table-filter-panel-actions');
    const apply = node('button', 'primary-button table-filter-apply', 'Apply filters'); apply.type = 'button'; apply.dataset.searchReadOnly = '';
    const clear = node('button', 'secondary-button', 'Clear filters'); clear.type = 'button'; clear.dataset.searchReadOnly = '';
    panelActions.append(apply, clear, close); panel.append(panelActions);
    actions.append(toggle); toolbar.append(actions);
    const status = node('p', 'table-filter-status'); status.setAttribute('role', 'status'); toolbar.append(status);
    function setOpen(open) { panel.hidden = !open; toggle.setAttribute('aria-expanded', String(open)); }
    toggle.addEventListener('click', () => setOpen(panel.hidden));
    close.addEventListener('click', () => { setOpen(false); toggle.focus(); });
    bar.addEventListener('keydown', e => { if (e.key === 'Escape' && !panel.hidden) { e.stopPropagation(); setOpen(false); toggle.focus(); } });
    function externalFilters() { return latestOptions.externalFilters ? latestOptions.externalFilters() || [] : external; }
    function refreshLayout() {
      const extra = externalFilters().filter(item => item && item.value);
      const active = [...controls].filter(([key]) => key !== '_search' && applied[key]);
      const count = active.length + extra.length;
      toggle.textContent = count ? `Filters (${count})` : 'Filters';
      toggle.hidden = ![...controls].some(([key, input]) => key !== '_search' && !input.closest('label')?.hidden) && !panel.querySelector('.table-filter-native');
      apply.hidden = ![...controls].some(([key, input]) => key !== '_search' && !input.closest('label')?.hidden);
      clear.disabled = busy || (!Object.keys(applied).length && !extra.length);
      chips.replaceChildren();
      function chip(label, value, remove) {
        if (typeof remove !== 'function') { chips.append(node('span', 'table-filter-chip', `${label}: ${value}`)); return; }
        const button = node('button', 'table-filter-chip', `${label}: ${value} ×`); button.type = 'button'; button.dataset.searchReadOnly = '';
        button.setAttribute('aria-label', `Remove ${label} filter`); button.disabled = busy;
        button.addEventListener('click', async () => { if (busy) return; try { await remove(); refreshLayout(); } catch (e) { status.textContent = e.message || 'Could not clear this filter.'; } });
        chips.append(button);
      }
      for (const [key, input] of active) {
        const label = key === '_from' ? 'From' : key === '_to' ? 'To' : fields.find(([name]) => name === key)?.[1] || key;
        const value = input.tagName === 'SELECT' ? [...input.options].find(option => option.value === applied[key])?.textContent || applied[key] : applied[key];
        chip(label, value, async () => { input.value = ''; delete applied[key]; await latestOptions.onChange?.(); });
      }
      for (const item of extra) chip(item.label, item.value, item.clear);
      chips.hidden = chips.children.length === 0;
      window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(bar);
    }
    function adopt(target) {
      const elements = typeof target === 'string' ? document.querySelectorAll(target) : target instanceof Element ? [target] : target || [];
      for (const el of elements) { if (el === panel || el.contains(panel)) continue; el.classList.add('table-filter-native'); el.hidden = false; panel.insertBefore(el, panelActions); }
      refreshLayout();
    }
    const sorting = window.GREENLOOP_SORTING.create(id, bar, options, async () => {
      try { await latestOptions.onChange?.(); }
      catch (e) { status.textContent = e.message || 'Could not sort records. Try again.'; }
    });
    const originalOrder = new WeakMap(); let nextOrder = 0;
    const get = row => latestOptions.project ? latestOptions.project(row) : row;
    function highlight() {
      const scope = latestOptions.highlightTarget || latestOptions.sortTarget || latestOptions.before;
      const root = typeof scope === 'string' ? document.querySelector(scope) : scope;
      const term = latestOptions.highlightQuery ? latestOptions.highlightQuery() : applied._search;
      window.GREENLOOP_HIGHLIGHTS?.show(root, term);
    }
    function updateFacets(facets) {
      fields.forEach(([key, label]) => {
        const select = controls.get(key), draft = select.value || '';
        const values = [...new Set((facets[key] || []).map(text).filter(Boolean))];
        if (draft && !values.includes(draft)) values.push(draft);
        select.replaceChildren(new Option('All', ''));
        values.sort((a,b)=>a.localeCompare(b, undefined, {numeric:true})).forEach(v=>select.add(new Option(v.replaceAll('_', ' '), v)));
        select.value = draft;
      });
    }
    function matches(row) {
      const r = get(row);
      if (applied._search) {
        const values = (latestOptions.searchFields || fields.map(f=>f[0])).map(key=>fieldValue(r,key));
        if (!normalized(values.join(' ')).includes(normalized(applied._search))) return false;
      }
      const d = day(fieldValue(r, latestOptions.dateKey));
      if (applied._from && (!d || d < applied._from)) return false;
      if (applied._to && (!d || d > applied._to)) return false;
      return fields.every(([key]) => !applied[key] || normalized(fieldValue(r,key)) === normalized(applied[key]));
    }
    async function change(reset, searchOnly = false) {
      live?.cancel();
      // A delayed keystroke must not reopen a report after its tab was left.
      if (searchOnly && !bar.getClientRects().length) { pendingChange = null; return; }
      // Keep just the latest requested search while a reader is running. This
      // also covers pages that intentionally serialize reads with other actions.
      if (busy) { pendingChange = {reset, searchOnly}; status.textContent = 'Searching…'; return; }
      pendingChange = null;
      const next = searchOnly ? {...applied} : {};
      if (searchOnly) {
        delete next._search;
        const value = controls.get('_search')?.value.trim();
        if (value) next._search = value;
      } else for (const [key, input] of controls) if (!reset && input.value.trim()) next[key] = input.value.trim();
      if (next._from && next._to && next._from > next._to) { status.textContent = 'From date must be on or before To date.'; return; }
      if (reset) for (const input of controls.values()) input.value = '';
      applied = next;
      refreshLayout();
      try {
        if (reset) for (const item of externalFilters().filter(item => item?.value)) await item.clear?.();
        await latestOptions.onChange?.();
        refreshLayout();
      }
      catch (e) { status.textContent = e.message || 'Could not load filtered records. Try again.'; }
    }
    if (controls.has('_search')) live = liveSearch(controls.get('_search'), () => change(false, true));
    apply.addEventListener('click',()=>change(false)); clear.addEventListener('click',()=>change(true));
    bar.addEventListener('keydown',e=>{if(e.key === 'Enter' && !e.isComposing && e.target.tagName !== 'BUTTON' && !e.target.closest('.table-filter-native')){e.preventDefault();e.stopPropagation();change(false);}});
    const api = {
      bar, controls, panel, toolbar, actions, refreshLayout, adopt,
      externalFilters(items) { external = items || []; refreshLayout(); },
      query: () => ({...applied}),
      sortArgs: () => sorting.args(),
      sortRows: rows => sorting.sort(rows),
      setSortFields: fields => { latestOptions = {...latestOptions,sortFields:fields}; sorting.refresh(latestOptions); },
      clear: () => change(true),
      submit: () => change(false),
      mount(opts = latestOptions) {
        latestOptions = opts;
        sorting.refresh(opts);
        const target = typeof opts.before === 'string' ? document.querySelector(opts.before) : opts.before;
        if (target && !bar.isConnected) target.before(bar);
        bar.hidden = false;
        if (opts.nativeControls) adopt(opts.nativeControls);
        refreshLayout();
      },
      apply(rows, opts = latestOptions) {
        api.mount(opts); sourceRows = rows; source = rows.map(get);
        updateFacets(Object.fromEntries(fields.map(([key])=>[key,source.map(r=>fieldValue(r,key))])));
        refreshLayout();
        const result = rows.filter(matches);
        status.textContent = `${result.length} of ${rows.length} records`;
        highlight();
        return opts.sortAfterGroup ? result : sorting.sort(result);
      },
      // Hide existing editable rows rather than recreating them: draft values,
      // checked controls, scanner targets and workflow row identity are retained.
      bind(rows, elements, opts = latestOptions) {
        const selected = new Set(api.apply(rows, opts));
        rows.forEach((r,i)=>{if(elements[i]) elements[i].hidden = !selected.has(r);});
        const pairs = rows.map((row,i)=>({row,element:elements[i]})).filter(p=>p.element);
        pairs.forEach(p=>{if(!originalOrder.has(p.element))originalOrder.set(p.element,nextOrder++);});
        pairs.sort((a,b)=>originalOrder.get(a.element)-originalOrder.get(b.element));
        const ordered = sorting.sort(pairs,p=>get(p.row));
        const parent = ordered[0]?.element.parentElement;
        if(parent && ordered.every(p=>p.element.parentElement===parent)) ordered.forEach((p,i)=>{
          if(parent.children[i]!==p.element)parent.insertBefore(p.element,parent.children[i] || null);
        });
        return selected.size;
      },
      result(data) {
        updateFacets(data.facets || {});
        refreshLayout();
        status.textContent = pendingChange ? 'Searching…' : `${data.total} matching records`;
        highlight();
        queueMicrotask(sorting.decorate);
      },
      fail(message) { status.textContent = message; },
      setBusy(value) {
        busy = value; bar.setAttribute('aria-busy', String(value));
        for (const el of [apply,clear,...controls.values()]) el.disabled = value && el !== controls.get('_search');
        sorting.setBusy(value);
        refreshLayout();
        if (!value && pendingChange) queueMicrotask(() => {
          if (!busy && pendingChange) { const next = pendingChange; change(next.reset, next.searchOnly); }
        });
      }
    };
    api.mount(); instances.set(id, api); return api;
  }
  const get = (id, options) => instances.get(id) || create(id, options);
  const use = (id, rows, options) => get(id, options).apply(rows, options);
  async function all(query) {
    const rows = []; const size = 500;
    for (let start = 0;; start += size) {
      const {data,error} = await query().range(start,start+size-1);
      if (error) return {data:null,error};
      rows.push(...(data || [])); if (!data || data.length < size) return {data:rows,error:null};
    }
  }
  function remote(id, options) {
    const filter = get(id, {...options,onChange:()=>{filter.offset=0;return filter.load();}});
    if (filter.load) return filter;
    filter.offset = 0;
    let total = 0, version = 0;
    const previous = node('button','secondary-button','Previous'), next = node('button','secondary-button','Next');
    const pagination = node('nav','table-filter-pagination'); pagination.setAttribute('aria-label', 'Record pages');
    [previous,next].forEach(b=>{b.type='button';b.dataset.searchReadOnly='';pagination.append(b);});
    const count = node('span','table-filter-page-count');pagination.append(count);
    function mountPager() {
      const ref = options.sortTarget || options.before;
      const target = typeof ref === 'string' ? document.querySelector(ref) : ref;
      if (target && pagination.previousElementSibling !== target) target.after(pagination);
    }
    mountPager();
    const size = options.pageSize || 50;
    function pager(busy) { previous.disabled=busy||filter.offset===0;next.disabled=busy||filter.offset+size>=total; }
    previous.onclick=()=>{filter.offset=Math.max(0,filter.offset-size);filter.load().catch(()=>{});};
    next.onclick=()=>{filter.offset+=size;filter.load().catch(()=>{});};
    filter.load = async () => {
      const token=++version;filter.setBusy(true);pager(true);
      try {
        const client=options.client ? options.client() : window.GREENLOOP_GET_CLIENT();
        const {data,error}=await client.rpc('get_sorted_filter_records_v1',{p_source:options.source,p_filters:filter.query(),p_offset:filter.offset,p_limit:size,...filter.sortArgs()});
        if(token!==version)return;
        if(error)throw error;
        total=Number(data.total);
        if(filter.offset && filter.offset>=total){filter.offset=Math.max(0,Math.floor(Math.max(0,total-1)/size)*size);return filter.load();}
        filter.result(data);count.textContent=total?`${filter.offset+1}–${Math.min(filter.offset+size,total)} of ${total}`:'0 records';
        options.onResult(data);mountPager();return data;
      } catch(e) {
        if(token===version){total=0;count.textContent='Unavailable';filter.fail(e.message||'Could not load records.');options.onError?.(e);}
        throw e;
      } finally {if(token===version){filter.setBusy(false);pager(false);}}
    };
    return filter;
  }
  window.GREENLOOP_FILTERS = {get,use,day,all,remote,liveSearch,find:id=>instances.get(id)};
})();
