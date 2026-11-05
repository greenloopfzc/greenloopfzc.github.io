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
 style.textContent=`
.app-page table.gl-content-table{table-layout:auto!important;width:auto!important;min-width:100%;max-width:none!important}
.app-page table.gl-content-table tr>:is(th,td){width:auto!important;min-width:0!important;max-width:none!important;overflow:visible!important;overflow-wrap:normal}
.app-page table.gl-content-table th{white-space:nowrap!important}
.app-page table.gl-content-table td{white-space:nowrap}
.app-page table.gl-content-table td :is(p,small,.lpo-list){white-space:normal}
.app-page table.gl-content-table tr>.gl-serial{width:1px!important;min-width:0!important;max-width:none!important;padding-left:9px!important;padding-right:9px!important;white-space:nowrap!important;text-align:center!important;font-variant-numeric:tabular-nums}
.app-page .gl-content-scroll{overflow-x:auto!important;max-width:100%;min-width:0}
.app-page .qc-bulk-scroll,.app-page .final-bulk-scroll{max-height:none!important;overflow-y:visible!important;overflow-x:auto!important}
.app-page .qc-save-route{min-width:175px;flex-wrap:nowrap}.app-page .qc-bulk-imei-cell input{min-width:160px}
.app-page :is(.qc-bulk-table,.final-bulk-table,.qci-table) select{min-width:135px}
.gl-list-status{font-size:12px;color:var(--nm-muted,#526b79)}
`;

 document.head.append(style);
 let queued=false,running=false;
 function serials(){
  if(running||!document.body?.classList.contains('app-page'))return;running=true;
  try{for(const table of document.querySelectorAll('table')){
   if(table.matches('[data-no-serial],.damage-summary-table')||table.closest('[data-label-preview],.phone-label,.device-label'))continue;
   const head=table.tHead?.rows[table.tHead.rows.length-1];if(!head)continue;
   // Composite workbench rows keep their existing grouped layout.
   const complex=[...table.tBodies].some(b=>[...b.rows].some(r=>r.cells.length>1&&[...r.cells].some(c=>c.colSpan>1||c.rowSpan>1)));
   if(complex)continue;
   table.classList.add('gl-content-table');table.parentElement?.classList.add('gl-content-scroll');
   const original=[...head.cells].filter(c=>!c.hasAttribute('data-gl-serial'));
   const existing=original.find(c=>/^(?:S\.?\s*No\.?|#|No\.)$/i.test(c.textContent.trim()));
   if(existing){const index=existing.cellIndex;existing.classList.add('gl-serial');if(index){head.prepend(existing);for(const b of [...table.tBodies,...(table.tFoot?[table.tFoot]:[])])for(const row of b.rows)if(row.cells.length===original.length&&[...row.cells].every(c=>c.colSpan===1))row.prepend(row.cells[index]);}continue;}
   if(!head.querySelector('[data-gl-serial]')){const th=document.createElement('th');th.dataset.glSerial='';th.className='gl-serial';th.scope='col';th.textContent='S.No';head.prepend(th);}else if(head.firstElementChild!==head.querySelector('[data-gl-serial]'))head.prepend(head.querySelector('[data-gl-serial]'));
   let n=0;
   for(const body of table.tBodies)for(const row of body.rows){
    const cells=[...row.cells].filter(c=>!c.hasAttribute('data-gl-serial'));
    if(cells.length===1&&cells[0].colSpan>1){const c=cells[0];if(!c.dataset.glOriginalSpan)c.dataset.glOriginalSpan=String(c.colSpan);const span=Number(c.dataset.glOriginalSpan)+1;if(c.colSpan!==span)c.colSpan=span;continue;}
    let cell=row.querySelector(':scope > [data-gl-serial]');
    if(!cell){cell=document.createElement('td');cell.dataset.glSerial='';cell.className='gl-serial';row.prepend(cell);}
    if(row.firstElementChild!==cell)row.prepend(cell);
    const label=row.hidden||row.style.display==='none'||cells.some(c=>c.tagName==='TH')?'':String(++n);
    if(cell.textContent!==label)cell.textContent=label;
   }
   if(table.tFoot)for(const row of table.tFoot.rows){if(row.cells.length===1){const c=row.cells[0];if(!c.dataset.glOriginalSpan)c.dataset.glOriginalSpan=String(c.colSpan);c.colSpan=Number(c.dataset.glOriginalSpan)+1;}else if(!row.querySelector('[data-gl-serial]')){const cell=document.createElement('td');cell.dataset.glSerial='';cell.className='gl-serial';row.prepend(cell);}}
  }
  }finally{running=false;}
 }
 function schedule(){if(!queued){queued=true;root.requestAnimationFrame(()=>{queued=false;observer.disconnect();serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});});}}
 const observer=new MutationObserver(schedule);
 function start(){serials();observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','style']});}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})(typeof window!=='undefined'?window:globalThis);
