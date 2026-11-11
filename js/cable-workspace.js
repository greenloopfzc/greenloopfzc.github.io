/* Shared USB handoff. Reads phone data; never clicks Save/Transfer/Issue. */
(() => {
 'use strict';
 const pages=new Set(['imei_search','initial_qc','qc_issuance','final_qc','frame_department','lab_glass','parts','supplier_returns','supplier_return_approval','supplier_return_handover','reports','accounts','ready_stock','export_boxes','stock_exported','ready_stock_journey','stock_received','overview']);
 let bar,info,use,status,device=null,applied='',locked=false,epoch=0;
 const routes=[];
 const shown=e=>!!e&&e.isConnected&&!e.closest('[hidden],dialog:not([open])')&&e.getClientRects().length>0;
 const usable=e=>shown(e)&&!e.disabled&&!e.readOnly;
 const first=s=>[...document.querySelectorAll(s)].find(usable);
 const can=c=>window.GREENLOOP_CAN?.(c,window.GREENLOOP_PAGE_ACCESS?.pageKey)===true;
 const say=t=>{if(status)status.textContent=t;};
 function field(e,value,force=false){if(!usable(e)||value==null||value==='')return false;
  // Manual drafts stay intact. Values previously filled by this reader may refresh.
  if(e.value&&e.value!==e.dataset.cableWorkspaceValue&&!force)return false;
  const val=String(value);if(e.tagName==='SELECT'){
   const normal=v=>String(v).toLowerCase().replace(/^iphone\s*/,'').replace(/\s+/g,'').replace(/gb$/,'');
   const choice=[...e.options].find(o=>normal(o.value)===normal(val)||normal(o.textContent)===normal(val));if(!choice)return false;e.value=choice.value;
  }else e.value=val;
  e.dataset.cableWorkspaceValue=e.value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;
 }
 function send(input,imei,{empty=false,submit=false,button=null,force=false}={}){
  if(!usable(input)||empty&&input.value)return false;
  if(!force&&input.value&&input.value!==input.dataset.cableWorkspaceValue)return false;
  input.value=imei;input.dataset.cableWorkspaceValue=imei;
  input.dispatchEvent(new Event('input',{bubbles:true}));
  if(submit&&input.form)input.form.requestSubmit();
  else if(button){const b=document.querySelector(button);if(usable(b))b.click();}
  return true;
 }
 function route(d,force){
  const imei=d.imei;
  for(const r of routes)if(r.active())return r.apply(d,{force});
  const p=window.GREENLOOP_PAGE_ACCESS?.pageKey;
  if(p==='initial_qc'||p==='qc_issuance'||p==='final_qc'){
   if(!can('entry'))return false;
   const selectors={initial_qc:'.qc-bulk-imei',qc_issuance:'.qc-issuance-imei',final_qc:'.final-row-imei'};
   const inputs=[...document.querySelectorAll(selectors[p])].filter(usable);
   if(inputs.some(e=>e.value===imei)){say('This phone is already in the tray.');return true;}
   let blank=inputs.find(e=>!e.value);if(!blank){const add=first(p==='qc_issuance'?'#issuance-add':'#add-ten-rows');if(add){add.click();blank=[...document.querySelectorAll(selectors[p])].find(e=>usable(e)&&!e.value);}}
   return send(blank,imei,{empty:true});
  }
  if(p==='frame_department')return can('entry')&&send(first('#b-dept-scan-imei'),imei,{force});
  if(p==='lab_glass'){
   const bulk=first('[data-lbt-scan]');if(bulk)return can('entry')&&send(bulk,imei,{force});
   return can('search')&&send(first('#technician-imei-scan'),imei,{button:'#check-technician-imei',force});
  }
  if(p==='export_boxes')return can('entry')&&send(first('#export-imei'),imei,{force});
  if(p==='imei_search')return can('search')&&send(first('#imei-query'),imei,{submit:true,force});
  if(p==='reports'){
   if(window.GREENLOOP_FULL_IMEI_CORRECTION?.isBusy()||window.GREENLOOP_BULK_IMEI_CORRECTION?.isBusy())return false;
   const full=first('#wf-identifier');if(full&&can('workflow_correction'))return send(full,imei,{submit:true,force});
   const list=first('[data-bci-imeis]');if(list&&can('bulk_imei_correction')){if(list.value.trim()&&!force)return false;list.value=imei;const open=first('[data-bci-list]');if(open)open.click();return true;}
   // Other report filters: use only an explicitly focused IMEI/search input.
   const target=document.activeElement;
   if(usable(target)&&target.matches('input[type=search],input[data-imei-scan],input[data-bulk-imei-search]')&&can('search'))return send(target,imei,{force});
   return false;
  }
  // View/report pages use their visible search filter, never editable saved rows.
  if(can('search')){const target=first('.table-filters .table-filter-toolbar input[type=search],.table-filter-search input,input[data-bulk-imei-search]');if(target)return send(target,imei,{force});}
  return false;
 }
 async function apply(force=false){
  if(locked||!device||Date.now()-(window.GREENLOOP_LAST_DEVICE_AT||0)>30000||!can('view'))return;
  if(!/^\d{15}$/.test(device.imei||'')){say('No primary IMEI is available yet. Read again after unlocking the phone.');return;}
  const active=routes.find(r=>r.active());const context=active?(active.key?.()||String(routes.indexOf(active))):window.GREENLOOP_PAGE_ACCESS?.pageKey;
  const key=String(window.GREENLOOP_CABLE_CONNECTION_ID||device.connectionId||'')+':'+device.imei+':'+context;
  if(!force&&applied===key)return;
  if(document.querySelector('dialog[open],tr[data-saving="yes"],tr[data-loading="yes"],tr[data-busy="yes"]')){say('Phone ready. Finish the current action, then choose Use connected phone.');return;}
  const revision=epoch;
  try{const used=await route(device,force);if(revision!==epoch||locked)return;
   if(used){applied=key;say('Connected phone loaded. Review the page before saving or transferring.');}
   else say('Phone ready. Open the required entry/search window, then choose Use connected phone. Existing entries are preserved.');
  }catch(e){if(revision===epoch)say(e.message||'The connected phone could not load on this page.');}
 }
 function show(d){
  if(locked||!bar||!can('view'))return;device=d;for(const r of routes)if(r.active()&&r.enrich)r.enrich(d);
  const values=[d.model,d.storageGb?d.storageGb+' GB':'',d.color,d.imei?'IMEI '+d.imei:'',d.batteryHealth!==''&&d.batteryHealth!=null?'BH '+d.batteryHealth+'%':'',d.serialNumber?'SN '+d.serialNumber:'',d.phoneRegion].filter(Boolean);
  info.textContent=values.join(' · ');use.disabled=!/^\d{15}$/.test(d.imei||'');void apply();
 }
 function clear(){epoch++;device=null;applied='';if(info)info.textContent='';if(use)use.disabled=true;}
 function lock(){locked=true;clear();if(bar)bar.hidden=true;}
 window.GREENLOOP_CABLE_WORKSPACE={register:r=>{if(r&&typeof r.active==='function'&&typeof r.apply==='function')routes.push(r);},field,apply};
 document.addEventListener('change',e=>{if(e.target.matches('#rp-supplier,#rp-batch,.sr-simple-form select[name=supplier],.sr-simple-form select[name=batch]'))setTimeout(()=>void apply(),0);});
 window.addEventListener('greenloop:device',e=>show(e.detail||{}));
 window.addEventListener('greenloop:device-reader-status',e=>{if(!bar||locked)return;const s=e.detail||{};if(['waiting','offline'].includes(s.state)){clear();say(s.message||'Connect one unlocked phone.');}else if(s.state==='reading')say('Reading connected phone…');});
 for(const e of ['greenloop:office-locked','greenloop:signed-out'])window.addEventListener(e,lock);
 window.addEventListener('greenloop:permissions-changed',()=>{clear();if(!can('view'))lock();});
 Promise.resolve(window.GREENLOOP_ACCESS_READY).then(()=>{
  const page=window.GREENLOOP_PAGE_ACCESS?.pageKey;if(!pages.has(page)||!can('view')||locked)return;
  const host=document.querySelector('.page-content');if(!host)return;
  bar=document.createElement('section');bar.className='cable-workspace';bar.setAttribute('aria-label','Connected phone');
  const title=document.createElement('strong');title.textContent='Cable Reader';
  info=document.createElement('span');info.className='cable-workspace-phone';
  status=document.createElement('small');status.setAttribute('role','status');status.textContent='Connect one unlocked phone. Reader setup is required on this PC.';
  use=document.createElement('button');use.type='button';use.className='secondary-button';use.textContent='Use connected phone';use.disabled=true;use.onclick=()=>void apply(true);
  const retry=document.createElement('button');retry.type='button';retry.className='secondary-button';retry.textContent='Read again';retry.onclick=()=>{if(!locked)window.dispatchEvent(new Event('greenloop:retry-device'));};
  const copy=document.createElement('div');copy.className='cable-workspace-copy';copy.append(title,info,status);const actions=document.createElement('div');actions.className='cable-workspace-actions';actions.append(use,retry);bar.append(copy,actions);host.prepend(bar);
  const current=window.GREENLOOP_GET_CONNECTED_DEVICE?.();if(current)show(current);
 });
})();
