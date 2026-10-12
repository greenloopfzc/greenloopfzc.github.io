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
  function create(id, options) {
    const bar = node('div', 'table-filters'); bar.id = id;
    bar.setAttribute('role', 'search'); bar.setAttribute('aria-label', options.label || 'Filter records');
    const controls = new Map(), fields = options.fields || [];
    let applied = {}, source = [], sourceRows = [], latestOptions = options;
    function control(key, label, type) {
      const wrap = node('label', 'table-filter-field');
      wrap.append(node('span', '', label));
      const input = node(type === 'select' ? 'select' : 'input');
      input.id = id + '-' + key; input.dataset.searchReadOnly = '';
      input.setAttribute('aria-label', label); if (type !== 'select') input.type = type;
      if (type === 'search') { input.placeholder = options.placeholder || 'Search matching records…'; input.maxLength = 160; }
      wrap.append(input); bar.append(wrap); controls.set(key, input);
    }
    if (options.search !== false) control('_search', 'Search', 'search');
    if (options.dateKey) { control('_from', (options.dateLabel || 'Date') + ' from · UAE', 'date'); control('_to', 'To · UAE', 'date'); }
    fields.forEach(([key, label]) => control(key, label, 'select'));
    const actions = node('div', 'table-filter-actions');
    const apply = node('button', 'primary-button', 'Search'); apply.type = 'button'; apply.dataset.searchReadOnly = '';
    const clear = node('button', 'secondary-button', 'Clear filters'); clear.type = 'button'; clear.dataset.searchReadOnly = '';
    actions.append(apply, clear); bar.append(actions);
    const status = node('p', 'table-filter-status'); status.setAttribute('role', 'status'); bar.append(status);
    const get = row => latestOptions.project ? latestOptions.project(row) : row;
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
    async function change(reset) {
      const next = {};
      for (const [key, input] of controls) if (!reset && input.value.trim()) next[key] = input.value.trim();
      if (next._from && next._to && next._from > next._to) { status.textContent = 'From date must be on or before To date.'; return; }
      if (reset) for (const input of controls.values()) input.value = '';
      applied = next;
      try { await latestOptions.onChange?.(); }
      catch (e) { status.textContent = e.message || 'Could not load filtered records. Try again.'; }
    }
    apply.addEventListener('click',()=>change(false)); clear.addEventListener('click',()=>change(true));
    bar.addEventListener('keydown',e=>{if(e.key === 'Enter' && e.target.tagName !== 'BUTTON'){e.preventDefault();e.stopPropagation();change(false);}});
    const api = {
      bar, controls,
      query: () => ({...applied}),
      clear: () => change(true),
      mount(opts = latestOptions) {
        latestOptions = opts;
        const target = typeof opts.before === 'string' ? document.querySelector(opts.before) : opts.before;
        if (target && !bar.isConnected) target.before(bar);
        bar.hidden = false;
      },
      apply(rows, opts = latestOptions) {
        api.mount(opts); sourceRows = rows; source = rows.map(get);
        updateFacets(Object.fromEntries(fields.map(([key])=>[key,source.map(r=>fieldValue(r,key))])));
        const result = rows.filter(matches);
        status.textContent = `${result.length} of ${rows.length} records`;
        return result;
      },
      // Hide existing editable rows rather than recreating them: draft values,
      // checked controls, scanner targets and workflow row identity are retained.
      bind(rows, elements, opts = latestOptions) {
        const selected = new Set(api.apply(rows, opts));
        rows.forEach((r,i)=>{if(elements[i]) elements[i].hidden = !selected.has(r);});
        return selected.size;
      },
      result(data) {
        updateFacets(data.facets || {});
        status.textContent = `${data.total} matching records`;
      },
      fail(message) { status.textContent = message; },
      setBusy(busy) { for(const el of [apply,clear,...controls.values()]) el.disabled = busy; }
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
    [previous,next].forEach(b=>{b.type='button';b.dataset.searchReadOnly='';filter.bar.append(b);});
    const count = node('span','table-filter-status');filter.bar.append(count);
    const size = options.pageSize || 50;
    function pager(busy) { previous.disabled=busy||filter.offset===0;next.disabled=busy||filter.offset+size>=total; }
    previous.onclick=()=>{filter.offset=Math.max(0,filter.offset-size);filter.load().catch(()=>{});};
    next.onclick=()=>{filter.offset+=size;filter.load().catch(()=>{});};
    filter.load = async () => {
      const token=++version;filter.setBusy(true);pager(true);
      try {
        const client=options.client ? options.client() : window.GREENLOOP_GET_CLIENT();
        const {data,error}=await client.rpc('get_filter_records_v1',{p_source:options.source,p_filters:filter.query(),p_offset:filter.offset,p_limit:size});
        if(token!==version)return;
        if(error)throw error;
        total=Number(data.total);
        if(filter.offset && filter.offset>=total){filter.offset=Math.max(0,Math.floor(Math.max(0,total-1)/size)*size);return filter.load();}
        filter.result(data);count.textContent=total?`${filter.offset+1}–${Math.min(filter.offset+size,total)} of ${total}`:'0 records';
        options.onResult(data);return data;
      } catch(e) {
        if(token===version){total=0;count.textContent='Unavailable';filter.fail(e.message||'Could not load records.');options.onError?.(e);}
        throw e;
      } finally {if(token===version){filter.setBusy(false);pager(false);}}
    };
    return filter;
  }
  window.GREENLOOP_FILTERS = {get,use,day,all,remote};
})();
