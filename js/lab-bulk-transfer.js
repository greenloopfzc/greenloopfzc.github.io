/* A scanned handover list; completion uses the existing Lab action grant. */
(() => {
  'use strict';
  let root,context,epoch=0,rows=[],queue=[],processing=false,working=false,pending=null,needsRecheck=false,timer;
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const canEdit=()=>window.GREENLOOP_PAGE_ACCESS?.pageKey==='lab_glass'&&window.GREENLOOP_PAGE_ACCESS?.canEdit===true&&window.GREENLOOP_CAN?.('entry','lab_glass')===true;
  const alive=revision=>revision===epoch&&root?.isConnected&&window.GREENLOOP_PAGE_ACCESS?.pageKey==='lab_glass';
  const client=()=>window.GREENLOOP_GET_CLIENT();
  const el=id=>root?.querySelector('[data-lbt-'+id+']');
  function message(text='',error=false){if(!root)return;const host=el('message');host.textContent=text;host.classList.toggle('is-error',error);host.hidden=!text;}
  function dirty(){return context?.hasDrafts?.()===true;}
  function render(){
    if(!root)return;
    const ready=rows.filter(row=>row.ready).length,busy=working||processing,locked=working||!!pending;
    context?.onBusy?.(locked);
    el('count').textContent=String(rows.length);el('summary').textContent=`${rows.length} phone${rows.length===1?'':'s'} · ${ready} ready${queue.length?' · '+queue.length+' scans queued':''}`;
    el('rows').innerHTML=rows.length?rows.map((r,i)=>`<tr class="${r.ready?'lbt-ready':'lbt-blocked'}"><td>${i+1}</td><td><strong>${esc(r.imei)}</strong></td><td>${esc(r.model||'—')}</td><td>${esc(r.storage_gb?Number(r.storage_gb)>=1024&&Number(r.storage_gb)%1024===0?Number(r.storage_gb)/1024+' TB':r.storage_gb+' GB':'—')}</td><td>${esc(r.color||'—')}</td><td>${esc(r.technician||'Unassigned')}</td><td>${esc(r.supplier_code||'—')}</td><td><span class="lbt-state">${r.ready?'Ready for Final QC':'Not ready'}</span>${r.reasons?.length?`<small>${esc(r.reasons.join(' '))}</small>`:''}</td><td><button type="button" class="secondary-button" data-lbt-remove="${esc(r.device_id)}" data-capability="entry" data-capability-page="lab_glass"${busy||locked?' disabled':''} aria-label="Remove ${esc(r.imei)} from this transfer list">Remove</button></td></tr>`).join(''):'<tr><td colspan="9" class="lbt-empty">Scan or enter the completed phones to prepare a handover.</td></tr>';
    el('scan').disabled=locked||!canEdit();el('add').disabled=locked||!canEdit();
    el('recheck').disabled=busy||locked||!rows.length||!canEdit();
    el('transfer').disabled=busy||!canEdit()||!rows.length||queue.length>0||(!pending&&(needsRecheck||ready!==rows.length));
    el('transfer').textContent=working?'Transferring…':pending?'Retry Transfer to Final QC':'Transfer All to Final QC';
    el('close').disabled=busy||!!pending;
  }
  function validPhone(data){return data&&typeof data==='object'&&typeof data.device_id==='string'&&/^[0-9]{15}$/.test(data.imei)&&typeof data.ready==='boolean'&&Array.isArray(data.reasons)&&typeof data.selection_token==='string'&&(!data.ready||typeof data.step_id==='string');}
  function focus(){if(!root||el('scan').disabled)return;el('scan').focus();}
  function enqueue(value){
    clearTimeout(timer);if(!canEdit()||working||pending)return;
    if(dirty()){message('Save or discard the changed Lab lines before preparing a bulk transfer.',true);return;}
    const scan=String(value??'').trim();if(!/^[0-9]{15}$/.test(scan)){message('Enter or scan one complete 15-digit IMEI.',true);focus();return;}
    if(rows.length+queue.length>=500){message('Transfer the current list before adding more phones (500 per handover).',true);return;}
    el('scan').value='';focus();
    if(queue.includes(scan)||rows.some(row=>row.imei===scan)){message('This phone is already in the transfer list.',true);return;}
    queue.push(scan);drain();
  }
  async function drain(){
    if(processing)return;processing=true;const revision=epoch;render();
    try{while(queue.length&&alive(revision)){
      const scan=queue.shift();message('Checking scanned phone…');
      try{const response=await client().rpc('lookup_lab_bulk_phone_v1',{p_imei:scan});if(!alive(revision))return;if(response.error)throw response.error;
        if(!validPhone(response.data))throw new Error('Phone details were incomplete. Scan again to retry.');
        const phone=response.data;
        if(rows.some(row=>row.device_id===phone.device_id||row.imei===phone.imei)){message('This phone is already in the transfer list.',true);}
        else{rows.push(phone);message(phone.matched_secondary?`IMEI 2 matched this phone. Added IMEI 1: ${phone.imei}.`:phone.ready?`Added ${phone.imei}. Ready for Final QC.`:`Added ${phone.imei}. ${phone.reasons.join(' ')}`,!phone.ready);}
      }catch(error){if(!alive(revision))return;message(error.message||'This phone could not be checked. Scan it again.',true);if(!queue.length&&!el('scan').value){el('scan').value=scan;el('scan').select();}}
      render();
    }}finally{if(alive(revision)){processing=false;render();}}
  }
  async function recheck(){
    if(processing||working||pending||!canEdit())return;
    if(dirty()){message('Save or discard the changed Lab lines before rechecking.',true);return;}
    processing=true;const revision=epoch;render();let failed=false;
    try{for(let i=0;i<rows.length;i++){
      try{const r=await client().rpc('lookup_lab_bulk_phone_v1',{p_imei:rows[i].imei});if(!alive(revision))return;if(r.error)throw r.error;if(!validPhone(r.data))throw Error('Phone details are incomplete.');rows[i]=r.data;}
      catch(error){if(!alive(revision))return;rows[i]={...rows[i],ready:false,reasons:[error.message||'Could not recheck this phone.']};failed=true;}
    }needsRecheck=failed;message(failed?'Some phones could not be rechecked. Review their lines and retry.':rows.every(row=>row.ready)?'All phones are ready. You can transfer the list.':'Some phones are not ready. Review their reasons below.',failed||rows.some(row=>!row.ready));}
    finally{if(alive(revision)){processing=false;render();}}
  }
  async function transfer(){
    if(working||processing||queue.length||!canEdit()||!rows.length)return;
    if(dirty()){message('Save or discard the changed Lab lines before transfer.',true);return;}
    if(!pending&&(needsRecheck||rows.some(row=>!row.ready)))return;
    pending ||= {p_request_id:crypto.randomUUID(),p_items:rows.map(row=>({imei:row.imei,step_id:row.step_id,selection_token:row.selection_token}))};
    working=true;const revision=epoch;render();message('Transferring all phones to Final QC…');
    try{
      const r=await client().rpc('transfer_lab_bulk_to_final_qc_v1',pending);if(!alive(revision))return;
      if(r.error){
        // A database rejection is rolled back. A lost connection may have committed;
        // keep its exact request key and command for an idempotent retry.
        if(/^(?:[0-9A-Z]{5})$/.test(r.error.code||'')&&!/^PGRST/.test(r.error.code)&&!['55P03','57014','40003'].includes(r.error.code)){pending=null;needsRecheck=true;message((r.error.message||'Transfer was rejected.')+' Recheck the list before trying again.',true);}
        else message((r.error.message||'Connection interrupted.')+' Retry this same transfer to confirm its result. Keep this page open.',true);
        return;
      }
      const result=r.data,expected=pending.p_items.map(row=>row.imei).sort();
      if(!result||result.transfer_id!==pending.p_request_id||result.status!=='final_qc_pending'||result.transferred_count!==expected.length||!Array.isArray(result.imeis)||JSON.stringify([...result.imeis].sort())!==JSON.stringify(expected)){
        message('The transfer result could not be confirmed. Retry this same transfer to check its saved result.',true);return;
      }
      const count=result.transferred_count;rows=[];pending=null;needsRecheck=false;
      message(`${count} phone${count===1?'':'s'} transferred to Final QC.`);
      document.dispatchEvent(new CustomEvent('greenloop:notifications-changed'));
      try{await context?.onTransferred?.(result);}catch{if(alive(revision))message(`${count} phones transferred to Final QC. Refresh the workbench to update its cards.`);}
    }catch(error){if(alive(revision))message((error.message||'Connection interrupted.')+' Retry this same transfer to confirm its result. Keep this page open.',true);}
    finally{if(alive(revision)){working=false;render();if(!pending)focus();}}
  }
  function mount(host,options={}){
    unmount();if(!host||window.location.hash.toLowerCase()==='#frame'||window.GREENLOOP_PAGE_ACCESS?.pageKey!=='lab_glass')return;
    context=options;root=document.createElement('section');root.className='lab-bulk-transfer';host.append(root);
    root.innerHTML=`<button type="button" class="lbt-launch" data-lbt-open data-capability="view" data-capability-page="lab_glass" aria-expanded="false" aria-controls="lab-bulk-panel"><span class="lbt-icon" aria-hidden="true">⇥</span><span><strong>Bulk Transfer to Final QC</strong><small>Scan completed phones and hand them over together.</small></span><span class="lbt-launch-count" data-lbt-count>0</span><span aria-hidden="true">→</span></button>
      <div id="lab-bulk-panel" data-lbt-panel hidden><div class="lbt-panel-heading"><h2>Completed phones handover</h2><button type="button" class="secondary-button" data-lbt-close data-capability="view" data-capability-page="lab_glass">Close</button></div>
      <form class="lbt-scan-form" data-lbt-form><label for="lab-bulk-imei">Scan or enter IMEI<input id="lab-bulk-imei" data-lbt-scan data-capability="entry" data-capability-page="lab_glass" inputmode="numeric" autocomplete="off" placeholder="15-digit IMEI" maxlength="15"></label><button type="submit" class="primary-button" data-lbt-add data-capability="entry" data-capability-page="lab_glass">Add phone</button></form>
      <p class="lbt-message" data-lbt-message role="status" aria-live="polite" hidden></p><div class="lbt-toolbar"><strong data-lbt-summary>0 phones · 0 ready</strong><div><button type="button" class="secondary-button" data-lbt-recheck data-capability="entry" data-capability-page="lab_glass">Recheck list</button><button type="button" class="primary-button" data-lbt-transfer data-capability="entry" data-capability-page="lab_glass">Transfer All to Final QC</button></div></div>
      <div class="lbt-table-scroll"><table class="lbt-table"><thead><tr><th>#</th><th>IMEI</th><th>Model</th><th>GB</th><th>Color</th><th>Technician</th><th>Supplier code</th><th>Readiness</th><th>List</th></tr></thead><tbody data-lbt-rows></tbody></table></div></div>`;
    el('open').addEventListener('click',()=>{if(dirty()){message('Save or discard changed Lab lines before preparing a bulk transfer.',true);el('panel').hidden=false;el('open').setAttribute('aria-expanded','true');return;}const open=el('panel').hidden;if((working||pending)&&!open)return;el('panel').hidden=!open;el('open').setAttribute('aria-expanded',String(open));if(open)focus();});
    el('close').addEventListener('click',()=>{if(working||pending||processing)return;el('panel').hidden=true;el('open').setAttribute('aria-expanded','false');el('open').focus();});
    el('form').addEventListener('submit',event=>{event.preventDefault();enqueue(el('scan').value);});
    el('scan').addEventListener('input',()=>{clearTimeout(timer);if(/^[0-9]{15}$/.test(el('scan').value.trim()))timer=setTimeout(()=>enqueue(el('scan').value),60);});
    el('scan').addEventListener('paste',event=>{const text=event.clipboardData?.getData('text')||'';const values=text.trim().split(/[\s,;]+/);if(values.length>1&&values.every(value=>/^[0-9]{15}$/.test(value))){event.preventDefault();for(const value of values)enqueue(value);}});
    el('recheck').addEventListener('click',recheck);el('transfer').addEventListener('click',transfer);
    root.addEventListener('click',event=>{const button=event.target.closest('[data-lbt-remove]');if(!button||processing||working||pending||!canEdit())return;rows=rows.filter(row=>row.device_id!==button.dataset.lbtRemove);render();});
    if(options.standalone){root.classList.add('lbt-standalone');el('open').hidden=true;el('close').hidden=true;el('panel').hidden=false;}
    render();if(options.standalone)focus();
  }
  function unmount(){epoch++;clearTimeout(timer);context?.onBusy?.(false);root?.remove();root=null;context=null;rows=[];queue=[];processing=false;working=false;pending=null;needsRecheck=false;}
  window.addEventListener('greenloop:office-locked',unmount);
  window.addEventListener('beforeunload',event=>{if(working||pending){event.preventDefault();event.returnValue='';}});
  window.GREENLOOP_LAB_BULK={mount,unmount,isBusy:()=>working||!!pending};
})();
