(() => {
  'use strict';
  const $ = s => document.querySelector(s);
  const root = $('#accounts-imei-panel');
  if (!root) return;
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num = n => Number(n || 0).toLocaleString('en-GB');
  const when = v => v ? new Date(v).toLocaleString('en-GB', {timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}) : 'Not recorded';
  const receivedDate = v => v ? new Date(v).toLocaleDateString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}) : 'Not recorded';
  const storage = n => n == null ? '—' : Number(n) >= 1024 && Number(n) % 1024 === 0 ? Number(n)/1024+' TB' : n+' GB';
  const can = c => window.GREENLOOP_CAN?.(c,'accounts') === true;
  const allowed = () => can('view') && can('imei_data');
  const columns = [[null,'S.No'],['imei','IMEI'],['model','Model'],['storage_gb','GB'],['color','Color'],['supplier_code','Supplier'],['batch_number','Stock / Batch No.'],['invoice_number','Invoice No.'],['received_at','Date Received']];
  let client, catalogue = null, report = null, visible = false, stopped = false, loading = false, exporting = false;
  const cards=window.GREENLOOP_ACCOUNTS_CARDS;
  let detailOpen=false,metric='all';
  let offset = 0, sortKey = 'imei', direction = 'asc', generation = 0, searchTimer, pdfUrl = '', pdfFilename = '';

  root.innerHTML = `<div class="aid-header"><div><p class="panel-kicker">STOCK RECORDS</p><h2>IMEI DATA</h2><p>Choose a supplier, stock/batch or invoice to view its complete phone list.</p></div><span id="aid-updated"></span></div>
    <div class="aid-primary">
      <label>Supplier<select id="aid-supplier" data-capability="search" data-capability-page="accounts"><option value="">All suppliers</option></select></label>
      <label>Stock / Batch<select id="aid-batch" data-capability="search" data-capability-page="accounts"><option value="">All stock / batches</option></select></label>
      <label>Invoice<select id="aid-invoice" data-capability="search" data-capability-page="accounts"><option value="">All invoices</option></select></label>
    </div>
    <div class="aid-toolbar"><input id="aid-search" type="search" placeholder="Search IMEI, model, color, supplier or receipt" aria-label="Search IMEI DATA" maxlength="160" data-capability="search" data-capability-page="accounts">
      <button id="aid-filter-toggle" class="secondary-button" type="button" aria-expanded="false" aria-controls="aid-filters" data-capability="search" data-capability-page="accounts">Filters</button>
      <button id="aid-clear" class="secondary-button" type="button" data-capability="search" data-capability-page="accounts">Clear filters</button>
      <button id="aid-refresh" class="secondary-button" type="button" data-capability="imei_data" data-capability-page="accounts">Refresh</button>
      <div class="aid-export-actions"><button type="button" class="secondary-button" data-aid-export="view" data-capability="imei_download" data-capability-page="accounts">PDF View</button><button type="button" class="secondary-button" data-aid-export="pdf" data-capability="imei_download" data-capability-page="accounts">Download PDF</button><button type="button" class="primary-button" data-aid-export="excel" data-capability="imei_download" data-capability-page="accounts">Download Excel</button></div>
    </div>
    <div id="aid-filters" class="aid-filters" hidden>
      ${[['model','Model'],['storage_gb','GB'],['color','Color'],['grade','Final grade'],['stage','Status / stage']].map(([k,label])=>`<label>${label}<select data-aid-filter="${k}" data-capability="search" data-capability-page="accounts"><option value="">All</option></select></label>`).join('')}
      <label>From date<input type="date" data-aid-filter="from_date" data-capability="search" data-capability-page="accounts"></label><label>To date<input type="date" data-aid-filter="to_date" data-capability="search" data-capability-page="accounts"></label>
      <small>Dates apply to the original stock received date (UAE).</small>
    </div>
    <p id="aid-message" role="status" hidden></p><p id="aid-scope" class="aid-scope"></p>
    <div id="aid-summary" class="aid-summary"></div>
    <h3 id="aid-selection" hidden></h3><div id="aid-receipt-detail" hidden></div><div class="aid-table-wrap" hidden><table class="aid-table"><thead><tr>${columns.map(([key,label])=>`<th scope="col"${key?' data-aid-heading="'+key+'"':''}>${key?`<button class="aid-sort" type="button" data-aid-sort="${key}" data-capability="sort" data-capability-page="accounts">${label} <span aria-hidden="true">↕</span></button>`:label}</th>`).join('')}</tr></thead><tbody id="aid-rows"></tbody></table></div>
    <div class="aid-footer" hidden><span id="aid-count">Choose IMEI DATA to load records.</span><div><button id="aid-prev" type="button" class="secondary-button" data-capability="imei_data" data-capability-page="accounts">Previous</button><button id="aid-next" type="button" class="secondary-button" data-capability="imei_data" data-capability-page="accounts">Next</button></div></div>
    <p class="aid-note" hidden>Red rows are returned phones; green rows are entered replacements. S.No follows the current filtered list. Original stock and return history remain available.</p>
    <dialog id="aid-pdf-dialog" aria-labelledby="aid-pdf-title"><div class="aid-pdf-header"><h2 id="aid-pdf-title">IMEI DATA - PDF preview</h2><div><button id="aid-pdf-download" type="button" class="primary-button" data-capability="imei_download" data-capability-page="accounts">Download PDF</button><button id="aid-pdf-close" type="button" class="secondary-button" data-capability="imei_data" data-capability-page="accounts">Close</button></div></div><iframe id="aid-pdf-frame" title="IMEI DATA PDF preview"></iframe><a id="aid-pdf-open" target="_blank" rel="noopener" data-capability="imei_download" data-capability-page="accounts">Open PDF in a new tab</a></dialog>`;

  function message(text = '', error = false) {
    $('#aid-message').textContent = text; $('#aid-message').hidden = !text;
    $('#aid-message').classList.toggle('is-error',error);
  }
  function filters() {
    if (!can('search')) return {};
    const result = {};
    for (const [key,id] of [['supplier_id','aid-supplier'],['batch_id','aid-batch'],['invoice_number','aid-invoice'],['query','aid-search']]) {
      const v = $('#'+id).value.trim(); if (v) result[key] = v;
    }
    for (const input of root.querySelectorAll('[data-aid-filter]')) if (input.value) result[input.dataset.aidFilter] = input.value;
    return result;
  }
  const signature = () => JSON.stringify([filters(),metric,detailOpen,sortKey,direction,offset]);
  async function rpc(name,args = {}) { const r = await client.rpc(name,args); if (r.error) throw r.error; return r.data; }
  function closePdf() {
    if ($('#aid-pdf-dialog').open) $('#aid-pdf-dialog').close();
    $('#aid-pdf-frame').removeAttribute('src'); $('#aid-pdf-open').removeAttribute('href');
    if (pdfUrl) URL.revokeObjectURL(pdfUrl); pdfUrl = ''; pdfFilename = '';
  }
  function controls() {
    const permitted = allowed();
    $('[data-accounts-view="imei"]').hidden = !permitted;
    for (const e of root.querySelectorAll('button,input,select,a')) {
      const cap = e.dataset.capability || 'imei_data';
      if ('disabled' in e) e.disabled = exporting || !permitted || !can(cap);
    }
    $('#aid-prev').disabled = exporting || loading || !permitted || offset === 0;
    $('#aid-next').disabled = exporting || loading || !permitted || !report || offset + 50 >= report.total;
    $('#aid-refresh').disabled = exporting || loading || !permitted;
    root.querySelectorAll('[data-aid-export]').forEach(e=>{e.hidden = !can('imei_download');e.disabled = exporting || loading || !report?.total || !detailOpen || !permitted || !can('imei_download');});
    if (!permitted || !can('imei_download')) closePdf();
    if (!permitted) { root.hidden = true; report = null; generation++; $('#aid-rows').replaceChildren(); $('#aid-summary').replaceChildren(); }
    window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(root);
  }
  function fillSelect(el,items,first,value = el.value) {
    el.replaceChildren(new Option(first,''),...items.map(item=>new Option(item.label,String(item.value))));
    if (value && ![...el.options].some(o=>o.value === value)) el.add(new Option(value,value));
    el.value = value;
  }
  function supplierLabel(row) { return window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(row.supplier_code,row.receipt_quantity ?? row.planned_quantity,row.supplier_name,'Not recorded'); }
  function stockOptions() {
    if (!catalogue) return;
    const supplier = $('#aid-supplier').value, invoice = $('#aid-invoice').value, batch = $('#aid-batch').value;
    const base = catalogue.batches.filter(b=>!supplier || String(b.supplier_id) === supplier);
    fillSelect($('#aid-batch'),base.filter(b=>!invoice || b.invoice_number === invoice).map(b=>({value:b.batch_id,label:[b.batch_number,b.invoice_number,supplierLabel(b)].filter(Boolean).join(' · ')})),'All stock / batches',base.some(b=>String(b.batch_id) === batch && (!invoice || b.invoice_number === invoice)) ? batch : '');
    const invoices = [...new Set(base.filter(b=>!$('#aid-batch').value || String(b.batch_id) === $('#aid-batch').value).map(b=>b.invoice_number).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'en',{numeric:true}));
    fillSelect($('#aid-invoice'),invoices.map(v=>({value:v,label:v})),'All invoices',invoices.includes(invoice) ? invoice : '');
  }
  async function loadCatalogue() {
    const data = await rpc('get_accounts_imei_catalogue_v1');
    if (!data || !Array.isArray(data.suppliers) || !Array.isArray(data.batches)) throw Error('The stock selector could not be verified. Refresh and retry.');
    if (!visible || stopped || !allowed()) return;
    catalogue = data;
    fillSelect($('#aid-supplier'),data.suppliers.map(s=>({value:s.supplier_id,label:window.GREENLOOP_PARTNER_LABEL(s.supplier_code,s.supplier_name,'Not recorded')})),'All suppliers');
    stockOptions();
  }
  function valid(data,complete = false) {
    return data && Array.isArray(data.rows) && data.summary && data.facets && Number.isSafeInteger(data.total) && data.total >= 0 && /^[a-f0-9]{32}$/.test(data.snapshot) && Number.isFinite(Date.parse(data.generated_at)) && (data.receipt_mode || data.summary.total_records === data.total) && (!complete || data.rows.length === data.total) && (data.receipt_mode || (new Set(data.rows.map(r=>r.record_key)).size === data.rows.length && data.rows.every(r=>typeof r.record_key === 'string' && typeof r.returned === 'boolean' && typeof r.return_pending === 'boolean')));
  }
  function selectedStockReceipts(){const f=filters();return(window.GREENLOOP_STOCK?.rows||[]).filter(r=>(!f.batch_id||r.batch_id===f.batch_id)&&(!f.supplier_id||r.supplier_id===f.supplier_id)&&(!f.invoice_number||r.invoice_number===f.invoice_number));}
  function draw() {
    if (!report) return;
    const fields = [['Total records','total_records'],['In company','in_company'],['Ready Stock','ready'],['In process','in_process'],['Exported','exported'],['Returned','returned']];
    $('#aid-summary').innerHTML = fields.map(([label,key])=>cards.button(label,key==='total_records'?'all':key,(report.base_summary||report.summary)[key],detailOpen?metric:null,'imei_data')).join('');
    $('#aid-scope').textContent = [$('#aid-supplier').selectedOptions[0]?.textContent,$('#aid-batch').value ? $('#aid-batch').selectedOptions[0]?.textContent : 'All stock / batches',$('#aid-invoice').value ? 'Invoice '+$('#aid-invoice').value : '',report.filters.from_date ? 'From '+report.filters.from_date : '',report.filters.to_date ? 'To '+report.filters.to_date : '',report.summary.missing_imei ? num(report.summary.missing_imei)+' return records have no recorded IMEI' : ''].filter(Boolean).join(' · ');
    $('#aid-selection').hidden=!detailOpen;$('#aid-selection').textContent=cards.labels[metric]+' — '+num(report.total)+(report.receipt_mode?' receipts':' records');
    root.querySelector('.aid-table-wrap').hidden=!detailOpen||report.receipt_mode;root.querySelector('.aid-footer').hidden=!detailOpen;root.querySelector('.aid-note').hidden=!detailOpen||report.receipt_mode;
    $('#aid-receipt-detail').hidden=!detailOpen||!report.receipt_mode;$('#aid-receipt-detail').innerHTML=detailOpen&&report.receipt_mode?cards.receiptTable(report,offset):'';
    $('#aid-rows').innerHTML = detailOpen&&!report.receipt_mode&&report.rows.length ? report.rows.map((r,i)=>`<tr class="${r.returned?'aid-returned':r.is_replacement?'aid-replacement':r.return_pending?'aid-return-pending':''}" data-record-key="${esc(r.record_key)}" aria-label="${r.returned?'Returned phone':r.is_replacement?'Replacement phone':'Phone'}"><td class="aid-serial">${num(offset+i+1)}</td><td class="aid-imei"><strong>${esc(r.imei || 'Not recorded')}</strong>${!r.imei?'<small>Unentered stock return</small>':''}${r.return_pending?'<small>Return pending</small>':''}</td><td>${esc(r.model || 'Not recorded')}</td><td>${esc(storage(r.storage_gb))}</td><td>${esc(r.color || 'Not recorded')}</td><td>${esc(supplierLabel(r))}</td><td>${esc(r.batch_number || 'Not recorded')}</td><td>${esc(r.invoice_number || 'Not recorded')}</td><td>${esc(receivedDate(r.received_at))}</td></tr>`).join('') : '<tr><td colspan="9" class="aid-empty">No IMEI or return records match this selection.</td></tr>';
    for (const input of root.querySelectorAll('select[data-aid-filter]')) {
      const key = input.dataset.aidFilter, values = [...(report.facets[key] || [])].sort((a,b)=>key==='storage_gb'?Number(a)-Number(b):String(a).localeCompare(String(b),'en',{numeric:true}));
      fillSelect(input,values.map(v=>({value:v,label:key==='storage_gb'?storage(v):v})),'All');
    }
    root.querySelectorAll('[data-aid-heading]').forEach(e=>{const active=e.dataset.aidHeading===sortKey;e.setAttribute('aria-sort',active?direction==='asc'?'ascending':'descending':'none');e.querySelector('span').textContent=active?direction==='asc'?'↑':'↓':'↕';});
    $('#aid-count').textContent = report.total ? `${num(offset+1)}–${num(Math.min(offset+50,report.total))} of ${num(report.total)} records · ${num(report.summary.imeis)} recorded IMEIs` : '0 records';
    $('#aid-updated').textContent = 'Updated '+when(report.generated_at)+' · UAE';
    controls();
    root.querySelector(':scope > [data-stock-balance-summary]')?.remove();if(report.receipt_summary)root.insertAdjacentHTML('afterbegin',window.GREENLOOP_STOCK?.summaryHtml(report.receipt_summary)||'');cards.decorate(root,metric,'imei_data');
  }
  async function load() {
    if (!visible || stopped || !allowed() || exporting) return;
    if(!detailOpen){root.querySelector('.aid-table-wrap').hidden=true;root.querySelector('.aid-footer').hidden=true;root.querySelector('.aid-note').hidden=true;$('#aid-selection').hidden=true;$('#aid-receipt-detail').hidden=true;}
    const ticket = ++generation, sig = signature(); loading = true; report = null; controls(); message('Loading IMEI DATA…');
    $('#aid-rows').innerHTML='<tr><td colspan="9" class="aid-empty">Loading records…</td></tr>';$('#aid-summary').replaceChildren();$('#aid-count').textContent='Loading…';
    try {
      const data = await rpc('get_accounts_card_report_v1',{p_kind:'imei',p_filters:filters(),p_metric:metric,p_summary_only:!detailOpen,p_offset:offset,p_limit:50,p_sort_key:sortKey,p_sort_direction:direction});
      if (ticket !== generation || sig !== signature() || !visible || stopped || !allowed()) return;
      if (!valid(data)) throw Error('The complete report totals could not be verified. Refresh and retry.');
      if (offset && offset >= data.total) { offset=0;return load(); }
      report = data; draw(); message();
    } catch (e) { if (ticket===generation) { report=null;$('#aid-rows').replaceChildren();$('#aid-summary').replaceChildren();$('#aid-count').textContent='Report unavailable';message(e.message || 'IMEI DATA could not load.',true); } }
    finally { if (ticket===generation) {loading=false;controls();} }
  }
  function changed() { if (!can('search') || exporting) return;detailOpen=metric!=='all'||Object.keys(filters()).length>0;offset=0;generation++;closePdf();clearTimeout(searchTimer);searchTimer=setTimeout(load,240); }
  function download(url,filename) { const a=document.createElement('a');a.href=url;a.download=filename;a.dataset.capability='imei_download';a.dataset.capabilityPage='accounts';document.body.append(a);a.click();a.remove(); }
  async function exportReport(kind) {
    if (!allowed() || !can('imei_download') || exporting || loading || !report?.total || !detailOpen) return;
    const snapshot=report.snapshot,sig=signature(),ticket=generation;exporting=true;controls();message('Preparing the complete selected stock…');
    try {
      const data=await rpc('get_accounts_card_report_v1',{p_kind:'imei',p_filters:filters(),p_metric:metric,p_download:true,p_sort_key:sortKey,p_sort_direction:direction,p_expected_snapshot:snapshot});
      if (!valid(data,true)) throw Error('The full selected report could not be verified. No partial file was created.');
      if (sig!==signature() || ticket!==generation || !visible || stopped || !allowed() || !can('imei_download')) return;
      if(data.receipt_mode){await window.GREENLOOP_REPORT_DOWNLOADS.output(kind,cards.receiptReport(data,cards.labels[metric]),()=>sig===signature()&&ticket===generation&&visible&&!stopped&&allowed()&&can('imei_download'),'accounts','imei_download');return;}
      data.selection_label=cards.labels[metric]+' | '+$('#aid-scope').textContent;
      const file=await window.GREENLOOP_ACCOUNTS_IMEI_EXPORT[kind==='excel'?'excel':'pdf'](data);
      if (sig!==signature() || ticket!==generation || !visible || stopped || !allowed() || !can('imei_download')) return;
      const url=URL.createObjectURL(new Blob([file.bytes],{type:kind==='excel'?'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':'application/pdf'}));
      if (kind==='view') { closePdf();pdfUrl=url;pdfFilename=file.filename;$('#aid-pdf-frame').src=url;$('#aid-pdf-open').href=url;$('#aid-pdf-dialog').showModal(); }
      else { download(url,file.filename);setTimeout(()=>URL.revokeObjectURL(url),30000); }
      message(num(data.total)+' records included.');
    } catch (e) { message(e.message || 'The file could not be prepared.',true); }
    finally { exporting=false;controls(); }
  }
  async function activate(next) {
    detailOpen=false;metric='all';offset=0;for(const e of root.querySelectorAll('input,select'))e.value='';clearTimeout(searchTimer);
    root.querySelector('.aid-table-wrap').hidden=true;root.querySelector('.aid-footer').hidden=true;root.querySelector('.aid-note').hidden=true;$('#aid-selection').hidden=true;$('#aid-receipt-detail').hidden=true;
    visible=next==='imei';root.hidden=!visible;
    if (!visible) { generation++;loading=false;closePdf();return; }
    if (!allowed()) { controls();return; }
    message('Loading stock choices…');
    try { await loadCatalogue();if (visible && !stopped) await load(); } catch(e) {message(e.message || 'Stock choices could not load.',true);}
  }
  function clearSensitive() {
    stopped=true;visible=false;generation++;loading=false;clearTimeout(searchTimer);closePdf();report=null;catalogue=null;root.hidden=true;
    $('#aid-rows').replaceChildren();$('#aid-summary').replaceChildren();$('#aid-scope').textContent='';$('#aid-updated').textContent='';
    for(const e of root.querySelectorAll('input,select')) { if(e.tagName==='SELECT')e.replaceChildren(new Option('',''));else e.value=''; }
  }
  async function init(settings) {
    client=settings.client;controls();
    root.addEventListener('click',e=>{const b=e.target.closest('[data-account-card]');if(!b||loading||exporting||!allowed())return;metric=b.dataset.accountCard;detailOpen=true;offset=0;closePdf();load();});
    $('#aid-supplier').addEventListener('change',()=>{$('#aid-batch').value='';$('#aid-invoice').value='';stockOptions();changed();});
    $('#aid-batch').addEventListener('change',()=>{stockOptions();changed();});$('#aid-invoice').addEventListener('change',()=>{stockOptions();changed();});
    root.querySelectorAll('[data-aid-filter]').forEach(e=>e.addEventListener('change',changed));$('#aid-search').addEventListener('input',changed);$('#aid-search').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();clearTimeout(searchTimer);detailOpen=metric!=='all'||Object.keys(filters()).length>0;offset=0;load();}});
    $('#aid-filter-toggle').addEventListener('click',()=>{if(!can('search')||exporting)return;const open=$('#aid-filters').hidden;$('#aid-filters').hidden=!open;$('#aid-filter-toggle').setAttribute('aria-expanded',String(open));});
    $('#aid-clear').addEventListener('click',()=>{if(!can('search')||exporting)return;for(const e of root.querySelectorAll('input,select'))e.value='';detailOpen=false;metric='all';offset=0;sortKey='imei';direction='asc';closePdf();stockOptions();load();});
    $('#aid-refresh').addEventListener('click',async()=>{if(exporting)return;try{await loadCatalogue();await load();}catch(e){message(e.message,true);}});
    $('#aid-prev').addEventListener('click',()=>{if(offset>=50&&!loading){offset-=50;load();}});$('#aid-next').addEventListener('click',()=>{if(report&&offset+50<report.total&&!loading){offset+=50;load();}});
    root.querySelectorAll('[data-aid-sort]').forEach(e=>e.addEventListener('click',()=>{if(!can('sort')||exporting)return;direction=sortKey===e.dataset.aidSort&&direction==='asc'?'desc':'asc';sortKey=e.dataset.aidSort;offset=0;closePdf();load();}));
    root.querySelectorAll('[data-aid-export]').forEach(e=>e.addEventListener('click',()=>exportReport(e.dataset.aidExport)));
    $('#aid-pdf-close').addEventListener('click',closePdf);$('#aid-pdf-download').addEventListener('click',()=>{if(allowed()&&can('imei_download')&&pdfUrl)download(pdfUrl,pdfFilename);});$('#aid-pdf-dialog').addEventListener('cancel',e=>{e.preventDefault();closePdf();});
    document.addEventListener('greenloop:accounts-section',e=>activate(e.detail.view));
    window.addEventListener('greenloop:access-ready',controls);window.addEventListener('greenloop:office-locked',clearSensitive);
    window.addEventListener('pagehide',()=>{stopped=true;generation++;closePdf();});client.auth.onAuthStateChange?.(event=>{if(event==='SIGNED_OUT')clearSensitive();});
  }
  window.GREENLOOP_ACCOUNTS_IMEI={init,isBusy:()=>exporting};
})();
