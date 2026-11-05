/* Shared serials and exports; report readers retain server pagination. */
(function(root){
 'use strict';
 // Compatibility for cached clients: each report request returns its requested page.
 const read=(rpc,name,args={},other=[])=>rpc(name,args,...other);
 const csvRows=lines=>lines.map((r,i)=>[i===0?'S.No':r.some(v=>/^total(?:\s|$)/i.test(String(v)))?'':i,...r]);
 root.GREENLOOP_COMPLETE_LISTS={read,csvRows};
 if(typeof module!=='undefined'&&module.exports)module.exports={read};
 if(!root.document)return;
 const document=root.document;
 const style=document.createElement('style');style.id='greenloop-complete-list-style';
 style.textContent=`.gl-serial{width:48px!important;min-width:38px!important;white-space:nowrap;text-align:center!important;color:var(--nm-muted,#526b79);font-variant-numeric:tabular-nums}.app-page .qc-bulk-scroll,.app-page .final-bulk-scroll{max-height:none!important;overflow-y:visible!important}.gl-list-status{font-size:12px;color:var(--nm-muted,#526b79)}`;
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
  }finally{running=false;}
 }
 function schedule(){if(!queued){queued=true;root.requestAnimationFrame(()=>{queued=false;observer.disconnect();serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});});}}
 const observer=new MutationObserver(schedule);
 function start(){serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})(typeof window!=='undefined'?window:globalThis);
