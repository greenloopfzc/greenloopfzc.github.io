(() => {
  'use strict';
  const elements=new Map([...document.querySelectorAll('[id^="qc-handover"]')].map(element=>['#'+element.id,element]));
  const $ = selector => elements.get(selector) || document.querySelector(selector), panel = $('#qc-handover');
  if (!panel) return;
  const rows = new Map(), pending = new Set();
  let revision = 0, exporting = false, stopped = false, pdfUrl = '', libraryPromise, logoPromise;
  const allowed = () => !stopped && window.GREENLOOP_CAN?.('entry','initial_qc') === true;
  const busy = () => pending.size > 0;
  function status(text = '', error = false) {
    const el = $('#qc-handover-message'); el.textContent = text; el.hidden = !text; el.classList.toggle('is-error',error);
  }
  function closePdf() {
    const dialog = $('#qc-handover-preview'); if(dialog.open)dialog.close();
    $('#qc-handover-frame').removeAttribute('src'); $('#qc-handover-open').removeAttribute('href'); $('#qc-handover-file').removeAttribute('href');
    if(pdfUrl)URL.revokeObjectURL(pdfUrl);pdfUrl='';
  }
  function update() {
    panel.hidden = !allowed();
    const groups = new Set([...rows.values()].map(r => r.technicianId || ''));
    $('#qc-handover-count').textContent = `${rows.size} saved ${rows.size === 1 ? 'phone' : 'phones'}`;
    $('#qc-handover-technician').textContent = groups.size===1 ? ([...rows.values()][0]?.technician || 'Unassigned') : groups.size>1 ? `${groups.size} technicians - check assignments` : 'Save entries, then generate the sheet.';
    panel.querySelectorAll('[data-qc-handover]').forEach(button => button.disabled = !allowed() || busy() || exporting || rows.size===0);
  }
  function changed() { revision++;closePdf();status();update(); }
  function setBusy(key, value) { value ? pending.add(key) : pending.delete(key);if(value){revision++;closePdf();}update(); }
  function record(value) {
    if(stopped)return;
    rows.set(String(value.jobId),{jobId:String(value.jobId),imei:String(value.imei),technicianId:value.technicianId || '',technician:value.technician || 'Unassigned',model:value.model || '',storage:value.storage || '',color:value.color || '',parts:value.parts.map(p=>({name:p.name,quantity:p.quantity})),services:[...value.services]});
    changed();
  }
  function warning(text) {
    status(text,true);$('#qc-handover-warning-text').textContent=text;
    if(!$('#qc-handover-warning').open)$('#qc-handover-warning').showModal();
  }
  function snapshot() {
    if(!allowed())throw new Error('Initial QC entry permission is required to generate this handover sheet.');
    if(busy())throw new Error('Wait for the Initial QC saves to finish before generating the sheet.');
    const data={generatedAt:new Date().toISOString(),rows:[...rows.values()]};window.GREENLOOP_QC_HANDOVER_PDF.validate(data);return data;
  }
  function library() {
    if(window.PDFLib)return Promise.resolve();
    if(!libraryPromise)libraryPromise=new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='js/vendor/pdf-lib-1.17.1.min.js';script.onload=()=>window.PDFLib?resolve():reject(new Error('PDF tools could not load. Please try again.'));script.onerror=()=>{script.remove();reject(new Error('PDF tools could not load. Check the connection and try again.'));};document.head.append(script);}).catch(error=>{libraryPromise=null;throw error;});
    return libraryPromise;
  }
  function logo() {
    if(!logoPromise)logoPromise=(async()=>{const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);try{const response=await fetch('assets/greenloop-fzc-logo.jpg',{signal:controller.signal});if(!response.ok)throw new Error('Greenloop logo could not load. Please try again.');return await response.arrayBuffer();}finally{clearTimeout(timer);}})().catch(()=>{logoPromise=null;throw new Error('Greenloop logo could not load. Check the connection and try again.');});
    return logoPromise;
  }
  function printImage(image) {
    return new Promise((resolve,reject)=>{let timer;const done=error=>{clearTimeout(timer);image.onload=null;image.onerror=null;error?reject(error):resolve();};if(image.complete){done(image.naturalWidth?null:new Error('Greenloop logo could not load. Please try Print again.'));return;}image.onload=()=>done();image.onerror=()=>done(new Error('Greenloop logo could not load. Please try Print again.'));timer=setTimeout(()=>done(new Error('Greenloop logo could not load. Please try Print again.')),12000);});
  }
  async function generate(kind) {
    if(exporting)return;
    let data;
    try{data=snapshot();}catch(error){warning(error.message);return;}
    if(kind==='print') {
      const target=window.open('','_blank');
      if(!target){status('The print window was blocked. Allow pop-ups for Greenloop and try Print again.',true);return;}
      const token=revision;exporting=true;status('Preparing print sheet...');update();
      try{target.opener=null;const brand=await logo();if(!allowed()||token!==revision||busy()){if(!target.closed)target.close();if(allowed())status('The saved list changed. Generate the sheet again.',true);return;}let binary='';for(const b of new Uint8Array(brand))binary+=String.fromCharCode(b);const html=window.GREENLOOP_QC_HANDOVER_PDF.printHtml(data,{logoUrl:'data:image/jpeg;base64,'+btoa(binary)});if(target.closed)return;target.document.open();target.document.write(html);target.document.close();
        await Promise.all([...target.document.images].map(printImage));
        if(!allowed()||token!==revision||busy()){if(!target.closed)target.close();if(allowed())status('The saved list changed. Generate the sheet again.',true);return;}
        if(!target.closed){target.focus();target.print();}status();
      }catch(error){if(!target.closed)target.close();if(allowed())status(error.message||'The print sheet could not be prepared. Please try again.',true);}
      finally{exporting=false;update();}return;
    }
    const token=revision;exporting=true;status('Preparing PDF...');update();
    try {
      const [,brand]=await Promise.all([library(),logo()]);const file=await window.GREENLOOP_QC_HANDOVER_PDF.create(data,{logo:brand});
      if(!allowed())return;
      if(token!==revision || busy()){status('The saved list changed. Generate the sheet again.',true);return;}
      const url=URL.createObjectURL(new Blob([file.bytes],{type:'application/pdf'}));
      if(kind==='view') {
        closePdf();pdfUrl=url;$('#qc-handover-frame').src=url;$('#qc-handover-open').href=url;$('#qc-handover-file').href=url;$('#qc-handover-file').download=file.filename;$('#qc-handover-preview').showModal();
      }else{const link=document.createElement('a');link.dataset.capability='entry';link.dataset.capabilityPage='initial_qc';link.href=url;link.download=file.filename;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);}
      status();
    }catch(error){if(allowed())status(error.message || 'The PDF could not be generated. Please try again.',true);}
    finally{exporting=false;update();}
  }
  panel.addEventListener('click',event=>{const button=event.target.closest('[data-qc-handover]');if(button)void generate(button.dataset.qcHandover);});
  $('#qc-handover-close').addEventListener('click',closePdf);
  $('#qc-handover-preview').addEventListener('cancel',event=>{event.preventDefault();closePdf();});
  $('#qc-handover-warning-close').addEventListener('click',()=>$('#qc-handover-warning').close());
  window.addEventListener('greenloop:office-locked',()=>{stopped=true;revision++;rows.clear();pending.clear();closePdf();$('#qc-handover-warning').close();update();});
  window.addEventListener('pagehide',closePdf);
  window.GREENLOOP_QC_HANDOVER={record,setBusy,refresh:update};
  Promise.resolve(window.GREENLOOP_ACCESS_READY).then(update);
})();
