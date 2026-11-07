/* Shared receipt labels and return/replacement balances; access remains server-side. */
(() => {
 'use strict';
 const allowed=new Set(['overview','stock_received','imei_entry','initial_qc','lab_glass','parts','final_qc','frame_department','ready_stock','export_boxes','stock_exported','ready_stock_journey','imei_search','accounts','supplier_returns','supplier_return_approval','supplier_return_handover','reports']);
 let rows=[],pending=null,stamp=0,scope='',generation=0;
 const one=v=>Array.isArray(v)?v[0]:v,esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),num=v=>v==null?'Not recorded':Number(v||0).toLocaleString('en-GB');
 const base=v=>String(v||'').trim().replace(/-\(\d+\)$/,'');
 const names=()=>window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true;
 function clear(){generation++;rows=[];stamp=0;scope='';pending=null;}
 async function ready(){
  let page=window.GREENLOOP_PAGE_ACCESS?.pageKey;if(!allowed.has(page)&&window.GREENLOOP_CAN?.('view','imei_search'))page='imei_search';if(page==='supplier_returns'&&!window.GREENLOOP_CAN?.('view',page))page=['supplier_return_approval','supplier_return_handover'].find(p=>window.GREENLOOP_CAN?.('view',p))||page;if(!allowed.has(page)||!window.GREENLOOP_CAN?.('view',page))return rows;
  const key=page+':'+names();if(scope===key&&Date.now()-stamp<60000)return rows;if(pending&&scope===key)return pending;
  scope=key;const revision=++generation;
  pending=(async()=>{const{data,error}=await window.GREENLOOP_GET_CLIENT().rpc('get_stock_receipt_catalog_v1',{p_page:page});if(error)throw Error(error.message||'Stock balances unavailable.');if(!Array.isArray(data)||data.some(x=>!x.batch_id||x.received_quantity!==null&&!Number.isSafeInteger(Number(x.received_quantity))||x.balance_quantity!==null&&!Number.isSafeInteger(Number(x.balance_quantity))))throw Error('Stock balances could not be verified.');if(revision===generation){rows=data;stamp=Date.now();window.GREENLOOP_BATCH_DISPLAY?.refresh();}return rows;})().catch(e=>{if(revision===generation){rows=[];stamp=0;}window.dispatchEvent(new CustomEvent('greenloop:stock-unavailable',{detail:{message:e.message}}));return rows;}).finally(()=>{if(revision===generation)pending=null;});
  return pending;
 }
 function resolve(row){
  if(!row||typeof row!=='object')return null;const b=one(row.receiving_batch)||one(row.batch)||{},j=one(row.job)||one(row.work_order)?.job||{},id=row.batch_id||row.receiving_batch_id||b.id||b.batch_id||j.receiving_batch_id;
  if(id){const found=rows.find(x=>String(x.batch_id)===String(id));if(found)return found;}
  const bn=row.batch_number||b.batch_number;if(bn){const found=rows.find(x=>x.batch_number===bn);if(found)return found;}
  const invoice=row.invoice_number||b.invoice_number,code=base(row.supplier_code||one(row.supplier)?.supplier_code);
  const found=rows.filter(x=>(!code||x.supplier_code===code)&&(!invoice||x.invoice_number===invoice));return invoice&&found.length===1?found[0]:null;
 }
 function summary(values){
  const chosen=[...new Map((values||[]).map(x=>typeof x==='string'?rows.find(r=>r.batch_id===x):resolve(x)).filter(Boolean).map(x=>[x.batch_id,x])).values()];
  const roots=chosen.filter(x=>!chosen.some(p=>p.batch_id!==x.batch_id&&p.descendant_ids?.includes(x.batch_id)));
  return roots.reduce((s,r)=>({received:s.received===null||r.received_quantity===null?null:s.received+Number(r.received_quantity),returned:s.returned+Number(r.returned_quantity),replacement_received:s.replacement_received+Number(r.replacement_quantity),balance:s.balance===null||r.balance_quantity===null?null:s.balance+Number(r.balance_quantity),return_pending:s.return_pending+Number(r.return_pending),receipts:s.receipts+1}),{received:0,returned:0,replacement_received:0,balance:0,return_pending:0,receipts:0});
 }
 function label(code,quantity,name,fallback='—'){
  const raw=String(code||'').trim(),clean=base(raw),embedded=raw.match(/-\((\d+)\)$/);
  const qty=embedded?Number(embedded[1]):quantity!==null&&quantity!==undefined&&quantity!==''&&Number.isSafeInteger(Number(quantity))&&Number(quantity)>=0?Number(quantity):null;
  const text=clean+(qty===null?'':`-(${qty})`);return names()&&name?[text,String(name).trim()].filter(Boolean).join(' '):(text||fallback);
 }
 function labelRow(row){const r=resolve(row),s=one(row?.supplier)||{};return label(r?.supplier_code||row?.supplier_code||s.supplier_code,r?.received_quantity??row?.receipt_quantity??row?.planned_quantity??row?.stock_quantity??row?.received_quantity,r?.supplier_name??row?.supplier_name??s.company_name);}
 function scoped(filters={},values=null){
  let selected=rows;const f=filters||{},supplier=f.supplier_id||f.supplier,code=f.supplier_code,batch=f.batch_id||f.receiving_batch_id||f.stock_id,invoice=f.invoice_number||f.invoice;
  if(supplier)selected=selected.filter(r=>r.supplier_id===supplier);if(code)selected=selected.filter(r=>r.supplier_code===base(code));if(batch)selected=selected.filter(r=>r.batch_id===batch||r.batch_number===batch);if(invoice)selected=selected.filter(r=>r.invoice_number===invoice);
  const from=f.from_date||f._from,to=f.to_date||f._to,day=v=>new Date(new Date(v).getTime()+14400000).toISOString().slice(0,10);
  if(from)selected=selected.filter(r=>day(r.received_at)>=from);if(to)selected=selected.filter(r=>day(r.received_at)<=to);
  if(values&&!supplier&&!code&&!batch&&!invoice&&!from&&!to){const found=values.map(resolve).filter(Boolean);if(found.length)return [...new Map(found.map(r=>[r.batch_id,r])).values()];}
  return selected;
 }
 function summaryText(s){return s?`Received stock: ${num(s.received)} | Returned: ${num(s.returned)} | Replacement received: ${num(s.replacement_received)} | Stock balance: ${num(s.balance)}`:'';}
 function enrich(data,context={}){
  window.GREENLOOP_BATCH_DISPLAY?.remember(data);
  const seen=new WeakSet();function visit(v){if(!v||typeof v!=='object'||seen.has(v))return;seen.add(v);if(Array.isArray(v)){v.forEach(visit);return;}const r=resolve(v);
   if(r){v.receipt_metrics={received:r.received_quantity,returned:r.returned_quantity,replacement_received:r.replacement_quantity,balance:r.balance_quantity,return_pending:r.return_pending};v.receipt_quantity=r.received_quantity;if(v.supplier_code)v.supplier_code=label(r.supplier_code,r.received_quantity,null);}
   for(const[key,value]of Object.entries(v))if(key!=='receipt_metrics')visit(value);
  }visit(data);
  const stockReports=new Set(['get_accounts_imei_data_v1','export_accounts_imei_data_v1','get_stock_replacement_data_v1','get_stock_parts_cost_v1','get_stock_grade_analysis_v1','get_stock_batch_report_v1']);
  if(data&&typeof data==='object'&&!Array.isArray(data)&&stockReports.has(context.name)&&!data.receipt_summary){const scope=summary(scoped(context.args?.p_filters||data.filters,context.name==='get_stock_parts_cost_v1'?data.stocks:undefined));if(scope.receipts)data.receipt_summary=scope;}
  return data;
 }
 function summaryHtml(value){
  const s=Array.isArray(value)?summary(value):value;if(!s||!Number.isFinite(Number(s.received)))return '';
  return `<div class="stock-balance-strip" data-stock-balance-summary>${[['Received stock',s.received],['Returned',s.returned],['Replacement received',s.replacement_received],['Stock balance',s.balance]].map(([label,v])=>`<div><span>${label}</span><strong>${esc(num(v))}</strong></div>`).join('')}${Number(s.return_pending)>0?`<small>${num(s.return_pending)} return pending</small>`:''}</div>`;
 }
 function mount(host,values){if(!host)return;host.querySelector(':scope > [data-stock-balance-summary]')?.remove();const s=summary(values);if(s.receipts)host.insertAdjacentHTML('afterbegin',summaryHtml(s));}
 window.GREENLOOP_STOCK={ready,clear,resolve,summary,scoped,summaryText,label,labelRow,enrich,summaryHtml,mount,get rows(){return rows;}};
 window.addEventListener('greenloop:office-locked',clear);window.addEventListener('greenloop:signed-out',clear);window.addEventListener('greenloop:permissions-changed',clear);window.addEventListener('greenloop:workflow-committed',()=>{stamp=0;});document.addEventListener('greenloop:workflow-committed',()=>{stamp=0;});
})();
