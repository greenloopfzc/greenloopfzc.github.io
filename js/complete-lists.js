/* Complete permitted lists on one page; transport pages remain bounded. */
(function(root){
 'use strict';
 const sources=new Set(['get_accounts_imei_data_v1','get_lab_overdue_v1','get_stock_batch_report_v1','get_sorted_filter_records_v1','get_sorted_filter_records_v2','get_b_dept_report_v1','get_box_status_v1','get_manual_damage_management_audit_v1','get_parts_batch_queue_v1','get_parts_batch_returns_v1','get_ready_stock_imeis_v1','get_closing_stock_entries_v1','get_period_stock_dates_v1','get_period_stock_report_v1','get_entered_production_report_v1','get_last_day_production_v1','get_suspicious_alerts_v1','get_sorted_login_activity_v1','get_login_activity_v1','get_search_receipt_returns_v1','search_greenloop_records_v1','get_restricted_scope_options_v1']);
 let accessEpoch=0;
 for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed','pagehide'])root.addEventListener?.(event,()=>accessEpoch++);
 const count=d=>{for(const key of ['total','record_count','total_count','count'])if(d[key]!==undefined&&Number.isSafeInteger(Number(d[key])))return Number(d[key]);return null;};
 async function read(rpc,name,args={},other=[]){
  if(!sources.has(name)||name==='search_greenloop_records_v1'&&root.GREENLOOP_PAGE_ACCESS?.pageKey!=='imei_search'||args.p_offset!==0||args.p_limit===1||args.p_download||args.p_export)return rpc(name,args,...other);
  const epoch=accessEpoch,first=await rpc(name,args,...other);
  if(first.error||!first.data)return first;
  const array=Array.isArray(first.data),base=array?first.data[0]:first.data;
  const rowKey=Array.isArray(base?.rows)?'rows':Array.isArray(base?.items)?'items':null;
  if(!rowKey)return first;
  const total=count(base),rows=[...base[rowKey]],size=args.p_limit||Math.max(1,rows.length),snapshot=base.snapshot;
  let more=total!==null?rows.length<total:base.has_more===true,last=base;
  while(more){
   if(epoch!==accessEpoch)return{data:null,error:{code:'42501',message:'Access changed while loading. Reload after signing in.'}};
   if(!last[rowKey].length)return{data:null,error:{code:'40001',message:'The list changed while loading. Refresh and retry.'}};
   const response=await rpc(name,{...args,p_offset:rows.length},...other);
   if(response.error)return response;
   const next=Array.isArray(response.data)?response.data[0]:response.data;
   if(!next||!Array.isArray(next[rowKey])||count(next)!==total||(snapshot!==undefined&&next.snapshot!==snapshot))return{data:null,error:{code:'40001',message:'The records changed while loading. Refresh to load a consistent list.'}};
   rows.push(...next[rowKey]);last=next;more=total!==null?rows.length<total:next.has_more===true;
   await new Promise(resolve=>setTimeout(resolve,0));
  }
  if(epoch!==accessEpoch)return{data:null,error:{code:'42501',message:'Access changed while loading.'}};
  if(total!==null&&rows.length!==total)return{data:null,error:{code:'40001',message:'The complete list could not be verified. Refresh and retry.'}};
  const data={...base,[rowKey]:rows,offset:0,has_more:false,next_offset:Math.max(rows.length,Number(base.next_offset)||size),complete_list:true};
  return{...first,data:array?[data]:data};
 }
 const csvRows=lines=>lines.map((r,i)=>[i===0?'S.No':r.some(v=>/^total(?:\s|$)/i.test(String(v)))?'':i,...r]);
 root.GREENLOOP_COMPLETE_LISTS={read,csvRows};
 if(typeof module!=='undefined'&&module.exports)module.exports={read,sources};
 if(!root.document)return;
 const document=root.document;
 const style=document.createElement('style');style.id='greenloop-complete-list-style';
 style.textContent=`.app-page button:is([id$="-prev"],[id$="-next"],[id$="-previous"],[data-dm-page]),.app-page .table-filter-pagination button{display:none!important}.gl-serial{width:48px!important;min-width:38px!important;white-space:nowrap;text-align:center!important;color:var(--nm-muted,#526b79);font-variant-numeric:tabular-nums}.app-page .qc-bulk-scroll,.app-page .final-bulk-scroll{max-height:none!important;overflow-y:visible!important}.gl-list-status{font-size:12px;color:var(--nm-muted,#526b79)}`;
 document.head.append(style);
 let queued=false,running=false;
 function serials(){
  if(running||!document.body?.classList.contains('app-page'))return;running=true;
  try{for(const table of document.querySelectorAll('table')){
   if(table.matches('[data-no-serial],.aid-table,.damage-summary-table')||table.closest('[data-label-preview],.phone-label,.device-label'))continue;
   const head=table.tHead?.rows[table.tHead.rows.length-1];if(!head)continue;
   const original=[...head.cells].filter(c=>!c.hasAttribute('data-gl-serial'));
   if(original.some(c=>/^(?:S\.?\s*No\.?|#|No\.)$/i.test(c.textContent.trim())))continue;
   if(!head.querySelector('[data-gl-serial]')){const th=document.createElement('th');th.dataset.glSerial='';th.className='gl-serial';th.scope='col';th.textContent='S.No';head.append(th);}
   let n=0;
   for(const body of table.tBodies)for(const row of body.rows){
    const cells=[...row.cells].filter(c=>!c.hasAttribute('data-gl-serial'));
    if(cells.length===1&&cells[0].colSpan>1){const c=cells[0];if(!c.dataset.glOriginalSpan)c.dataset.glOriginalSpan=String(c.colSpan);const span=Number(c.dataset.glOriginalSpan)+1;if(c.colSpan!==span)c.colSpan=span;continue;}
    let cell=row.querySelector(':scope > [data-gl-serial]');
    if(!cell){cell=document.createElement('td');cell.dataset.glSerial='';cell.className='gl-serial';row.append(cell);}
    const label=row.hidden||row.style.display==='none'||cells.some(c=>c.tagName==='TH')?'':String(++n);
    if(cell.textContent!==label)cell.textContent=label;
   }
  }
  for(const el of document.querySelectorAll('.table-filter-page-count,.aid-footer>span,[id$="-count"],[id$="-page"],[id$="-result"],[id$="-page-label"],.dm-pager>span')){
   if(el.children.length)continue;const text=el.textContent.replace(/\b[\d,]+\s*[–-]\s*[\d,]+\s+of\s+([\d,]+)/g,'$1');if(text!==el.textContent)el.textContent=text;
  }}finally{running=false;}
 }
 function schedule(){if(!queued){queued=true;root.requestAnimationFrame(()=>{queued=false;observer.disconnect();serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});});}}
 const observer=new MutationObserver(schedule);
 function start(){serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})(typeof window!=='undefined'?window:globalThis);
