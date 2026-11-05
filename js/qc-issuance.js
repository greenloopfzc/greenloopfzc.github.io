/* Saved Initial QC inspections are assigned and transferred from this full page. */
(() => {
  'use strict';
  const $=s=>document.querySelector(s),app=$('#issuance-app'),body=$('#issuance-body');
  const client=window.GREENLOOP_GET_CLIENT(),records=new Map(),timers=new WeakMap(),prepared=new Map();
  let technicians=[],sequence=0,busy=false,stopped=false,paste,editing=null;
  const selectionTemplate={technician:'',destination:'lab_glass'};
  const can=()=>!stopped&&window.GREENLOOP_CAN?.('entry','initial_qc')===true;
  const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const storage=n=>!n?'—':n>=1024&&n%1024===0?`${n/1024} TB`:`${n} GB`;
  const date=s=>s?new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',dateStyle:'medium',timeStyle:'short'}).format(new Date(s))+' UAE':'—';
  function message(text='',success=false){const e=$('#issuance-message');e.textContent=text;e.hidden=!text;e.classList.toggle('is-visible',Boolean(text));e.classList.toggle('is-success',success);}
  function state(row,text='',error=false){const e=row.querySelector('[data-row-state]');e.textContent=text;e.hidden=!text;row.classList.toggle('is-error',error);}
  function options(value=''){return '<option value="">Choose technician</option>'+technicians.map(t=>`<option value="${esc(t.id)}" ${t.id===value?'selected':''}>${esc(t.name)}</option>`).join('');}
  function sync(row){
    if(row.dataset.completed==='yes'){row.querySelectorAll('input,select,button').forEach(e=>e.disabled=true);return;}
    const r=records.get(row),destination=row.querySelector('[data-destination]');
    row.querySelectorAll('input,select,button').forEach(e=>e.disabled=busy||paste?.busy||!can()||Boolean(editing));
    const tech=row.querySelector('[data-technician]');tech.disabled=busy||paste?.busy||!can()||Boolean(editing)||destination.value==='b_dept';
    row.querySelector('[data-transfer]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!r;
    row.querySelector('[data-edit-work]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!r;
    row.querySelector('[data-reload]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!row.querySelector('.qc-issuance-imei').value;
  }
  function syncAll(){for(const row of body.rows)sync(row);syncWorkEditor();window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(app);}
  function carrySelection(row,field){
    const selector=field==='technician'?'[data-technician]':'[data-destination]',flag=field==='technician'?'manualTechnician':'manualDestination';
    if(row!==body.firstElementChild){row.dataset[flag]='yes';return;}
    const value=row.querySelector(selector).value;selectionTemplate[field]=value;
    for(const other of [...body.rows].slice(1)){
      if(other.dataset.completed==='yes'||other.dataset[flag]==='yes')continue;
      other.querySelector(selector).value=value;delete other.dataset.issueRequest;sync(other);
    }
  }
  function createRows(n){for(let i=0;i<n;i++)body.insertAdjacentHTML('beforeend',`<tr data-row-id="issue-${++sequence}"><td class="issuance-imei-cell"><input class="qc-issuance-imei" placeholder="Scan IMEI" maxlength="15" inputmode="numeric" autocomplete="off" data-capability="entry" aria-label="Scan IMEI"><small data-row-state role="status" hidden></small></td><td data-phone>—</td><td data-storage>—</td><td data-color>—</td><td data-battery>—</td><td data-stock>—</td><td data-supplier-grade>—</td><td data-gl-grade>—</td><td data-parts>—</td><td data-services>—</td><td><select data-technician data-capability="entry" aria-label="Assign technician">${options(selectionTemplate.technician)}</select></td><td><select data-destination data-capability="entry" aria-label="Destination"><option value="lab_glass">Lab &amp; Glass</option><option value="b_dept">B-DEPT</option></select></td><td><div class="issuance-row-actions"><button type="button" class="secondary-button issuance-edit" data-edit-work data-capability="entry" title="Edit Parts / Services" aria-label="Edit Parts / Services" disabled>Edit</button><button type="button" class="primary-button" data-transfer data-capability="entry" disabled>Transfer</button><button type="button" class="secondary-button issuance-reload" data-reload data-capability="entry" aria-label="Reload details" title="Reload saved details">↻</button></div></td></tr>`);
    for(const row of [...body.rows].slice(-n))row.querySelector('[data-destination]').value=selectionTemplate.destination;
    $('#issuance-lines').textContent=`${body.rows.length} lines`;if(!paste?.busy)syncAll();
  }
  function clearRow(row){records.delete(row);row.dataset.ticket=String(Number(row.dataset.ticket||0)+1);delete row.dataset.issueRequest;row.dataset.loading='';for(const selector of ['[data-phone]','[data-storage]','[data-color]','[data-battery]','[data-stock]','[data-supplier-grade]','[data-gl-grade]','[data-parts]','[data-services]']){const cell=row.querySelector(selector);cell.textContent='—';cell.removeAttribute('title');cell.removeAttribute('aria-label');}state(row);sync(row);}
  async function rpc(name,args={}){const{data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function workMessage(text=''){
    const e=$('#issuance-work-message');e.textContent=text;e.hidden=!text;
  }
  function syncWorkEditor(){
    const locked=busy||paste?.busy||!can();
    $('#issuance-work-editor').querySelectorAll('input,select,button').forEach(e=>e.disabled=locked);
    for(const id of ['issuance-transfer-all','issuance-add','issuance-clear','issuance-load-all','issuance-refresh']){
      const e=$('#'+id);e.disabled=busy||paste?.busy||Boolean(editing)||(e.dataset.capability==='entry'&&!can());
    }
  }
  function renderWorkEditor(){
    if(!editing)return;
    const {parts,services,catalog}=editing;
    $('#issuance-edit-parts').innerHTML=parts.length?parts.map((p,i)=>`<div class="issuance-selected-item"><span>${esc(p.name)}</span><input type="number" min="1" max="10000" step="1" value="${esc(p.quantity)}" data-edit-quantity="${i}" data-capability="entry" aria-label="Quantity for ${esc(p.name)}"><button type="button" class="secondary-button" data-remove-edit-part="${i}" data-capability="entry" aria-label="Remove ${esc(p.name)} part">Remove</button></div>`).join(''):'<p class="issuance-work-empty">No parts selected</p>';
    $('#issuance-edit-services').innerHTML=services.length?services.map((name,i)=>`<div class="issuance-selected-item issuance-selected-service"><span>${esc(name)}</span><button type="button" class="secondary-button" data-remove-edit-service="${i}" data-capability="entry" aria-label="Remove ${esc(name)} service">Remove</button></div>`).join(''):'<p class="issuance-work-empty">No services selected</p>';
    const key=v=>String(v).trim().replace(/\s+/g,' ').toLowerCase();
    $('#issuance-part-choice').innerHTML='<option value="">Choose part</option>'+catalog.parts.filter(p=>!parts.some(x=>key(x.name)===key(p.name))).map(p=>`<option value="${esc(p.name)}">${esc(p.name)}</option>`).join('');
    $('#issuance-service-choice').innerHTML='<option value="">Choose service</option>'+catalog.services.filter(p=>!services.some(x=>key(x)===key(p.name))).map(p=>`<option value="${esc(p.name)}">${esc(p.name)}</option>`).join('');
    syncWorkEditor();
  }
  function closeWorkEditor(){
    editing?.row.classList.remove('is-editing');editing=null;
    const panel=$('#issuance-work-editor');panel.hidden=true;
    $('#issuance-edit-parts').replaceChildren();$('#issuance-edit-services').replaceChildren();
    $('#issuance-work-phone').textContent='';workMessage();syncAll();
  }
  async function openWorkEditor(row){
    const r=records.get(row);
    if(editing||busy||paste?.busy||!can()||!r||row.dataset.completed==='yes')return;
    lock(true);message();
    try{
      const catalog=await rpc('get_ranked_qc_dropdowns_v1');
      if(!can()||!row.isConnected||records.get(row)!==r)return;
      if(!Array.isArray(catalog?.parts)||!Array.isArray(catalog?.services)||![...catalog.parts,...catalog.services].every(o=>typeof o.name==='string'&&o.name.trim()))throw Error('The parts and services dropdowns could not be loaded. Try Edit again.');
      editing={row,record:r,catalog,parts:r.parts.map(p=>({name:p.name,quantity:p.quantity})),services:[...r.services],request:null};
      $('#issuance-work-phone').textContent=`IMEI ${r.imei} · ${r.model||'Phone'} · ${storage(r.storage_gb)}`;
      row.classList.add('is-editing');workMessage();renderWorkEditor();
      $('#issuance-work-editor').hidden=false;$('#issuance-work-editor').scrollIntoView({block:'nearest',behavior:'smooth'});
    }catch(e){message(e.message||'The editor could not be opened.');}
    finally{lock(false);}
  }
  async function saveWorkEditor(){
    if(!editing||busy||paste?.busy||!can())return;
    const draft=editing,r=draft.record;
    if(draft.parts.length>100||draft.services.length>100){workMessage('Select no more than 100 different parts and 100 services.');return;}
    if(draft.parts.some(p=>!Number.isInteger(Number(p.quantity))||Number(p.quantity)<1||Number(p.quantity)>10000||String(p.quantity).trim()==='')){workMessage('Enter a whole quantity from 1 to 10,000 for every part.');return;}
    draft.request ||= crypto.randomUUID();lock(true);workMessage('Saving changes…');
    try{
      const result=await rpc('update_qc_issuance_requirements_v1',{
        p_job_id:r.job_id,p_revision:r.revision,p_parts:draft.parts.map(p=>({part_name:p.name,quantity:Number(p.quantity)})),p_services:draft.services,p_request_id:draft.request
      });
      if(stopped||editing!==draft||!can()||!draft.row.isConnected)return;
      const updated=result?.row;
      if(result.saved!==true||updated?.job_id!==r.job_id||updated?.imei!==r.imei||!Array.isArray(updated.parts)||!Array.isArray(updated.services)||typeof updated.revision!=='string')throw Error('The saved changes could not be verified. Keep this editor open and retry, or reload the phone.');
      prepared.clear();populate(draft.row,updated);closeWorkEditor();
      state(draft.row,'Changes saved · Awaiting Issuance');
      window.dispatchEvent(new CustomEvent('greenloop:workflow-committed',{detail:{source:'qc-issuance-edit',imeis:[r.imei]}}));
    }catch(e){if(editing===draft)workMessage(e.message||'Changes were not saved. Your selections are still here.');}
    finally{lock(false);}
  }
  $('#issuance-work-save').addEventListener('click',()=>void saveWorkEditor());
  $('#issuance-work-cancel').addEventListener('click',()=>{if(!busy&&!paste?.busy)closeWorkEditor();});
  $('#issuance-part-add').addEventListener('click',()=>{
    if(!editing||busy||paste?.busy||!can())return;const name=$('#issuance-part-choice').value;
    if(!name)return;if(editing.parts.some(p=>p.name===name))return;
    editing.parts.push({name,quantity:1});editing.request=null;workMessage();renderWorkEditor();
  });
  $('#issuance-service-add').addEventListener('click',()=>{
    if(!editing||busy||paste?.busy||!can())return;const name=$('#issuance-service-choice').value;
    if(!name||editing.services.includes(name))return;
    editing.services.push(name);editing.request=null;workMessage();renderWorkEditor();
  });
  $('#issuance-work-editor').addEventListener('click',event=>{
    if(!editing||busy||paste?.busy||!can())return;
    const part=event.target.closest('[data-remove-edit-part]'),service=event.target.closest('[data-remove-edit-service]');
    if(part)editing.parts.splice(Number(part.dataset.removeEditPart),1);
    else if(service)editing.services.splice(Number(service.dataset.removeEditService),1);else return;
    editing.request=null;workMessage();renderWorkEditor();
  });
  $('#issuance-work-editor').addEventListener('input',event=>{
    if(!editing||busy||paste?.busy||!can()||!event.target.matches('[data-edit-quantity]'))return;
    editing.parts[Number(event.target.dataset.editQuantity)].quantity=event.target.value;editing.request=null;workMessage();
  });
  body.addEventListener('paste',event=>{if(editing){event.preventDefault();event.stopImmediatePropagation();workMessage('Save or cancel these changes before pasting more phones.');}},true);

  function populate(row,r){
    records.set(row,r);delete row.dataset.issueRequest;
    const cell=(selector,value,title=value)=>{const e=row.querySelector(selector);e.textContent=value;e.title=title;};
    cell('[data-phone]',r.model||'—');cell('[data-storage]',storage(r.storage_gb));cell('[data-color]',r.color||'—');cell('[data-battery]',r.battery_health==null?'N/A':r.battery_health+'%');
    const supplier=window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(r.supplier_code,r.stock_quantity,r.supplier_name,'—')||r.supplier_code||'—';
    const receipt=`${supplier}\nStock / Batch: ${r.batch_number||'—'}\nInvoice: ${r.invoice_number||'—'}`;
    cell('[data-stock]',supplier,receipt);row.querySelector('[data-stock]').setAttribute('aria-label',receipt);
    const saved=`Inspection saved: ${date(r.saved_at)}${r.saved_by?' · '+r.saved_by:''}`;
    cell('[data-supplier-grade]',r.supplier_grade||'—',saved);cell('[data-gl-grade]',r.gl_grade||'—',saved);
    cell('[data-parts]',r.parts.length?r.parts.map(p=>`${p.name} × ${p.quantity}`).join('; '):'None');
    cell('[data-services]',r.services.length?r.services.join('; '):'None');
    row.dataset.inspectionRevision=r.revision;state(row,'Awaiting Issuance');sync(row);
  }
  async function prepare(imeis){prepared.clear();for(let i=0;i<imeis.length;i+=500){const chunk=imeis.slice(i,i+500);const data=await rpc('get_qc_issuance_rows_v1',{p_imeis:chunk,p_limit:500});for(const r of data.rows)prepared.set(r.imei,r);}}
  async function loadRow(row,settings={}){
    const input=row.querySelector('.qc-issuance-imei'),imei=input.value.trim();if(!/^\d{15}$/.test(imei))return{loaded:false,message:'Enter an exact 15-digit IMEI.'};
    const ticket=row.dataset.ticket=String(Number(row.dataset.ticket||0)+1),current=()=>!stopped&&row.isConnected&&row.dataset.ticket===ticket&&input.value.trim()===imei&&(!settings.isCurrent||settings.isCurrent());
    if([...body.rows].some(other=>other!==row&&other.querySelector('.qc-issuance-imei').value===imei)){state(row,'This IMEI is already in this tray.',true);return{loaded:false,message:'Duplicate IMEI: already in this tray.'};}
    row.dataset.loading='yes';state(row,'Loading saved inspection…');
    try{
      const r=settings.bulk?prepared.get(imei):(await rpc('get_qc_issuance_rows_v1',{p_imeis:[imei],p_limit:1})).rows[0];
      if(!current())return{loaded:false,message:'Loading stopped.'};
      if(r){populate(row,r);return{loaded:true};}
      const record=await window.GREENLOOP_IMEI_STAGE_NOTICE.lookup(imei);if(!current())return{loaded:false,message:'Loading stopped.'};
      const text=record?.matched_type==='secondary'?`This is IMEI 2. Use IMEI 1 ${record.primary_imei||''}.`:record?.found?`Current stage: ${record.current_stage}. Save its Initial QC inspection before issuance.`:'IMEI not found in the software.';
      state(row,text,true);if(!settings.bulk)void window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei,knownRecord:record,title:'Phone unavailable here',message:text,onlyIfFound:true,isCurrent:current});return{loaded:false,message:text,record};
    }catch(e){if(current())state(row,e.message||'Could not load. Press Enter to retry.',true);throw e;}
    finally{if(current()){row.dataset.loading='';sync(row);}}
  }
  async function refresh(){
    const data=await rpc('get_qc_issuance_options_v1');technicians=data.technicians||[];$('#issuance-count').textContent=String(data.awaiting_issuance||0);
    for(const select of app.querySelectorAll('[data-technician]')){const v=select.value;select.innerHTML=options(v);}
    if(body.firstElementChild)selectionTemplate.technician=body.firstElementChild.querySelector('[data-technician]').value;
    // A successful inspection save in another tab becomes available on Refresh.
    prepared.clear();syncAll();
  }
  function lock(value){busy=value;for(const e of app.querySelectorAll('input,select,button'))e.disabled=value||(!can()&&e.dataset.capability!=='view');window.GREENLOOP_QC_HANDOVER?.setBusy('issuance',value);syncAll();}
  async function transfer(row){
    const r=records.get(row);if(editing)return{ok:false,error:'Save or cancel the open Parts / Services editor first.'};
    if(!can()||!r||row.dataset.completed==='yes'||row.querySelector('.qc-issuance-imei').value.trim()!==r.imei)return{ok:false,error:'Load this saved inspection first.'};
    const dest=row.querySelector('[data-destination]').value,technician=dest==='lab_glass'?row.querySelector('[data-technician]').value:null;
    if(dest==='lab_glass'&&!technician){state(row,'Choose a Lab technician.',true);return{ok:false,error:'Choose a Lab technician.'};}
    if(dest==='b_dept'&&(r.parts.length||r.services.length||String(r.gl_grade).toUpperCase()==='D')){const error='B-DEPT direct transfer needs no parts or services and a non-D GL grade. Choose Lab & Glass for repair work.';state(row,error,true);return{ok:false,error};}
    row.dataset.issueRequest ||= crypto.randomUUID();row.dataset.saving='yes';state(row,'Transferring…');
    try{
      const result=await rpc('issue_initial_qc_inspection_v1',{p_job_id:r.job_id,p_revision:r.revision,p_destination:dest,p_technician_roster_id:technician||null,p_request_id:row.dataset.issueRequest});
      row.dataset.completed='yes';row.classList.add('is-completed');row.querySelector('[data-transfer]').textContent='Done';state(row,`Transferred to ${dest==='b_dept'?'B-DEPT':result.technician_name+' · Lab & Glass'}`);
      if(dest==='lab_glass')window.GREENLOOP_QC_HANDOVER?.record({jobId:r.job_id,imei:r.imei,model:r.model,storage:storage(r.storage_gb),color:r.color,technicianId:technician,technician:result.technician_name,parts:r.parts,services:r.services});
      window.dispatchEvent(new CustomEvent('greenloop:workflow-committed',{detail:{source:'qc-issuance',imeis:[r.imei]}}));return{ok:true};
    }catch(e){state(row,e.message||'Transfer failed. Your choices are preserved.',true);return{ok:false,error:e.message};}
    finally{row.dataset.saving='';sync(row);}
  }
  async function transferMany(rows){if(editing){message('Save or cancel the open Parts / Services editor first.');return;}if(busy||paste?.busy||!can())return;message();lock(true);let done=0;const errors=[];try{for(const row of rows){if(stopped||!can())break;const result=await transfer(row);if(result.ok)done++;else errors.push(`Line ${[...body.rows].indexOf(row)+1}: ${result.error}`);}await refresh();message(`${done} phone(s) transferred.${errors.length?' '+errors.length+' need checking. '+errors[0]:''}`,!errors.length);}catch(e){message(e.message);}finally{lock(false);}}
  async function loadAll(){if(editing||busy||paste?.busy||stopped||!window.GREENLOOP_CAN?.('view','initial_qc'))return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Replace this unfinished tray with all awaiting inspections?'))return;lock(true);message();try{const all=[];let offset=0,total=1;while(offset<total){const data=await rpc('get_qc_issuance_rows_v1',{p_offset:offset,p_limit:500});total=data.total;if(!data.rows.length&&offset<total)throw Error('The queue changed. Refresh and try again.');all.push(...data.rows);offset+=data.rows.length;}body.innerHTML='';records.clear();createRows(Math.max(10,all.length));all.forEach((r,i)=>{body.rows[i].querySelector('.qc-issuance-imei').value=r.imei;populate(body.rows[i],r);});message(`${all.length} saved inspections loaded.`,true);}catch(e){message(e.message);}finally{lock(false);}}
  function reset(){if(editing||busy||paste?.busy)return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Clear this unfinished handover tray? Saved inspections stay in the queue.'))return;body.innerHTML='';records.clear();prepared.clear();paste?.clear();createRows(10);message();}
  body.addEventListener('input',event=>{const input=event.target.closest('.qc-issuance-imei');if(!input||editing)return;const row=input.closest('tr');clearTimeout(timers.get(row));input.value=input.value.replace(/\D/g,'').slice(0,15);clearRow(row);if(input.value.length===15){timers.set(row,setTimeout(()=>loadRow(row).catch(e=>message(e.message)),120));const next=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>e!==input&&!e.disabled&&!e.value);if(document.activeElement===input)next?.focus();}});
  body.addEventListener('keydown',event=>{if(editing||event.key!=='Enter'||!event.target.matches('.qc-issuance-imei'))return;event.preventDefault();const row=event.target.closest('tr');clearTimeout(timers.get(row));void loadRow(row).catch(e=>message(e.message));});
  body.addEventListener('change',e=>{const row=e.target.closest('tr');if(!row||editing||!can()||busy||paste?.busy||row.dataset.completed==='yes')return;if(e.target.matches('[data-destination],[data-technician]')){delete row.dataset.issueRequest;carrySelection(row,e.target.matches('[data-technician]')?'technician':'destination');sync(row);}});
  body.addEventListener('click',e=>{const row=e.target.closest('tr');if(!row||busy||paste?.busy||!can()||editing)return;if(e.target.closest('[data-edit-work]'))void openWorkEditor(row);if(e.target.closest('[data-transfer]'))void transferMany([row]);if(e.target.closest('[data-reload]')){clearRow(row);void loadRow(row).catch(e=>message(e.message));}});
  $('#issuance-transfer-all').addEventListener('click',()=>{const rows=[...body.rows].filter(r=>records.has(r)&&r.dataset.completed!=='yes');if(!rows.length){message('Scan or paste at least one saved inspection first.');return;}void transferMany(rows);});
  $('#issuance-load-all').addEventListener('click',()=>void loadAll());$('#issuance-clear').addEventListener('click',reset);$('#issuance-add').addEventListener('click',()=>{if(!editing&&!busy&&!paste?.busy&&can())createRows(10);});
  $('#issuance-refresh').addEventListener('click',()=>{if(editing||busy||paste?.busy)return;void refresh().catch(e=>message(e.message));});
  window.addEventListener('greenloop:imei-scan',event=>{if(editing||!can()||busy||paste?.busy)return;const imei=String(event.detail?.imei||'');if(!/^\d{15}$/.test(imei))return;const existing=[...body.rows].find(r=>r.querySelector('.qc-issuance-imei').value===imei);if(existing){event.preventDefault();existing.scrollIntoView({block:'center'});state(existing,'This IMEI is already in the tray.');return;}let blank=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>!e.disabled&&!e.value);if(!blank){createRows(1);blank=body.lastElementChild.querySelector('.qc-issuance-imei');}event.preventDefault();blank.value=imei;void loadRow(blank.closest('tr')).catch(e=>message(e.message));});
  function stop(){stopped=true;closeWorkEditor();records.clear();prepared.clear();body.innerHTML='';app.hidden=true;message('Access ended. Reload after signing in.');}
  window.addEventListener('greenloop:office-locked',stop);window.addEventListener('pagehide',stop);client.auth.onAuthStateChange?.(e=>{if(e==='SIGNED_OUT')stop();});
  window.addEventListener('greenloop:permissions-changed',()=>{if(!window.GREENLOOP_CAN?.('view','initial_qc'))stop();else{if(!can()&&editing)closeWorkEditor();syncAll();}});
  async function init(){await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();if(!window.GREENLOOP_CAN?.('view','initial_qc'))throw Error('Initial QC page access is required.');await refresh();createRows(10);app.hidden=false;paste=window.GREENLOOP_QC_EXCEL_PASTE.attach({app,tableBody:body,selector:'.qc-issuance-imei',page:'initial_qc',client,createRows,clearRow,loadRow,prepare,onUnlock:()=>setTimeout(syncAll,0)});window.GREENLOOP_QC_HANDOVER?.refresh();syncAll();}
  void init().catch(e=>{$('#permission-message').textContent=e.message||'Issuance could not load.';$('#permission-message').hidden=false;});
})();
