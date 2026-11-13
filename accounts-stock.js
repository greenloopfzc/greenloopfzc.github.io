(() => {
  'use strict';
  const $ = s => document.querySelector(s);
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const value = v => esc(v === null || v === undefined || v === '' ? '—' : v);
  const date = v => v ? new Date(v).toLocaleString('en-GB', {timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}) : 'Not recorded';
  let context, customers = [], namesAllowed = false, view = 'verify', offset = 0, total = 0;
  let query = {from:null,to:null,search:null},stockGeneration=0,detailOpen=false,metric='all',snapshot=null;
  const cards=window.GREENLOOP_ACCOUNTS_CARDS;
  function stockArgs(){const sort=stockFilters.sortArgs();return {p_kind:view,p_filters:stockFilters.query(),p_metric:metric,p_sort_key:sort.p_sort_by||null,p_sort_direction:sort.p_sort_direction||'asc',p_limit:50};}
  function hideDetails(){detailOpen=false;metric='all';offset=0;$('#accounts-stock-details').hidden=true;downloads.close();}
  const mayReadStock=kind=>window.GREENLOOP_CAN?.('view','accounts')===true&&window.GREENLOOP_CAN?.(kind+'_stock','accounts')===true;
  async function rpc(name, args = {}) {
    const {data,error} = await context.client.rpc(name,args);
    if (error) throw error;
    return data;
  }
  const customerLabel = c => c.name ? `${c.name} · ${c.code}` : c.code;
  function options(selected) {
    return '<option value="">Select customer</option>' + customers.map(c => `<option value="${esc(c.id)}"${c.id === selected ? ' selected' : ''}>${esc(customerLabel(c))}</option>`).join('');
  }
  function picker(box) {
    if (!context?.canEdit || box.state !== 'accounts') return '';
    return `<div class="accounts-customer-picker"><label for="box-customer">Customer <span>(required)</span></label><div class="accounts-customer-controls"><select id="box-customer" required data-entry-only>${options(box.customer_id)}</select>${namesAllowed ? '<button type="button" class="secondary-button" data-add-box-customer data-entry-only aria-label="Add customer">+</button><button type="button" class="secondary-button accounts-remove" data-remove-box-customer data-entry-only aria-label="Remove customer from dropdown">−</button>' : ''}</div></div>`;
  }
  async function reloadCustomers() { customers = await rpc('get_accounts_customers_v1'); }
  async function manageCustomer(remove) {
    if (context.isBusy() || !context.canEdit || !namesAllowed) return;
    const select = $('#box-customer');
    let name, id;
    if (remove) {
      id = select.value;
      if (!id) { select.reportValidity(); return; }
      if (!window.confirm(`Remove ${select.selectedOptions[0].textContent} from the customer dropdown? Existing export records will be kept.`)) return;
    } else {
      name = window.prompt('Customer name');
      if (name === null) return;
      name = name.trim();
      if (!name || name.length > 160) { context.notice('Enter a customer name of 1 to 160 characters.',true); return; }
    }
    context.lock(true);
    try {
      if (remove) await rpc('remove_accounts_customer_v1',{p_customer_id:id});
      else id = await rpc('add_accounts_customer_v1',{p_name:name});
      await reloadCustomers();
      select.innerHTML = options(remove ? '' : id);
      context.notice(remove ? 'Customer removed from the dropdown. Existing exports are preserved.' : 'Customer added and selected.');
    } catch (e) { context.notice(e.message || 'Customer could not be saved.',true); }
    finally { context.lock(false); }
  }
  const supplierColumns = [['Supplier','supplier_name'],['Code','supplier_code'],['Stock/Batch No','batch_number'],['Invoice / Receipt','invoice_number'],['Received · UAE','received_at'],['Model','model'],['GB','storage_gb'],['Color','color'],['Received','received'],['In company','in_company'],['Ready','ready'],['In process','in_process'],['Exported','exported'],['Returned','returned']];
  const customerColumns = [['Customer','customer_name'],['Customer code','customer_code'],['Exported · UAE','exported_at'],['Box','box_number'],['Model','model'],['GB','storage_gb'],['Color','color'],['Grade','final_grade'],['Qty','quantity'],['Supplier','supplier_name'],['Supplier code','supplier_code'],['Stock/Batch No','batch_number'],['Invoice','invoice_number'],['Stock received · UAE','received_at']];
  function columnsFor(data) { return (view==='supplier'?supplierColumns:customerColumns).filter(([,key])=>data.names_allowed||!['supplier_name','customer_name'].includes(key)); }
  function table(data) {
    const columns=columnsFor(data),numeric=view==='supplier'?new Set(['received','in_company','ready','in_process','exported','returned']):new Set(['quantity']);
    const first=columns.findIndex(([,key])=>numeric.has(key));
    const footer=`<tfoot><tr class="accounts-stock-total"><th scope="row" colspan="${first+1}">Total · All matching records</th>${columns.slice(first).map(([,key])=>`<td>${numeric.has(key)?value(Number(data.totals[key]||0).toLocaleString('en-GB')):''}</td>`).join('')}</tr></tfoot>`;
    const rows=data.rows.map((row,index)=>'<tr><td>'+String(offset+index+1)+'</td>'+columns.map(([,key])=>{
      let content=key.endsWith('_at')?value(date(row[key])):key==='batch_number'?value(window.GREENLOOP_BATCH_LABEL?.(row.batch_number,row)||row.batch_number):value(key==='invoice_number'?row.invoice_number||row.batch_number:row[key]);
      if(key==='in_process'&&row.awaiting_imei>0)content+=`<small>${value(row.awaiting_imei)} awaiting IMEI</small>`;
      if(key==='box_number'&&row.state==='legacy')content+='<small>Historical</small>';
      return `<td>${content}</td>`;
    }).join('')+'</tr>').join('');
    return `<div class="box-table-wrap"><table class="box-table accounts-stock-table"><thead><tr><th scope="col">S.No</th>${columns.map(([label])=>`<th scope="col">${esc(label)}</th>`).join('')}</tr></thead><tbody>${rows||`<tr><td colspan="${columns.length+1}" class="box-empty">No stock found for these filters.</td></tr>`}</tbody>${footer}</table></div>`;
  }

  const downloads=window.GREENLOOP_REPORT_DOWNLOADS;
  async function exportStock(kind){
    const selected=view,token=stockGeneration;
    const allowed=()=>stockGeneration===token&&view===selected&&mayReadStock(selected)&&window.GREENLOOP_CAN?.('print','accounts')===true;
    if(context.isBusy()||!allowed()||!total||!detailOpen)return;
    const args=stockArgs();
    context.lock(true);stockFilters.setBusy(true);
    try{
      const data=await rpc('get_accounts_card_report_v1',{...args,p_download:true,p_expected_snapshot:snapshot});
      if(!allowed()||data.rows.length!==data.total)throw Error('The complete card data could not be verified.');
      if(data.receipt_mode){await downloads.output(kind,cards.receiptReport(data,cards.labels[metric]),allowed,'accounts','print');return;}
      window.GREENLOOP_BATCH_DISPLAY?.remember(data);
      const columns=columnsFor({...data,names_allowed:data.names_allowed&&window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true});
      const report={title:(selected==='supplier'?'Supplier Stock':'Customer Stock')+' - '+cards.labels[metric],subtitle:Object.entries(args.p_filters).filter(([,v])=>v).map(([k,v])=>k.replace(/^_/,'')+': '+v).join(' | ')||'All matching stock',headers:['S.No',...columns.map(([h])=>h)],rows:data.rows.map((r,i)=>[i+1,...columns.map(([,k])=>k.endsWith('_at')?date(r[k]):k==='batch_number'?window.GREENLOOP_BATCH_LABEL?.(r.batch_number,r)||r.batch_number:k==='invoice_number'?r.invoice_number||r.batch_number:r[k])])};
      const numeric=selected==='supplier'?['received','in_company','ready','in_process','exported','returned']:['quantity'];
      report.subtitle+=' | '+(window.GREENLOOP_STOCK?.chamanText(data.chaman_summary)||'');
      report.subtitle+=' | '+cards.stockText(data.stock_summary);
      report.subtitle+=' | '+numeric.map(k=>k.replace(/_/g,' ')+': '+Number(data.totals[k]||0)).join(' | ');
      await downloads.output(kind,report,allowed,'accounts','print');
    }catch(e){const msg=$('#accounts-stock-message');msg.textContent=e.message;msg.classList.add('is-visible');}
    finally{context.lock(false);stockFilters.setBusy(false);pagination();}
  }
  function pagination() {
    $('#accounts-stock-downloads').querySelectorAll('button').forEach(b=>b.disabled=context.isBusy()||!detailOpen||!total);
    $('#accounts-stock-prev').disabled = context.isBusy() || offset === 0;
    $('#accounts-stock-next').disabled = context.isBusy() || offset + 50 >= total;
  }
  const stockFilters=window.GREENLOOP_FILTERS.get('accounts-record-filters',{
    before:$('#accounts-stock-filter'),sortTarget:'#accounts-stock-list',dateKey:'received_at',dateLabel:'Received / exported',
    fields:[['supplier_name','Supplier name'],['supplier_code','Supplier code'],['batch_number','Stock/Batch No'],['invoice_number','Invoice'],['customer_name','Customer name'],['customer_code','Customer code'],['model','Model'],['storage_gb','GB'],['color','Color'],['final_grade','Grade']],
    onChange:()=>{offset=0;detailOpen=metric!=='all'||Object.values(stockFilters.query()).some(Boolean);return loadStock();}
  });
  for(const key of ['supplier_name','customer_name'])stockFilters.controls.get(key).closest('label').hidden=true;
  $('#accounts-stock-filter').hidden=true;
  stockFilters.bar.querySelector('.table-filter-actions').append($('#accounts-stock-refresh'));
  async function loadStock() {
    if (!context || view === 'verify' || view === 'imei' || context.isBusy() || !mayReadStock(view)) return;
    const token=++stockGeneration,requestedView=view;
    $('#accounts-stock-details').hidden=!detailOpen;
    context.lock(true); stockFilters.setBusy(true);
    const msg = $('#accounts-stock-message');
    msg.textContent = ''; msg.classList.remove('is-visible');
    try {
      const data = await rpc('get_accounts_card_report_v1',{...stockArgs(),p_offset:offset,p_summary_only:!detailOpen});
      if(token!==stockGeneration||requestedView!==view||!mayReadStock(requestedView))return;
      if(!Array.isArray(data.rows)||!data.totals||!Number.isSafeInteger(Number(data.total)))throw new Error('Stock report could not be verified.');
      for(const key of ['supplier_name','customer_name'])stockFilters.controls.get(key).closest('label').hidden=!data.names_allowed||(key==='customer_name'&&view==='supplier');
      stockFilters.setSortFields(data.receipt_mode?[]:columnsFor(data).map(([label,key])=>[key,label,key.endsWith('_at')?'date':undefined]));
      window.GREENLOOP_BATCH_DISPLAY?.remember(data);
      stockFilters.externalFilters([{label:'Card',value:detailOpen?cards.labels[metric]:'',clear:()=>{hideDetails();return loadStock();}}]);
      stockFilters.result(data);
      total = data.total;
      snapshot=data.snapshot;$('#accounts-stock-details').hidden=!detailOpen;
      $('#accounts-stock-list').innerHTML=detailOpen?(data.receipt_mode?cards.receiptTable(data,offset):table(data)):'';
      $('#accounts-stock-selection').textContent=cards.labels[metric]+' — '+total+(data.receipt_mode?' receipts':' matching records');
      $('#accounts-stock-receipts').innerHTML=view==='supplier'?(window.GREENLOOP_STOCK?.chamanHtml(data.chaman_summary)||''):'';
      $('#accounts-stock-downloads').querySelectorAll('button').forEach(b=>b.disabled=!detailOpen||!total);
      const metrics = view === 'supplier' ? [['Received','received'],['In company','in_company'],['Ready','ready'],['In process','in_process'],['Exported','exported'],['Returned','returned']] : [['Exported phones','exported']];
      $('#accounts-stock-totals').innerHTML = view==='supplier'?cards.stockCards(data.stock_summary,detailOpen?metric:null,'supplier_stock'):metrics.map(([label,key])=>cards.button(label,key,(data.base_totals||data.totals)[key]||0,detailOpen?metric:null,'customer_stock')).join('');
      $('#accounts-stock-count').textContent = total ? `${offset+1}–${Math.min(offset+50,total)} of ${total} rows` : '0 rows';
      $('#accounts-stock-updated').textContent = 'Updated '+date(new Date())+' · Refresh every 30 sec';
    } catch (e) {
      total = 0;
      $('#accounts-stock-receipts').replaceChildren();
      $('#accounts-stock-list').innerHTML = '';
      $('#accounts-stock-totals').innerHTML = '';
      $('#accounts-stock-count').textContent = '';
      $('#accounts-stock-updated').textContent = 'Update unavailable';
      msg.textContent = e.message || 'Stock could not be loaded.'; msg.classList.add('is-visible');
    } finally { context.lock(false); stockFilters.setBusy(false); pagination(); }
  }
  function showView(next) {
    if (context.isBusy() || window.GREENLOOP_ACCOUNTS_IMEI?.isBusy() || !['verify','supplier','customer','imei'].includes(next)) return;
    if(['supplier','customer'].includes(next)&&!mayReadStock(next))return;
    hideDetails();stockGeneration++;view = next;
    document.querySelectorAll('[data-accounts-view]').forEach(b=>{const active=b.dataset.accountsView===view;b.classList.toggle('is-active',active);b.setAttribute('aria-pressed',String(active));});
    $('#accounts-verify-panel').hidden = view !== 'verify';
    $('#accounts-stock-panel').hidden = view === 'verify' || view === 'imei';
    document.dispatchEvent(new CustomEvent('greenloop:accounts-section',{detail:{view}}));
    if (view === 'verify' || view === 'imei') return;
    offset = 0; query = {from:null,to:null,search:null}; $('#accounts-stock-filter').reset();
    const supplier = view === 'supplier';
    stockFilters.setSortFields((supplier ? supplierColumns : customerColumns).map(([label,key])=>[key,label,key.endsWith('_at')?'date':undefined]));
    for (const key of ['_from', '_to']) stockFilters.controls.get(key).title = supplier ? 'Stock received date range' : 'Exported date range';
    for(const key of ['supplier_name','customer_name'])stockFilters.controls.get(key).closest('label').hidden=true;
    stockFilters.controls.get('customer_code').closest('label').hidden=supplier;
    stockFilters.controls.get('final_grade').closest('label').hidden=supplier;
    $('#accounts-stock-title').textContent = supplier ? 'Supplier Stock' : 'Customer Stock';
    $('#accounts-stock-downloads').innerHTML=downloads.buttons('data-stock-download','accounts','print');
    $('#accounts-date-from-label').firstChild.textContent = 'From date';
    $('#accounts-date-to-label').firstChild.textContent = 'To date';
    $('#accounts-stock-filter').elements.search.placeholder = supplier ? 'Supplier, batch, invoice, model, color…' : 'Customer, supplier, batch, box, invoice, model…';
    $('#accounts-stock-note').textContent = supplier ? 'All suppliers in one table. In company = Ready + In process. In process includes stock awaiting IMEI entry, Box Entry and Accounts verification. Returned phones are shown separately. Dates filter the original receipt.' : 'All customers in one table. Exports appear after Accounts verification. Older boxes show the recorded customer, or Not recorded if unavailable. Totals cover all matching rows.';
    stockFilters.panel.hidden=true;stockFilters.bar.querySelector('.table-filter-toggle').setAttribute('aria-expanded','false');
    stockFilters.clear();
  }
  async function init(settings) {
    context = settings;
    $('#accounts-stock-panel').addEventListener('click',e=>{const b=e.target.closest('[data-account-card]');if(!b||context.isBusy()||!mayReadStock(view))return;metric=b.dataset.accountCard;detailOpen=true;offset=0;downloads.close();loadStock();});
    stockFilters.bar.querySelectorAll('.table-filter-panel-actions button').forEach(b=>{if(b.textContent==='Clear filters')b.classList.add('table-filter-clear');});
    stockFilters.bar.addEventListener('click',e=>{if(e.target.closest('.table-filter-clear'))hideDetails();},true);
    $('#accounts-stock-downloads').addEventListener('click',e=>{const b=e.target.closest('[data-stock-download]');if(b)exportStock(b.dataset.stockDownload);});
    await window.GREENLOOP_ACCOUNTS_IMEI.init(settings);
    if (context.canEdit) {
      namesAllowed = await rpc('get_my_partner_name_access') === true;
      await reloadCustomers();
    }
    $('#box-queue-app').addEventListener('click',e=>{
      const b=e.target.closest('button'); if (!b || context.isBusy()) return;
      if (b.dataset.accountsView) showView(b.dataset.accountsView);
      else if (b.hasAttribute('data-add-box-customer')) manageCustomer(false);
      else if (b.hasAttribute('data-remove-box-customer')) manageCustomer(true);
    });
    $('#accounts-stock-filter').addEventListener('submit',e=>{
      e.preventDefault(); if (context.isBusy()) return;
      const f=e.currentTarget;query={from:f.elements.from.value || null,to:f.elements.to.value || null,search:f.elements.search.value.trim() || null};offset=0;loadStock();
    });
    $('#accounts-stock-clear').addEventListener('click',()=>{if(!context.isBusy()){hideDetails();query={from:null,to:null,search:null};$('#accounts-stock-filter').reset();stockFilters.clear();}});
    $('#accounts-stock-refresh').addEventListener('click',loadStock);
    $('#accounts-stock-prev').addEventListener('click',()=>{if(!context.isBusy() && offset>0){offset-=50;loadStock();}});
    $('#accounts-stock-next').addEventListener('click',()=>{if(!context.isBusy() && offset+50<total){offset+=50;loadStock();}});
    window.setInterval(()=>{if(!document.hidden)loadStock();},30000);
  }
  function clearStock(){
    hideDetails();stockGeneration++;$('#accounts-stock-list').replaceChildren();$('#accounts-stock-totals').replaceChildren();$('#accounts-stock-receipts').replaceChildren();$('#accounts-stock-count').textContent='';total=0;
    for(const key of ['supplier_name','customer_name']){const input=stockFilters.controls.get(key);input.replaceChildren(new Option('All',''));input.closest('label').hidden=true;}
    stockFilters.clear();
  }
  for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,clearStock);
  window.GREENLOOP_ACCOUNTS = {init,picker,reloadCustomers};
})();
