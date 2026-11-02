/* One explicit review/save action for each cable phone; manual Auto Save stays separate. */
(() => {
  'use strict';
  const canEnter=()=>window.GREENLOOP_PAGE_ACCESS?.canEdit===true&&window.GREENLOOP_CAN?.('entry','imei_entry')===true;
  let current=null,pending=null,busy=false,timer=0,lastSaved=null;
  const dismissed=new Set(),edited=new Set();
  const dialog=document.createElement('dialog');dialog.id='cable-device-review';dialog.className='cable-device-review';
  dialog.setAttribute('aria-labelledby','cable-review-title');
  dialog.innerHTML=`<form id="cable-review-form"><header><div><p class="eyebrow">CABLE READER</p><h2 id="cable-review-title">Review connected phone</h2></div><button type="button" id="cable-review-close" class="secondary-button" aria-label="Close phone review">Close</button></header><p id="cable-review-receipt"></p><div class="cable-review-grid"></div><p id="cable-review-status" role="status" aria-live="polite"></p><div id="cable-review-label" aria-label="Label preview"></div><footer><button id="cable-review-save" class="secondary-button" type="button">Save</button><button id="cable-review-print" class="primary-button" type="submit">Save &amp; Print</button></footer></form>`;
  document.body.appendChild(dialog);
  const get=id=>dialog.querySelector('#'+id),form=get('cable-review-form'),grid=dialog.querySelector('.cable-review-grid');
  const status=get('cable-review-status'),label=get('cable-review-label'),saveButton=get('cable-review-save'),printButton=get('cable-review-print');
  const fields={};const definitions=[['imei','IMEI 1','text'],['brand','Brand','text'],['model','Model','select'],['storageGb','GB','select'],['color','Color','select'],['batteryHealth','Battery Health %','number'],['serialNumber','Serial Number','text'],['phoneRegion','Region','text']];
  for(const[key,title,type]of definitions){
    const wrap=document.createElement('div');wrap.className='form-field';const caption=document.createElement('label');caption.htmlFor='cable-review-'+key;caption.textContent=title;
    const input=document.createElement(type==='select'?'select':'input');input.id=caption.htmlFor;input.name=key;
    if(type!=='select')input.type=type;if(type==='number'){input.min='0';input.max='100';input.step='1';}
    if(key==='imei'){input.readOnly=true;input.pattern='[0-9]{15}';}else if(type==='text')input.maxLength=key==='brand'?80:120;
    if(!['serialNumber','phoneRegion','batteryHealth'].includes(key))input.required=true;
    input.addEventListener('input',()=>{edited.add(key);if(key==='batteryHealth')edited.add('estimated');syncEdits();});
    input.addEventListener('change',()=>{edited.add(key);syncEdits();});fields[key]=input;wrap.append(caption,input);grid.appendChild(wrap);
  }
  const naWrap=document.createElement('label');naWrap.className='cable-review-unavailable';
  naWrap.innerHTML='<input id="cable-review-unavailable" type="checkbox"> Battery health is not available on this Android phone';grid.appendChild(naWrap);
  const unavailable=get('cable-review-unavailable');unavailable.onchange=()=>{edited.add('batteryUnavailable');syncEdits();};
  const reprint=document.createElement('button');reprint.type='button';reprint.id='reprint-device-label';reprint.className='secondary-button';reprint.textContent='Reprint Last Label';reprint.disabled=true;
  document.querySelector('.cable-reader-banner')?.appendChild(reprint);
  reprint.onclick=()=>{if(!lastSaved||!canEnter())return;try{window.GREENLOOP_PHONE_LABEL.print(lastSaved);}catch(e){window.alert(e.message);}};
  function values(){return {...current.read(),...Object.fromEntries(Object.entries(fields).map(([key,input])=>[key,input.value])),batteryUnavailable:unavailable.checked,estimated:edited.has('estimated')?false:current.read().estimated};}
  function syncEdits(){if(!current||busy||lastSaved&&current.saved)return;const d=values();current.write(d,edited);syncBattery(d);preview(d);}
  function syncBattery(d){naWrap.hidden=d.platform!=='android';unavailable.checked=d.platform==='android'&&d.batteryUnavailable;fields.batteryHealth.disabled=unavailable.checked;fields.batteryHealth.required=!unavailable.checked;fields.brand.readOnly=d.platform!=='android';}
  function preview(d){try{label.innerHTML=window.GREENLOOP_PHONE_LABEL.svg(d);}catch{label.textContent='Label preview will appear when a valid IMEI 1 is available.';}}
  function populate(adapter,refresh=false){
    const d=adapter.read();get('cable-review-receipt').textContent=adapter.receipt||'Selected supplier receipt';
    for(const[key,input]of Object.entries(fields)){
      if(refresh&&edited.has(key))continue;
      if(input.tagName==='SELECT'){
        const source=adapter.selects[key];input.replaceChildren(new Option('Choose '+(key==='storageGb'?'GB':key),''));
        for(const option of source?.options||[])if(option.value)input.add(new Option(option.text,option.value));
        if(d[key]!==''&&d[key]!=null&&![...input.options].some(o=>o.value===String(d[key])))input.add(new Option(String(d[key]),String(d[key])));
      }
      input.value=d[key]??'';
    }
    if(!refresh||!edited.has('batteryUnavailable'))unavailable.checked=Boolean(d.batteryUnavailable);
    syncBattery(values());preview(values());
    status.textContent=d.estimated?'Battery Health is estimated. Verify or correct it before saving.':'Review the details. Saving sends this phone to Initial QC. Label: 60 x 40 mm.';
  }
  function close(){if(busy)return;clearTimeout(timer);if(current&&!current.saved)dismissed.add(current.key);dialog.close();current=null;edited.clear();label.textContent='';if(pending){const next=pending;pending=null;offer(next);}}
  get('cable-review-close').onclick=close;dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  function offer(adapter,force=false){
    if(!canEnter()||!adapter?.isCurrent()||adapter.isLatest?.()===false||!/^\d{15}$/.test(String(adapter.read().imei||'')))return;
    if(busy){if(current?.key!==adapter.key)pending=adapter;return;}
    if(current?.saved&&dialog.open){pending=adapter;return;}
    if(current?.key===adapter.key&&dialog.open){current=adapter;populate(adapter,true);return;}
    if(!force&&dismissed.has(adapter.key))return;
    clearTimeout(timer);timer=setTimeout(()=>{
      if(!canEnter()||!adapter.isCurrent()||adapter.isLatest?.()===false)return;
      current=adapter;edited.clear();saveButton.textContent='Save';printButton.textContent='Save & Print';
      for(const input of dialog.querySelectorAll('input,select,button'))input.disabled=false;
      populate(adapter);if(!dialog.open)dialog.showModal();
    },force?0:450);
  }
  async function commit(withPrint){
    if(busy||!current||!canEnter())return;
    if(current.saved){if(withPrint)reprint.onclick();else close();return;}
    if(!current.isCurrent()){status.textContent='The receipt or phone changed. Close this review and read the phone again.';return;}
    syncEdits();if(!form.reportValidity())return;
    const adapter=current,entry={...values()};let printWindow=null;
    if(withPrint)printWindow=window.GREENLOOP_PHONE_LABEL.openWindow();
    busy=true;for(const input of dialog.querySelectorAll('input,select,button'))input.disabled=true;status.textContent='Saving phone...';
    try{
      const result=await adapter.save(()=>adapter.isCurrent()&&canEnter());
      if(!result?.saved){if(printWindow&&!printWindow.closed)printWindow.close();status.textContent='Phone not saved. Check the highlighted details or error popup, then retry.';return;}
      lastSaved=Object.freeze({...entry,...result.entry});current={...adapter,saved:true};reprint.disabled=!canEnter();
      status.textContent='Saved and sent to Initial QC. This phone will not be saved again.';
      saveButton.textContent='Done';printButton.textContent='Reprint Label';
      if(withPrint){try{window.GREENLOOP_PHONE_LABEL.print(lastSaved,printWindow);}catch(e){status.textContent=e.message;}}
    }catch(error){if(printWindow&&!printWindow.closed)printWindow.close();status.textContent=error.message||'Save could not be confirmed. Check IMEI Search before trying again.';}
    finally{
      busy=false;for(const button of dialog.querySelectorAll('button'))button.disabled=false;
      if(!current?.saved){for(const input of dialog.querySelectorAll('input,select'))input.disabled=false;syncBattery(values());}
    }
  }
  saveButton.type='submit';printButton.type='button';
  printButton.onclick=()=>commit(true);form.onsubmit=event=>{event.preventDefault();void commit(false);};
  document.querySelector('#stock-batch')?.addEventListener('change',()=>{if(!busy)close();});
  window.addEventListener('pagehide',()=>{clearTimeout(timer);pending=null;});
  window.GREENLOOP_CABLE_REVIEW={offer};
})();
