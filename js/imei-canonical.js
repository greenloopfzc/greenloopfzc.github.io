/* Resolve a saved phone's IMEI 2 to its IMEI 1 before departmental handlers run. */
(function(root){
 'use strict';
 let live=true,epoch=0,running=0,timer;
 const pending=new Map(),queue=[],versions=new WeakMap(),approved=new WeakSet(),fields=new WeakMap(),pendingFields=new Set();
 const page=()=>root.GREENLOOP_PAGE_ACCESS?.pageKey;
 const allowed=()=>live&&root.GREENLOOP_CAN?.('view',page())===true;
 const valid=v=>/^\d{15}$/.test(v);
 function available(input){return allowed()&&input?.isConnected&&!input.disabled&&!input.readOnly&&!input.closest('[hidden]')&&!input.matches('[data-wf-field],[data-field]')&&!/imei[\s_-]*2|secondary/i.test([input.id,input.name].join(' '))&&root.GREENLOOP_IMEI_SCAN?.field(input);}
 function invalidate(stop=false){epoch++;if(stop)live=false;pending.clear();for(const input of pendingFields){fields.delete(input);input.removeAttribute('aria-busy');}pendingFields.clear();pump();}
 for(const event of ['pagehide','greenloop:office-locked','greenloop:signed-out'])root.addEventListener(event,()=>invalidate(true));
 root.addEventListener('greenloop:permissions-changed',()=>invalidate());
 document.addEventListener('greenloop:workflow-committed',()=>invalidate());
 function finish(entry,value,error){if(pending.get(entry.key)===entry)pending.delete(entry.key);for(const w of entry.waiters){if(w.epoch!==epoch||w.page!==page()||!allowed()||!w.current())w.resolve(null);else if(error)w.reject(error);else w.resolve(value);}}
 function pump(){
  while(running<2&&queue.length){
   const group=[];while(queue.length&&group.length<100){const e=queue.shift();if(e.epoch===epoch&&e.page===page()&&e.waiters.some(w=>w.current())&&allowed())group.push(e);else finish(e,null);}
   if(!group.length)continue;running++;
   void(async()=>{try{
    const imeis=group.map(e=>e.value),{data,error}=await root.GREENLOOP_GET_CLIENT().rpc('get_scan_imei_identities_v1',{p_imeis:imeis,p_page:group[0].page});if(error)throw error;
    if(!Array.isArray(data)||data.length!==group.length)throw Error('The phone identity response could not be verified. Scan again.');
    const rows=new Map();for(const r of data){if(!imeis.includes(r?.scanned_imei)||rows.has(r.scanned_imei)||!valid(r.imei)||typeof r.found!=='boolean'||!r.found&&r.imei!==r.scanned_imei||r.found&&!r.device_id)throw Error('The phone identity response could not be verified. Scan again.');rows.set(r.scanned_imei,r);}
    for(const e of group)finish(e,rows.get(e.value));
   }catch(error){for(const e of group)finish(e,null,error);}finally{running--;pump();}})();
  }
 }
 async function resolve(values,current=()=>true){
  if(!allowed())throw Error('This action is not allowed for your account.');
  const ids=[...new Set(values)];if(ids.some(v=>!valid(v)))throw Error('Use exact 15-digit IMEIs.');
  const p=page(),stamp=epoch;
  const rows=await Promise.all(ids.map(value=>new Promise((resolve,reject)=>{const key=stamp+':'+p+':'+value;let e=pending.get(key);if(!e){e={key,value,page:p,epoch:stamp,waiters:[]};pending.set(key,e);queue.push(e);}e.waiters.push({epoch:stamp,page:p,current,resolve,reject});})));
  return new Map(ids.map((v,i)=>[v,rows[i]]));
 }
 // Start queued reads before awaiting their results.
 async function lookup(values,current=()=>true){const result=resolve(values,current);if(!timer)timer=setTimeout(()=>{timer=null;pump();},8);return result;}
 function replay(input,value){input.value=value;const event=new Event('input',{bubbles:true});approved.add(event);input.dispatchEvent(event);}
 function reuse(input,identity){
  if(identity.imei===identity.scanned_imei||!input.matches('.qc-bulk-imei,.final-row-imei,.qc-issuance-imei,.batch-row-imei'))return false;
  const existing=[...input.closest('tbody').querySelectorAll('input')].find(e=>e!==input&&e.matches('.qc-bulk-imei,.final-row-imei,.qc-issuance-imei,.batch-row-imei')&&e.value.trim()===identity.imei);
  if(!existing||existing.closest('tr').dataset.completed==='yes')return false;
  replay(input,'');existing.closest('tr').scrollIntoView({block:'nearest'});if(!existing.disabled)existing.focus();else input.focus();return true;
 }
 root.addEventListener('input',event=>{
  const input=event.target;if(approved.has(event)){approved.delete(event);return;}
  if(!available(input))return;
  const revision=(versions.get(input)||0)+1;versions.set(input,revision);
  const value=input.value.trim();if(!valid(value)){fields.delete(input);pendingFields.delete(input);input.removeAttribute('aria-busy');return;}
  event.stopImmediatePropagation();const stamp=epoch,scope=page(),entry={value,revision};fields.set(input,entry);pendingFields.add(input);input.setAttribute('aria-busy','true');
  const current=()=>stamp===epoch&&page()===scope&&available(input)&&versions.get(input)===revision&&input.value.trim()===value;
  void lookup([value],current).then(rows=>{const r=rows.get(value);if(!r||!current())return;fields.delete(input);if(reuse(input,r))return;replay(input,r.imei);input.dispatchEvent(new CustomEvent('greenloop:imei-input-scan',{bubbles:true,detail:{imei:r.imei}}));})
   .catch(error=>{if(!current())return;fields.delete(input);if(root.GREENLOOP_SCAN_READY)void root.GREENLOOP_SCAN_READY.notice({input,imei:value,reset:()=>{input.value='';},allowed,title:'Phone identity unavailable',message:error.message||'The phone identity could not be checked. Scan again.'});else void root.GREENLOOP_IMEI_STAGE_NOTICE?.show({imei:value,isCurrent:current,title:'Phone identity unavailable',message:error.message||'Scan again.'});})
   .finally(()=>{if(fields.get(input)===entry)fields.delete(input);if(!fields.has(input)){pendingFields.delete(input);input.removeAttribute('aria-busy');}});
 },true);
 root.addEventListener('keydown',event=>{if(!['Enter','Tab'].includes(event.key))return;const input=event.target;if(fields.has(input)){event.preventDefault();event.stopImmediatePropagation();}},true);
 root.addEventListener('click',event=>{const button=event.target.closest?.('button');if(!button||! /^(?:Save|Transfer|Confirm|Issue|Receive)\b/i.test(button.textContent.trim()))return;const host=button.closest('form')||button.closest('main');if(host&&[...pendingFields].some(input=>host.contains(input))){event.preventDefault();event.stopImmediatePropagation();}},true);
 root.addEventListener('submit',event=>{if([...pendingFields].some(input=>event.target.contains(input))){event.preventDefault();event.stopImmediatePropagation();}},true);
 root.addEventListener('greenloop:imei-input-scan',event=>{if(fields.has(event.target)){event.preventDefault();event.stopImmediatePropagation();}},true);
 root.addEventListener('greenloop:imei-scan',event=>{
  if(approved.has(event)){approved.delete(event);return;}
  const value=String(event.detail?.imei||'');if(!valid(value)||!allowed())return;event.preventDefault();event.stopImmediatePropagation();const stamp=epoch;
  void lookup([value],()=>stamp===epoch&&allowed()).then(rows=>{const r=rows.get(value);if(!r||stamp!==epoch||!allowed())return;if(r.imei!==value){const existing=[...document.querySelectorAll('.qc-bulk-imei,.final-row-imei,.qc-issuance-imei,.batch-row-imei')].find(e=>e.value===r.imei&&e.closest('tr').dataset.completed!=='yes');if(existing){existing.closest('tr').scrollIntoView({block:'nearest'});if(!existing.disabled)existing.focus();return;}}const replay=new CustomEvent('greenloop:imei-scan',{cancelable:true,detail:{...event.detail,imei:r.imei}});approved.add(replay);root.dispatchEvent(replay);}).catch(error=>{if(stamp===epoch&&allowed())void root.GREENLOOP_IMEI_STAGE_NOTICE?.show({imei:value,title:'Phone identity unavailable',message:error.message||'Scan again.'});});
 },true);
 root.GREENLOOP_IMEI_CANONICAL={resolve:lookup,async list(values,current=()=>true){const rows=await lookup(values,current);if(!current()||!allowed())return null;const result=[];for(const value of values){const r=rows.get(value);if(!r)return null;if(!result.includes(r.imei))result.push(r.imei);}return result;}};
})(window);
