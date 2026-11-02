/* Keyboard-wedge scanners replace the previous phone, without clearing ordinary typing. */
(() => {
  'use strict';
  const states=new WeakMap(),lookupTimers=new WeakMap();
  let lastField=null,locationRevision=0;
  const file=()=>location.pathname.split('/').pop().toLowerCase();
  const valid=value=>/^[0-9]{15}$/.test(String(value||'').trim());
  function field(input){
    if(!(input instanceof HTMLInputElement)||input.disabled||input.readOnly||input.closest('[data-multiple-imeis]'))return false;
    const requirement=window.GREENLOOP_CONTROL_CAPABILITY?.(input);
    if(requirement&&window.GREENLOOP_CAPABILITY_ALLOWED?.(requirement)!==true)return false;
    if(!['text','search','tel'].includes(input.type))return false;
    if(input.type==='search'||input.hasAttribute('data-imei-scan'))return true;
    const text=[input.id,input.name,input.placeholder,input.getAttribute('aria-label'),input.className,...[...(input.labels||[])].map(l=>l.textContent)].join(' ');
    return /imei|barcode|scan.*phone|phone.*scan/i.test(text);
  }
  function source(event){
    if(field(event.target))return event.target;
    if(document.querySelector('.gl-imei-stage-dialog[open]')&&field(lastField))return lastField;
    return null;
  }
  function clearOldNotice(){locationRevision++;window.GREENLOOP_IMEI_STAGE_NOTICE?.dismiss?.();}
  function replace(input,value){
    if(input.value===value)return;
    input.value=value;input.setSelectionRange(value.length,value.length);
    input.dispatchEvent(new Event('input',{bubbles:true}));
  }
  function usable(){const page=window.GREENLOOP_PAGE_ACCESS?.pageKey;return !!page&&(window.GREENLOOP_CAN?.('search',page)||window.GREENLOOP_CAN?.('entry',page)||window.GREENLOOP_CAN?.('scan',page)||window.GREENLOOP_CAN?.('search','imei_search'));}
  function stageKey(stage){
    const s=String(stage||'').toLowerCase();
    if(/initial\s*qc|qc\s*1/.test(s))return 'initial_qc';
    if(/final\s*qc|qc\s*2/.test(s))return 'final_qc';
    if(/frame|b[ -]?dept|b department/.test(s))return 'frame_department';
    if(/lab|laboratory|glass/.test(s))return 'lab_glass';
    if(/ready stock|qc_passed|production_completed|ready_for_(packing|shipment)/.test(s))return 'ready_stock';
    if(/^parts(?:\b|_)/.test(s))return 'parts';
    if(/stock return|supplier return|returned to supplier/.test(s))return 'supplier_returns';
    if(/export|shipped/.test(s))return 'stock_exported';
    if(/stock received|^received$/.test(s))return 'stock_received';
    return '';
  }
  function target(stage){
    const page=stageKey(stage),urls={initial_qc:'initial-qc.html',final_qc:'final-qc.html',frame_department:'laboratory.html#frame',lab_glass:'laboratory.html',ready_stock:'ready-stock.html',parts:'parts.html',supplier_returns:'stock-return.html',stock_exported:'stock-exported.html',stock_received:'stock-entry.html'};
    return urls[page]?{page,url:urls[page]}:null;
  }
  function expected(input){
    if(input.closest('#pp-returned,#pp-prices,.pf-history,.frame-history,[data-scan-history]'))return null;
    const f=file();
    if(f==='laboratory.html')return location.hash==='#frame'?['frame_department']:['lab_glass'];
    if(['glass.html','lab-bulk-transfer.html'].includes(f))return ['lab_glass'];
    if(f==='initial-qc.html')return ['initial_qc'];
    if(f==='final-qc.html')return ['final_qc'];
    if(f==='ready-stock.html')return ['ready_stock'];
    if(f==='parts.html'){
      if(document.querySelector('#pp-returned:not([hidden]),#pp-prices:not([hidden])'))return null;
      return ['parts','lab_glass']; // Initial QC sends the request to both departments.
    }
    if(['export-box.html','packing.html','stock-out.html'].includes(f))return ['ready_stock','export_boxes'];
    if(f==='imei-entry.html')return ['new_phone'];
    return null; // Reports and global IMEI Search intentionally cover every stage.
  }
  function nativeLocationCheck(input){
    return input.matches('.qc-bulk-imei,.final-row-imei,#technician-imei-scan,.batch-row-imei,#imei-1,#export-imei');
  }
  async function checkLocation(input){
    const accepted=expected(input),imei=input.value.trim();
    if(!accepted||!valid(imei)||!field(input)||!usable()||nativeLocationCheck(input))return;
    const ticket=++locationRevision;
    const current=()=>ticket===locationRevision&&input.isConnected&&input.value.trim()===imei&&usable();
    const record=await window.GREENLOOP_IMEI_STAGE_NOTICE?.lookup?.(imei);
    if(!current()||!record?.found||!record.current_stage)return;
    if(record.matched_type!=='secondary'&&accepted.includes(stageKey(record.current_stage)))return;
    const dest=target(record.current_stage);
    await window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei,knownRecord:record,isCurrent:current,
      title:record.matched_type==='secondary'?'Duplicate phone':'Phone is in another stage',
      message:'This phone is not in this page\'s current work queue. Its current location is shown below.'});
  }
  function schedule(input,delay=450){
    clearTimeout(lookupTimers.get(input));
    if(valid(input.value))lookupTimers.set(input,setTimeout(()=>void checkLocation(input),delay));
  }
  function complete(input,s){
    if(!valid(s.digits)||s.done)return;
    s.done=true;clearOldNotice();replace(input,s.digits);schedule(input,0);
    input.dispatchEvent(new CustomEvent('greenloop:imei-input-scan',{bubbles:true,detail:{imei:s.digits}}));
  }
  document.addEventListener('pointerdown',event=>{if(field(event.target))states.delete(event.target);},true);
  document.addEventListener('focusin',event=>{if(field(event.target))lastField=event.target;},true);
  window.addEventListener('keydown',event=>{
    const input=source(event);if(!input||event.isComposing||event.ctrlKey||event.altKey||event.metaKey||event.repeat)return;
    lastField=input;const now=performance.now();let s=states.get(input);
    if(/^[0-9]$/.test(event.key)){
      // Keep a short delivery pause inside one burst; claim only fast, complete scans.
      if(!s||s.done||now-s.last>250)s={digits:'',last:now,start:now,original:input.value,originalStart:input.selectionStart,originalEnd:input.selectionEnd,claimed:false,done:false};
      s.digits+=event.key;s.last=now;states.set(input,s);
      const avg=s.digits.length>1?(now-s.start)/(s.digits.length-1):0;
      const deliberateSelection=s.originalStart!==s.originalEnd&&!(s.originalStart===0&&s.originalEnd===s.original.length);
      s.deliberateSelection=deliberateSelection;
      const replaceable=!s.original||/^[0-9]{15,}$/.test(s.original)||s.originalStart===0&&s.originalEnd===s.original.length;
      if(replaceable&&!deliberateSelection&&s.digits.length>=3&&avg<=35)s.claimed=true;
      if(s.claimed&&s.digits.length<=15){
        event.preventDefault();if(document.querySelector('.gl-imei-stage-dialog[open]')){clearOldNotice();input.focus();}
        replace(input,s.digits);
      }
      if(s.digits.length===15&&!deliberateSelection&&(s.claimed||avg<=(replaceable?90:25))){
        event.preventDefault();complete(input,s);
      }
      if(s.digits.length>15)states.delete(input);
      return;
    }
    if(event.key==='Enter'||event.key==='Tab'){
      if(s&&!s.deliberateSelection&&s.digits.length===15&&(s.last-s.start)/14<=90)complete(input,s);
      schedule(input,0);states.delete(input);return;
    }
    if(!['Shift','CapsLock'].includes(event.key))states.delete(input);
  },true);
  document.addEventListener('paste',event=>{
    const input=field(event.target)?event.target:null;if(!input)return;
    const text=event.clipboardData?.getData('text')?.trim();
    if(!valid(text))return;
    event.preventDefault();clearOldNotice();states.delete(input);replace(input,text);schedule(input,0);
  },true);
  document.addEventListener('input',event=>{
    if(!field(event.target))return;
    if(event instanceof InputEvent&&event.data?.length>1)states.delete(event.target);
    lastField=event.target;locationRevision++;schedule(event.target);
  },true);
  document.addEventListener('submit',event=>{
    const form=event.target;if(!/search|lookup|scan/.test(form.id||'')&&!form.matches('.global-imei-search'))return;
    const input=[...form.querySelectorAll('input')].find(field);if(input)schedule(input,0);
  },true);
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');if(!button||!/^(?:Search|Find|Open phone)$/i.test(button.textContent.trim()))return;
    const host=button.closest('form,.lab-imei-finder');const input=host&&[...host.querySelectorAll('input')].find(field);if(input)schedule(input,0);
  },true);
  document.addEventListener('greenloop:workflow-committed',()=>{locationRevision++;});
  window.addEventListener('pagehide',()=>{locationRevision++;});
  async function prefill(){
    const imei=new URLSearchParams(location.search).get('scan_imei');if(!valid(imei))return;
    await window.GREENLOOP_ACCESS_READY;
    if(!usable())return;
    const apply=()=>{
      const visible=el=>!!el?.getClientRects().length;
      let input=[...document.querySelectorAll('#technician-imei-scan:not(:disabled),#imei-query:not(:disabled)')].find(visible);
      if(!field(input)){
        const trigger=document.querySelector('.gl-header-lookup:not([hidden]) .gl-header-search-trigger:not(:disabled)');
        if(visible(trigger)&&trigger.getAttribute('aria-expanded')!=='true')trigger.click();
        input=document.querySelector('.gl-header-lookup:not([hidden]) .gl-header-search-panel:not([hidden]) input:not(:disabled)');
      }
      if(!field(input))return false;
      replace(input,imei);input.focus();return true;
    };
    if(apply())return;
    const observer=new MutationObserver(()=>{if(apply())observer.disconnect();});observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['disabled','hidden']});setTimeout(()=>observer.disconnect(),10000);
  }
  window.addEventListener('DOMContentLoaded',()=>void prefill());
  window.GREENLOOP_IMEI_SCAN={checkLocation,target,stageKey};
})();
