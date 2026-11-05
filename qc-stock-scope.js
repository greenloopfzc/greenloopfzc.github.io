/* Explicit stock selection for QC work trays. No save/transfer is automatic. */
(() => {
 'use strict';
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function attach({host,stage,client,load,blocked=()=>false}){
  const panel=document.createElement('section');panel.className='qc-stock-scope';panel.setAttribute('aria-label','Choose QC stock');
  panel.innerHTML='<label>Supplier<select data-qcs-supplier data-capability="search" data-capability-page="initial_qc"><option value="">All suppliers</option></select></label><label>Stock / Batch<select data-qcs-batch data-capability="search" data-capability-page="initial_qc"><option value="">All stocks / batches</option></select></label><label>Invoice<select data-qcs-invoice data-capability="search" data-capability-page="initial_qc"><option value="">All invoices</option></select></label><div class="qc-stock-actions"><button type="button" class="secondary-button" data-qcs-clear data-capability="search" data-capability-page="initial_qc">Clear</button><button type="button" class="primary-button" data-qcs-load data-capability="entry" data-capability-page="initial_qc">Load selected stock</button><small data-qcs-status role="status">Choose a supplier, stock or invoice.</small></div>';
  host.after(panel);
  const supplier=panel.querySelector('[data-qcs-supplier]'),batch=panel.querySelector('[data-qcs-batch]'),invoice=panel.querySelector('[data-qcs-invoice]'),status=panel.querySelector('[data-qcs-status]'),button=panel.querySelector('[data-qcs-load]');
  let catalog=[],selection={},generation=0,loading=false,stopped=false;
  const can=cap=>!stopped&&window.GREENLOOP_CAN?.(cap,'initial_qc')===true;
  const filters=()=>Object.fromEntries(Object.entries(selection).filter(([,v])=>v));
  const message=(text,error=false)=>{status.textContent=text;status.classList.toggle('is-error',error);};
  function sync(){for(const e of panel.querySelectorAll('select,button'))e.disabled=loading||!can(e.dataset.capability||'search');button.disabled=loading||!can('entry')||!can('search')||!Object.keys(filters()).length;}
  function options(){
   const suppliers=[...new Map(catalog.map(r=>[r.supplier_id,r])).values()];
   supplier.innerHTML='<option value="">All suppliers</option>'+suppliers.map(r=>{const code=String(r.supplier_code||'').replace(/-\(\d+\).*$/,'');const label=code+(window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true&&r.supplier_name?' '+r.supplier_name:'');return `<option value="${esc(r.supplier_id)}">${esc(label)}</option>`;}).join('');supplier.value=selection.supplier_id||'';
   const stocks=catalog.filter(r=>!selection.supplier_id||r.supplier_id===selection.supplier_id);
   batch.innerHTML='<option value="">All stocks / batches</option>'+stocks.map(r=>`<option value="${esc(r.batch_id)}">${esc(r.batch_number||'Stock')} · ${esc(window.GREENLOOP_STOCK.label(r.supplier_code,r.received_quantity,r.supplier_name))}</option>`).join('');batch.value=selection.batch_id||'';
   invoice.innerHTML='<option value="">All invoices</option>'+[...new Set(stocks.map(r=>r.invoice_number).filter(Boolean))].map(v=>`<option value="${esc(v)}">${esc(v)}</option>`).join('');invoice.value=selection.invoice_number||'';sync();
  }
  async function rpc(args){const{data,error}=await client.rpc('get_qc_stock_selection_v1',{p_stage:stage,p_filters:filters(),...args});if(error)throw error;if(!data||!Array.isArray(data.rows)||!Number.isSafeInteger(Number(data.total))||Number(data.total)<0)throw Error('Stock selection could not be verified.');return data;}
  async function refreshCount(){const ticket=++generation;if(!can('search')||!Object.keys(filters()).length){message('Choose a supplier, stock or invoice.');sync();return;}message('Checking pending phones…');try{const r=await rpc({p_offset:0,p_limit:1});if(ticket!==generation||stopped)return;message(`${r.total} phone(s) ${stage==='issuance'?'awaiting Issuance':'waiting for Initial QC'}`);}catch(e){if(ticket===generation&&!stopped)message(e.message||'Stock count could not load.',true);}sync();}
  panel.addEventListener('change',e=>{
   if(loading||!can('search'))return;
   if(e.target===supplier)selection={supplier_id:supplier.value};
   if(e.target===batch){selection.batch_id=batch.value;const r=catalog.find(r=>r.batch_id===batch.value);if(r){selection.supplier_id=r.supplier_id;selection.invoice_number=r.invoice_number||'';}else selection.invoice_number='';}
   if(e.target===invoice){selection.invoice_number=invoice.value;const matches=catalog.filter(r=>r.invoice_number===invoice.value&&(!selection.supplier_id||r.supplier_id===selection.supplier_id));if(matches.length===1){selection.batch_id=matches[0].batch_id;selection.supplier_id=matches[0].supplier_id;}else selection.batch_id='';}
   options();void refreshCount();
  });
  panel.querySelector('[data-qcs-clear]').addEventListener('click',()=>{if(loading||!can('search'))return;selection={};options();void refreshCount();});
  button.addEventListener('click',async()=>{
   if(loading||!can('entry')||!can('search')||!Object.keys(filters()).length)return;
   if(blocked()){message('Finish the current save or edit before loading stock.',true);return;}
   loading=true;sync();const ticket=++generation;message('Loading selected stock…');
   try{
    const imeis=[],seen=new Set();let offset=0,total=1;
    while(offset<total){const r=await rpc({p_offset:offset,p_limit:500});if(ticket!==generation||!can('entry')||!can('search'))return;total=Number(r.total);if(!r.rows.length&&offset<total)throw Error('The pending queue changed. Try Load again.');for(const row of r.rows){if(!/^\d{15}$/.test(row.imei)||seen.has(row.imei))throw Error('The pending queue changed. Try Load again.');seen.add(row.imei);imeis.push(row.imei);}offset+=r.rows.length;message(`Preparing ${offset} of ${total} phones…`);}
    if(!imeis.length){message('No pending phones match this stock. The current tray is unchanged.');return;}
    if(blocked())throw Error('Finish the current save or edit before loading stock.');
    await load(imeis);if(ticket===generation&&!stopped)message(`${total} phone(s) in the selected stock queue. Review the tray before saving.`);
   }catch(e){if(ticket===generation&&!stopped)message(e.message||'Selected stock could not load.',true);}
   finally{loading=false;sync();}
  });
  async function refresh(){const ticket=++generation;catalog=[];options();try{await window.GREENLOOP_STOCK.ready();if(stopped||ticket!==generation)return;catalog=window.GREENLOOP_STOCK.rows||[];options();void refreshCount();}catch(e){if(ticket===generation)message(e.message||'Stock options could not load.',true);}}
  const stop=()=>{stopped=true;++generation;catalog=[];selection={};options();message('Access ended. Reload after signing in.');};
  window.addEventListener('greenloop:office-locked',stop);window.addEventListener('pagehide',stop);window.addEventListener('greenloop:permissions-changed',()=>{++generation;catalog=[];selection={};options();if(can('view'))void refresh();else stop();});
  void refresh();return{refresh,refreshCount,panel,hasSelection:()=>Object.keys(filters()).length>0,load:()=>button.click(),get busy(){return loading;}};
 }
 window.GREENLOOP_QC_STOCK_SCOPE={attach};
})();
