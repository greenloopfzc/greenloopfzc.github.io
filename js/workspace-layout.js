/* Presentation only. No fetches, pagination changes, saved values or cloned controls. */
(() => {
 'use strict';if(window.GREENLOOP_WORKSPACE_LAYOUT)return;
 window.GREENLOOP_WORKSPACE_LAYOUT=true;
 let queued=false,main,resize,lastWidth=-1;
 const clean=s=>String(s||'').replace(/[↑↓↕▲▼]/g,'').replace(/\s+/g,' ').trim();
 function weight(label){
  if(/^(s\.?\s*no\.?|#|no\.)$/i.test(label))return 0;
  if(/imei/.test(label.toLowerCase()))return 1.9;
  if(/parts needed|service needed|destination|transfer|route|save inspection/.test(label.toLowerCase()))return 1.9;
  if(/date|received|entered|invoice|batch|supplier code|model.*color/.test(label.toLowerCase()))return 1.6;
  if(/^(gb|bh|a|b|d|ba|bb|c|rma|qty|phones|pass|fail)$/i.test(label))return .7;
  return 1.15;
 }
 function compact(table,head){
  table.classList.remove('gl-fit-table','gl-table-cards');table.classList.add('gl-work-tray');
  const host=table.parentElement;host.classList.remove('gl-fit-scroll');host.classList.add('gl-work-tray-scroll');
  const width=host.getBoundingClientRect().width;if(width<=0)return;
  const labels=[...head.cells].map(c=>clean(c.dataset.sortLabel||c.textContent));
  const minima=labels.map(label=>{
   const s=label.toLowerCase();return /^(s\.?\s*no\.?|#)$/.test(s)?28:/imei/.test(s)?128:/parts needed|service needed/.test(s)?110:/destination|route|transfer/.test(s)?138:/save/.test(s)?58:/final grade/.test(s)?106:/pass|fail/.test(s)?60:/b-dept/.test(s)?76:/final bh/.test(s)?62:/supplier code/.test(s)?68:/grade/.test(s)?48:32;
  });
  const desired=minima.map((min,i)=>{
   let longest=labels[i].length*5.3+12;
   for(const body of table.tBodies)for(const row of [...body.rows].slice(0,50)){
    if(row.cells.length!==head.cells.length||[...row.cells].some(c=>c.colSpan>1))continue;
    const c=row.cells[i],texts=[],walk=document.createTreeWalker(c,NodeFilter.SHOW_TEXT);
    while(walk.nextNode())if(!walk.currentNode.parentElement.closest('[hidden],select,button,input,textarea'))texts.push(walk.currentNode.textContent);
    longest=Math.max(longest,Math.min(180,clean(texts.join(' ')).length*5.3+12));
    for(const select of c.querySelectorAll('select')){
     if(select.closest('[hidden]'))continue;
     const value=select.selectedOptions[0]?.textContent||'';if(select.title!==value)select.title=value;
     longest=Math.max(longest,Math.min(180,value.length*5.3+28));
    }
   }
   return min===28?28:Math.max(min,Math.min(200,longest));
  });
  const floor=minima.reduce((a,b)=>a+b,0),wanted=desired.reduce((a,b)=>a+b,0),available=Math.max(1,width-2);
  table.classList.toggle('gl-work-tray-stack',available<floor);
  const ratio=wanted>floor?Math.min(1,Math.max(0,(available-floor)/(wanted-floor))):0;
  const widths=minima.map((min,i)=>min+(desired[i]-min)*ratio),used=widths.reduce((a,b)=>a+b,0),stretch=labels.map(s=>/imei|model|color|supplier|parts|service|technician|destination|route|transfer|final grade/i.test(s)),flex=stretch.filter(Boolean).length;
  head.querySelectorAll('th').forEach((cell,i)=>{
   const value=(widths[i]+(!stretch[i]?0:Math.max(0,available-used)/Math.max(1,flex))).toFixed(2)+'px';
   if(cell.style.getPropertyValue('--gl-tray-width')!==value)cell.style.setProperty('--gl-tray-width',value);
  });
  for(const body of table.tBodies)for(const row of body.rows){let col=0;for(const cell of row.cells){if(cell.colSpan===1){const label=labels[col]||'';if(cell.dataset.glColLabel!==label)cell.dataset.glColLabel=label;}col+=cell.colSpan;}}
 }
 function fit(){
  queued=false;main=document.querySelector('body.app-page .app-main');if(!main)return;
  for(const table of main.querySelectorAll('table')){
   if(table.closest('[data-label-preview],.phone-label,.device-label,[data-preserve-table-layout]'))continue;
   const head=table.tHead?.rows[table.tHead.rows.length-1];if(!head||head.cells.length<2)continue;
   if(table.matches('.qc-bulk-table,.final-bulk-table,.issuance-table')||document.body.classList.contains('frame-mode')&&table.matches('#frame-pending-panel .technician-lines-table')){compact(table,head);continue;}
   // Multi-row technician workbenches have their own grouped record layout.
   const complex=[...table.tBodies].some(b=>[...b.rows].some(r=>r.cells.length>1&&[...r.cells].some(c=>c.colSpan>1||c.rowSpan>1)));
   if(complex)continue;
   const labels=[...head.cells].map(c=>clean(c.dataset.sortLabel||c.textContent)),weights=labels.map(weight),serial=weights.includes(0)?40:0,total=weights.reduce((a,b)=>a+b,0);
   table.classList.add('gl-fit-table');table.parentElement.classList.add('gl-fit-scroll');
   for(let i=0;i<head.cells.length;i++){const value=weights[i]===0?'40px':`calc((100% - ${serial}px) * ${weights[i]/total})`;if(head.cells[i].style.getPropertyValue('--gl-fit-width')!==value)head.cells[i].style.setProperty('--gl-fit-width',value);}
   for(const body of [...table.tBodies,...(table.tFoot?[table.tFoot]:[])])for(const row of body.rows){let col=0;for(const cell of row.cells){const span=cell.colSpan||1;if(span>1){cell.dataset.glFullRow='';}else{const label=labels[col]||'';if(cell.dataset.glColLabel!==label)cell.dataset.glColLabel=label;}col+=span;}}
   const width=table.parentElement.getBoundingClientRect().width;if(width>0)table.classList.toggle('gl-table-cards',width<serial+total*72);
  }
 }
 function schedule(){if(!queued){queued=true;requestAnimationFrame(fit);}}
 const mutations=new MutationObserver(schedule);
 function start(){main=document.querySelector('body.app-page .app-main');if(!main)return;fit();mutations.observe(main,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden']});resize=new ResizeObserver(entries=>{const w=Math.round(entries[0].contentRect.width);if(w!==lastWidth){lastWidth=w;schedule();}});resize.observe(main);window.addEventListener('resize',schedule);main.addEventListener('change',schedule);}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
 window.addEventListener('pagehide',()=>{mutations.disconnect();resize?.disconnect();window.removeEventListener('resize',schedule);main?.removeEventListener('change',schedule);});
 window.addEventListener('pageshow',e=>{if(e.persisted)start();});
})();
