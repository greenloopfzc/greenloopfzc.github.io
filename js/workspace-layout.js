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
 function fit(){
  queued=false;main=document.querySelector('body.app-page .app-main');if(!main)return;
  for(const table of main.querySelectorAll('table')){
   if(table.closest('[data-label-preview],.phone-label,.device-label,[data-preserve-table-layout]'))continue;
   const head=table.tHead?.rows[table.tHead.rows.length-1];if(!head||head.cells.length<2)continue;
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
 function start(){main=document.querySelector('body.app-page .app-main');if(!main)return;fit();mutations.observe(main,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden']});resize=new ResizeObserver(entries=>{const w=Math.round(entries[0].contentRect.width);if(w!==lastWidth){lastWidth=w;schedule();}});resize.observe(main);window.addEventListener('resize',schedule);}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
 window.addEventListener('pagehide',()=>{mutations.disconnect();resize?.disconnect();window.removeEventListener('resize',schedule);});
 window.addEventListener('pageshow',e=>{if(e.persisted)start();});
})();
