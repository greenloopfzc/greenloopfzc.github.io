(() => {
  'use strict';
  const $ = s => document.querySelector(s);
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const value = v => esc(v === null || v === undefined || v === '' ? '—' : v);
  const date = v => v ? new Date(v).toLocaleString('en-GB', {timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'numeric',minute:'2-digit',hour12:true}) : 'Not recorded';
  let context, customers = [], namesAllowed = false, view = 'verify', offset = 0, total = 0;
  let query = {from:null,to:null,search:null};
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
  const supplierColumns = [['Supplier','supplier_name'],['Code','supplier_code'],['Invoice / Receipt','invoice_number'],['Received · UAE','received_at'],['Model','model'],['GB','storage_gb'],['Color','color'],['Received','received'],['In company','in_company'],['Ready','ready'],['In process','in_process'],['Exported','exported'],['Returned','returned']];
  const customerColumns = [['Customer','customer_name'],['Customer code','customer_code'],['Exported · UAE','exported_at'],['Box','box_number'],['Model','model'],['GB','storage_gb'],['Color','color'],['Grade','final_grade'],['Qty','quantity'],['Supplier','supplier_name'],['Supplier code','supplier_code'],['Invoice','invoice_number'],['Stock received · UAE','received_at']];
  function table(data) {
    const columns = view === 'supplier' ? supplierColumns : customerColumns;
    if (!data.rows.length) return '<p class="box-empty">No stock found for these filters.</p>';
    return `<div class="box-table-wrap"><table class="box-table accounts-stock-table"><thead><tr>${columns.map(([label])=>`<th scope="col">${esc(label)}</th>`).join('')}</tr></thead><tbody>${data.rows.map(row=>'<tr>'+columns.map(([,key])=>{
      let content = key.endsWith('_at') ? value(date(row[key])) : value(key === 'invoice_number' ? row.invoice_number || row.batch_number : row[key]);
      if (key === 'in_process' && row.awaiting_imei > 0) content += `<small>${value(row.awaiting_imei)} awaiting IMEI</small>`;
      if (key === 'box_number' && row.state === 'legacy') content += '<small>Historical</small>';
      return `<td>${content}</td>`;
    }).join('')+'</tr>').join('')}</tbody></table></div>`;
  }
  function pagination() {
    $('#accounts-stock-prev').disabled = context.isBusy() || offset === 0;
    $('#accounts-stock-next').disabled = context.isBusy() || offset + 50 >= total;
  }
  async function loadStock() {
    if (view === 'verify' || context.isBusy()) return;
    context.lock(true);
    const msg = $('#accounts-stock-message');
    msg.textContent = ''; msg.classList.remove('is-visible');
    try {
      const data = await rpc('get_accounts_stock_v1',{p_kind:view,p_date_from:query.from,p_date_to:query.to,p_search:query.search,p_offset:offset,p_limit:50});
      total = data.total;
      $('#accounts-stock-list').innerHTML = table(data);
      const metrics = view === 'supplier' ? [['Received','received'],['In company','in_company'],['Ready','ready'],['In process','in_process'],['Exported','exported'],['Returned','returned']] : [['Exported phones','exported']];
      $('#accounts-stock-totals').innerHTML = metrics.map(([label,key])=>`<div><span>${esc(label)}</span><strong>${value(data.totals[key] || 0)}</strong></div>`).join('');
      $('#accounts-stock-count').textContent = total ? `${offset+1}–${Math.min(offset+50,total)} of ${total} rows` : '0 rows';
      $('#accounts-stock-updated').textContent = 'Updated '+date(new Date())+' · Refresh every 30 sec';
    } catch (e) {
      total = 0;
      $('#accounts-stock-list').innerHTML = '';
      $('#accounts-stock-totals').innerHTML = '';
      $('#accounts-stock-count').textContent = '';
      $('#accounts-stock-updated').textContent = 'Update unavailable';
      msg.textContent = e.message || 'Stock could not be loaded.'; msg.classList.add('is-visible');
    } finally { context.lock(false); pagination(); }
  }
  function showView(next) {
    if (context.isBusy() || !['verify','supplier','customer'].includes(next)) return;
    view = next;
    document.querySelectorAll('[data-accounts-view]').forEach(b=>{const active=b.dataset.accountsView===view;b.classList.toggle('is-active',active);b.setAttribute('aria-pressed',String(active));});
    $('#accounts-verify-panel').hidden = view !== 'verify';
    $('#accounts-stock-panel').hidden = view === 'verify';
    if (view === 'verify') return;
    offset = 0; query = {from:null,to:null,search:null}; $('#accounts-stock-filter').reset();
    const supplier = view === 'supplier';
    $('#accounts-stock-title').textContent = supplier ? 'Supplier Stock' : 'Customer Stock';
    $('#accounts-date-from-label').firstChild.textContent = supplier ? 'Received from · UAE' : 'Exported from · UAE';
    $('#accounts-date-to-label').firstChild.textContent = supplier ? 'Received to · UAE' : 'Exported to · UAE';
    $('#accounts-stock-filter').elements.search.placeholder = supplier ? 'Supplier, invoice, model, color…' : 'Customer, supplier, box, invoice, model…';
    $('#accounts-stock-note').textContent = supplier ? 'All suppliers in one table. In company = Ready + In process. In process includes stock awaiting IMEI entry, Box Entry and Accounts verification. Returned phones are shown separately. Dates filter the original receipt.' : 'All customers in one table. Exports appear after Accounts verification. Older boxes show the recorded customer, or Not recorded if unavailable. Totals cover all matching rows.';
    loadStock();
  }
  async function init(settings) {
    context = settings;
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
    $('#accounts-stock-clear').addEventListener('click',()=>{if(!context.isBusy())showView(view);});
    $('#accounts-stock-refresh').addEventListener('click',loadStock);
    $('#accounts-stock-prev').addEventListener('click',()=>{if(!context.isBusy() && offset>0){offset-=50;loadStock();}});
    $('#accounts-stock-next').addEventListener('click',()=>{if(!context.isBusy() && offset+50<total){offset+=50;loadStock();}});
    window.setInterval(()=>{if(!document.hidden)loadStock();},30000);
  }
  window.GREENLOOP_ACCOUNTS = {init,picker,reloadCustomers};
})();
