/* B-DEPT work tray: scanning selects existing pending work; it never saves QC. */
(() => {
 'use strict';
 const valid=v=>/^\d{15}$/.test(v),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function mount({host,getRows,reload,render,start,allowed}){
  const panel=document.createElement('section');panel.className='b-dept-scan';panel.setAttribute('aria-label','Scan B-DEPT phones');
  panel.innerHTML='<div class="b-dept-scan-field"><label for="b-dept-scan-imei">Scan / paste IMEIs</label><input id="b-dept-scan-imei" type="text" inputmode="numeric" autocomplete="off" maxlength="15" data-b-dept-scan data-imei-scan data-capability="entry" data-capability-page="frame_department" placeholder="Scan a phone or paste an Excel IMEI column"><small>Each scan adds a new line. The scanner stays ready for the next phone.</small></div><div class="b-dept-scan-actions"><button type="button" class="secondary-button" data-frame-show-all data-capability="view" data-capability-page="frame_department" data-search-read-only>Auto Pick</button><button type="button" class="secondary-button" data-frame-clear-tray data-capability="view" data-capability-page="frame_department" data-search-read-only>Clear Tray</button><span data-frame-scan-count role="status" aria-live="polite"></span></div>';
  host.querySelector('#lab-work-filters').before(panel);
  const input=panel.querySelector('input'),count=panel.querySelector('[data-frame-scan-count]');
  let entries=[],selected=true,running=false,ticket=0,stopped=false,loadedAt=0,invalidValues=[];
  const can=()=>!stopped&&Boolean(window.document?.body?.contains(input))&&allowed(),queue=()=>new Map(getRows().map(r=>[String(r.imei),r]));
  function status(){const loaded=entries.filter(e=>e.state==='loaded').length,done=entries.filter(e=>e.state==='complete').length,bad=entries.filter(e=>e.state==='error').length;count.textContent=selected?`${entries.length} selected · ${loaded} loaded${done?' · '+done+' completed':''}${bad?' · '+bad+' need checking':''}`:'All pending phones loaded';if(invalidValues.length)count.textContent+=` · ${invalidValues.length} invalid value(s): ${invalidValues.slice(0,3).join(', ')}`;input.disabled=!can();}
  function select(rows){
   if(!selected)return rows;
   const byImei=new Map(rows.map(r=>[String(r.imei),r]));
   return entries.map((e,i)=>e.state==='loaded'&&byImei.has(e.imei)?{...byImei.get(e.imei),scan_line:i+1}:{imei:e.imei,scan_line:i+1,scan_issue:e.message||'Checking this phone…',scan_completed:e.state==='complete',scan_entry:i}).concat(Array.from({length:Math.max(1,10-entries.length)},(_,i)=>({scan_empty:true,scan_line:entries.length+i+1})));
  }
  function changed(){if(!window.document?.body?.contains(input)||stopped)return;status();render();}
  async function explain(entry,revision){
   const record=await window.GREENLOOP_IMEI_STAGE_NOTICE?.lookup?.(entry.imei);
   if(revision!==ticket||!can())return;
   entry.record=record;
   entry.message=record?.matched_type==='secondary'?`This is IMEI 2 of IMEI 1 ${record.primary_imei||'not recorded'}. Use IMEI 1.`:record?.found?`Current stage: ${window.GREENLOOP_DEPT_NAME(record.current_stage||'not recorded')}. This phone is not available in pending B-DEPT work.`:'IMEI not found in the software.';
   if(entry.source==='scan'&&entries.at(-1)===entry&&record&&revision===ticket&&can())void window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei:entry.imei,knownRecord:record,title:'Phone unavailable in B-DEPT',message:entry.message,isCurrent:()=>revision===ticket&&entries.at(-1)===entry&&can()}).catch(()=>{});
  }
  async function process(){
   if(running||!can())return;running=true;const revision=ticket;
   try{
    if(Date.now()-loadedAt>3000||entries.some(e=>e.state==='checking'&&!queue().has(e.imei))){await reload();loadedAt=Date.now();}
    while(revision===ticket&&can()){
     const pending=entries.filter(e=>e.state==='checking');if(!pending.length)break;
     const current=queue();let next=0;
     await Promise.all(Array.from({length:Math.min(4,pending.length)},async()=>{while(next<pending.length){const e=pending[next++];if(revision!==ticket||!can())return;if(current.has(e.imei)){e.state='loaded';e.message='';}else{e.state='error';e.message='Not in pending B-DEPT work.';await explain(e,revision);}}}));
     if(revision===ticket&&can())changed();
    }
   }catch(e){if(revision===ticket&&can()){for(const item of entries.filter(x=>x.state==='checking')){item.state='error';item.message=e.message||'The phone could not load. Refresh and scan again.';}changed();}}
   finally{running=false;status();if(entries.some(e=>e.state==='checking')&&can())void process();}
  }
  async function add(values,source){
   if(!can())return;
   if(host.querySelector('tr[data-busy="yes"]')){count.textContent='Wait for the current Save to finish, then scan again.';return;}
   const revision=ticket,seen=new Set(entries.map(e=>e.imei)),first=entries.length===0;selected=true;
   for(const imei of values){const duplicate=seen.has(imei);seen.add(imei);entries.push({imei,state:duplicate?'error':'checking',message:duplicate?'Duplicate IMEI — this extra line cannot be saved.':'Checking this phone…',source});}
   input.value='';if(first)await start();if(revision!==ticket||!can())return;changed();void process();input.focus();
  }
  function readInput(field) {
   field.value=field.value.replace(/\D/g,'').slice(0,15);
   if(valid(field.value))void add([field.value],'scan');
  }
  host.addEventListener('input',event=>{
   if(event.target===input||event.target.matches('[data-frame-empty-imei]'))readInput(event.target);
  });
  host.addEventListener('keydown',event=>{
   if(event.key==='Enter'&&(event.target===input||event.target.matches('[data-frame-empty-imei]'))){event.preventDefault();readInput(event.target);}
  });
  const pasted=e=>{if(e.target!==input&&!e.target.matches('[data-frame-empty-imei]'))return;e.preventDefault();e.stopImmediatePropagation();if(!can())return;const text=e.clipboardData?.getData('text/plain')||e.clipboardData?.getData('text')||'',values=[],issues=[];for(const raw of text.split(/[\s,;]+/)){const value=raw.replace(/^["']|["']$/g,'').replace(/[\u0660-\u0669\u06f0-\u06f9]/g,c=>String(c.charCodeAt(0)-(c.charCodeAt(0)>=0x6f0?0x6f0:0x660)));if(!value||/^imei(?:1)?$/i.test(value))continue;if(valid(value))values.push(value);else issues.push(value);}invalidValues.push(...issues);if(values.length)void add(values,'paste');else status();};
  window.addEventListener('paste',pasted,true);
  async function resetTray(showPending) {
   if(window.GREENLOOP_CAN?.('view','frame_department')!==true||host.querySelector('tr[data-busy="yes"]'))return;
   const revision=++ticket;
   selected=!showPending;entries=[];invalidValues=[];input.value='';
   await start();
   if(revision!==ticket||stopped)return;
   changed();
   if(showPending){
    try{await reload();if(revision===ticket&&!stopped)changed();}
    catch(error){if(revision===ticket)count.textContent=error.message||'Pending phones could not load. Try Auto Pick again.';}
   }else if(can())input.focus();
  }
  panel.querySelector('[data-frame-show-all]').onclick=()=>void resetTray(true);
  panel.querySelector('[data-frame-clear-tray]').onclick=()=>void resetTray(false);
  host.addEventListener('click',e=>{const b=e.target.closest('[data-frame-scan-location]');if(!b)return;const item=entries[Number(b.dataset.frameScanLocation)];if(!item?.record||!can())return;void window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei:item.imei,knownRecord:item.record,title:'Phone unavailable in B-DEPT',message:item.message});});
  function stop(){stopped=true;ticket++;entries=[];selected=true;status();}
  for(const event of ['greenloop:office-locked','greenloop:signed-out','pagehide'])window.addEventListener(event,stop);
  window.addEventListener('greenloop:permissions-changed',()=>{if(!allowed())stop();else{stopped=false;status();}});
  window.addEventListener('pageshow',event=>{if(event.persisted&&window.document?.body?.contains(input)){stopped=false;status();if(can())void reload().then(changed).catch(()=>{});}});
  status();
  return{select,refresh(){loadedAt=Date.now();const current=queue();for(const e of entries)if(e.state==='loaded'&&!current.has(e.imei)){e.state='error';e.message='This phone is no longer pending in B-DEPT. Refresh or check its current location.';}status();},complete(imei,label){for(const e of entries)if(e.imei===imei&&e.state==='loaded'){e.state='complete';e.message=label;}status();},issueMarkup(row){
   if(row.scan_empty)return `<tr class="b-dept-empty-row"><td><input type="text" inputmode="numeric" maxlength="15" autocomplete="off" placeholder="Scan IMEI" aria-label="Scan IMEI line ${row.scan_line}" data-frame-empty-imei data-capability="entry" data-capability-page="frame_department" ${can()?'':'disabled'}></td>${Array.from({length:11},()=>'<td>—</td>').join('')}<td><button type="button" class="line-save" disabled>Save</button></td></tr>`;
   return `<tr class="b-dept-scan-result${row.scan_completed?' is-completed':' is-error'}"><td colspan="13"><span class="b-dept-scan-line">Line ${row.scan_line}</span><strong>${esc(row.imei)}</strong><span>${esc(row.scan_issue)}</span>${entries[row.scan_entry]?.record?`<button type="button" class="secondary-button" data-frame-scan-location="${row.scan_entry}" data-capability="view" data-capability-page="frame_department" data-search-read-only>Current location</button>`:''}</td></tr>`;}};
 }
 window.GREENLOOP_B_DEPT_SCAN={mount};
})();
